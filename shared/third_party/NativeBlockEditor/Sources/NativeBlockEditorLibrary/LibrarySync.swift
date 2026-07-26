import Foundation
import NativeBlockEditorEngine

/// A transport-neutral page or folder payload used by CloudKit and future
/// sync providers. The page and its library metadata travel together so title,
/// hierarchy, and document content resolve conflicts as one user edit.
public struct LibrarySyncRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String { item.id }
    public var item: LibraryItem
    public var page: PageRecord?

    public init(item: LibraryItem, page: PageRecord? = nil) throws {
        guard item.kind == .page ? page?.id == item.id : page == nil else {
            throw PageWorkspaceError.itemNotFound(item.id)
        }
        self.item = item
        self.page = page
    }

    public var updatedAt: Date {
        max(item.updatedAt, page?.updatedAt ?? .distantPast)
    }
}

public extension PageWorkspace {
    /// Stable, independently syncable records. The synthetic library root is
    /// recreated locally and never needs its own cloud record.
    var syncRecords: [LibrarySyncRecord] {
        items.values
            .filter { $0.id != libraryRootID }
            .compactMap { try? LibrarySyncRecord(item: $0, page: pages[$0.id]) }
            .sorted { $0.id < $1.id }
    }
}

/// Deterministic last-user-edit-wins merging for records received from a
/// personal cloud database. CloudKit system modification dates are not used:
/// they describe upload order, while these dates describe the user's edit.
public enum LibrarySyncMerger {
    public static func merge(
        local: PageWorkspace,
        remoteRecords: [LibrarySyncRecord],
        deletedRecordIDs: Set<String> = [],
        remoteRootPageID: String? = nil
    ) throws -> PageWorkspace {
        var items = local.items
        var pages = local.pages

        let protectedIDs: Set<String> = [local.libraryRootID, local.rootPageID]
        let deletions = deletedRecordIDs.subtracting(protectedIDs)
        if !deletions.isEmpty {
            let subtree = items.keys.filter { id in
                var cursor: String? = id
                var visited: Set<String> = []
                while let current = cursor, visited.insert(current).inserted {
                    if deletions.contains(current) { return true }
                    cursor = items[current]?.parentID
                }
                return false
            }
            for id in subtree {
                items.removeValue(forKey: id)
                pages.removeValue(forKey: id)
            }
        }

        for record in remoteRecords where record.id != local.libraryRootID {
            let localDate = max(
                items[record.id]?.updatedAt ?? .distantPast,
                pages[record.id]?.updatedAt ?? .distantPast
            )
            guard record.updatedAt >= localDate else { continue }
            items[record.id] = record.item
            if let page = record.page {
                pages[record.id] = page
            } else {
                pages.removeValue(forKey: record.id)
            }
        }

        // Remote batches can arrive independently. Repair temporary orphaning
        // without dropping content, then let the next batch place it correctly.
        for id in Array(items.keys) where id != local.libraryRootID {
            guard var item = items[id] else { continue }
            if item.parentID == nil || items[item.parentID ?? ""] == nil {
                item.parentID = local.libraryRootID
                items[id] = item
            }
            if item.kind == .folder {
                pages.removeValue(forKey: id)
            } else if pages[id] == nil {
                // A page item without its document is not usable. Preserve a
                // local copy when one exists; otherwise defer it to a later batch.
                if let localPage = local.pages[id] {
                    pages[id] = localPage
                } else {
                    items.removeValue(forKey: id)
                }
            }
        }

        for id in Array(pages.keys) {
            guard let item = items[id], item.kind == .page else {
                pages.removeValue(forKey: id)
                continue
            }
            var page = pages[id]!
            page.title = item.title
            page.icon = item.icon
            page.parentID = item.parentID
            pages[id] = page
        }

        var rootPageID = remoteRootPageID.flatMap { pages[$0] == nil ? nil : $0 }
            ?? (pages[local.rootPageID] == nil ? nil : local.rootPageID)
            ?? pages.keys.sorted().first
        guard let resolvedRoot = rootPageID, var rootItem = items[resolvedRoot], var rootPage = pages[resolvedRoot] else {
            throw PageWorkspaceError.pageNotFound(remoteRootPageID ?? local.rootPageID)
        }
        rootPageID = resolvedRoot
        rootItem.parentID = local.libraryRootID
        rootPage.parentID = local.libraryRootID
        items[resolvedRoot] = rootItem
        pages[resolvedRoot] = rootPage

        return try PageWorkspace(rootPageID: rootPageID!, pages: pages, items: items)
    }
}
