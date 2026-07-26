import Foundation
import NativeBlockEditorEngine

public enum PageWorkspaceError: Error, Equatable, Sendable {
    case duplicatePageID(String)
    case pageNotFound(String)
    case itemNotFound(String)
    case invalidParent(String)
    case folderRequiresFolderParent(String)
    case cannotReparentRoot
    case cannotDeleteRoot
    case cyclicHierarchy
}

extension PageWorkspaceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .duplicatePageID(id): "A page with ID \(id) already exists"
        case let .pageNotFound(id): "Page \(id) was not found"
        case let .itemNotFound(id): "Library item \(id) was not found"
        case let .invalidParent(id): "Parent library item \(id) was not found"
        case let .folderRequiresFolderParent(id): "Folders can only live at the library root or inside another folder, not inside page \(id)"
        case .cannotReparentRoot: "The workspace root page cannot be reparented"
        case .cannotDeleteRoot: "The workspace root page cannot be deleted"
        case .cyclicHierarchy: "A page cannot become its own descendant"
        }
    }
}

public enum LibraryItemKind: String, Codable, Hashable, Sendable {
    case folder
    case page
}

public struct LibraryItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: LibraryItemKind
    public var parentID: String?
    public var sortKey: Double
    public var title: String
    public var icon: String
    public var isFavorite: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastOpenedAt: Date?
    public var trashedAt: Date?

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: LibraryItemKind,
        parentID: String? = nil,
        sortKey: Double = 0,
        title: String,
        icon: String? = nil,
        isFavorite: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastOpenedAt: Date? = nil,
        trashedAt: Date? = nil
    ) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.kind = kind
        self.parentID = parentID
        self.sortKey = sortKey
        self.title = trimmed.isEmpty ? (kind == .folder ? "New folder" : "Untitled") : trimmed
        self.icon = icon ?? (kind == .folder ? "folder" : "doc.text")
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
        self.trashedAt = trashedAt
    }
}

public struct PageRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var icon: String
    public var parentID: String?
    public var document: BlockDocument
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        icon: String = "doc.text",
        parentID: String? = nil,
        document: BlockDocument = .blank(),
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title
        self.icon = icon
        self.parentID = parentID
        var anchoredDocument = document
        anchoredDocument.ensureStableBlockIDs()
        self.document = anchoredDocument
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PageBacklink: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case child
        case reference
    }

    public var sourcePageID: String
    public var blockPath: BlockPath
    public var kind: Kind

    public init(sourcePageID: String, blockPath: BlockPath, kind: Kind) {
        self.sourcePageID = sourcePageID
        self.blockPath = blockPath
        self.kind = kind
    }
}

public struct BlockAnchor: Codable, Hashable, Sendable {
    public var pageID: String
    public var blockID: String

    public init(pageID: String, blockID: String) {
        self.pageID = pageID
        self.blockID = blockID
    }

    public var url: URL? {
        URL(string: "native-editor://page/\(pageID)#\(blockID)")
    }
}

/// A collection of independently stored block documents connected by stable IDs.
/// Child-page blocks express ownership; page-reference blocks are non-owning links.
public struct PageWorkspace: Codable, Hashable, Sendable {
    public static let libraryRootItemID = "__native_editor_library_root__"

    public private(set) var rootPageID: String
    public private(set) var pages: [String: PageRecord]
    public private(set) var items: [String: LibraryItem]
    public var libraryRootID: String { Self.libraryRootItemID }

    public init(rootPage: PageRecord) {
        var root = rootPage
        root.parentID = Self.libraryRootItemID
        rootPageID = root.id
        pages = [root.id: root]
        items = [
            Self.libraryRootItemID: LibraryItem(
                id: Self.libraryRootItemID,
                kind: .folder,
                title: "Library",
                icon: "books.vertical",
                createdAt: root.createdAt,
                updatedAt: root.updatedAt
            ),
            root.id: LibraryItem(
                id: root.id,
                kind: .page,
                parentID: Self.libraryRootItemID,
                title: root.title,
                icon: root.icon,
                createdAt: root.createdAt,
                updatedAt: root.updatedAt,
                lastOpenedAt: root.updatedAt
            ),
        ]
    }

    public init(rootTitle: String, document: BlockDocument = .blank()) {
        self.init(rootPage: PageRecord(title: rootTitle, document: document))
    }

    public func page(id: String) -> PageRecord? {
        pages[id]
    }

    public func item(id: String) -> LibraryItem? {
        items[id]
    }

    public func libraryChildren(of parentID: String, includeTrashed: Bool = false) -> [LibraryItem] {
        items.values
            .filter { item in
                item.parentID == parentID && (includeTrashed || item.trashedAt == nil)
            }
            .sorted(by: Self.itemOrder)
    }

    public var favorites: [LibraryItem] {
        items.values
            .filter { $0.isFavorite && $0.trashedAt == nil }
            .sorted(by: Self.itemOrder)
    }

    public var recents: [LibraryItem] {
        items.values
            .filter { $0.kind == .page && $0.trashedAt == nil && $0.lastOpenedAt != nil }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
    }

    public var trash: [LibraryItem] {
        items.values
            .filter { $0.trashedAt != nil && ($0.parentID.flatMap { items[$0]?.trashedAt } == nil) }
            .sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
    }

    public func children(of pageID: String) -> [PageRecord] {
        libraryChildren(of: pageID).compactMap { $0.kind == .page ? pages[$0.id] : nil }
    }

    public func breadcrumbs(to pageID: String) -> [PageRecord] {
        libraryBreadcrumbs(to: pageID).compactMap { $0.kind == .page ? pages[$0.id] : nil }
    }

    public func libraryBreadcrumbs(to itemID: String) -> [LibraryItem] {
        var result: [LibraryItem] = []
        var currentID: String? = itemID
        var visited: Set<String> = []
        while let id = currentID, id != libraryRootID,
              visited.insert(id).inserted, let item = items[id] {
            result.append(item)
            currentID = item.parentID
        }
        return result.reversed()
    }

    public func backlinks(to targetPageID: String) -> [PageBacklink] {
        pages.values.flatMap { page in
            page.document.flattenedNodes().compactMap { path, node in
                guard node.data["page_id"]?.stringValue == targetPageID else { return nil }
                let kind: PageBacklink.Kind
                switch node.type {
                case "nbe/child_page": kind = .child
                case "nbe/page_reference": kind = .reference
                default: return nil
                }
                return PageBacklink(sourcePageID: page.id, blockPath: path, kind: kind)
            }
        }
        .sorted { lhs, rhs in
            if lhs.sourcePageID == rhs.sourcePageID { return lhs.blockPath < rhs.blockPath }
            return lhs.sourcePageID < rhs.sourcePageID
        }
    }

    public func anchor(for pageID: String, blockPath: BlockPath) -> BlockAnchor? {
        guard let blockID = pages[pageID]?.document.node(at: blockPath)?.stableBlockID else { return nil }
        return BlockAnchor(pageID: pageID, blockID: blockID)
    }

    public func resolve(_ anchor: BlockAnchor) -> BlockPath? {
        pages[anchor.pageID]?.document.flattenedNodes().first { _, node in
            node.stableBlockID == anchor.blockID
        }?.path
    }

    @discardableResult
    public mutating func createPage(
        title: String,
        parentID: String,
        icon: String = "doc.text",
        document: BlockDocument = .blank(),
        id: String = UUID().uuidString.lowercased()
    ) throws -> PageRecord {
        guard let parent = items[parentID], parent.trashedAt == nil else {
            throw PageWorkspaceError.invalidParent(parentID)
        }
        guard pages[id] == nil else { throw PageWorkspaceError.duplicatePageID(id) }
        let page = PageRecord(id: id, title: title, icon: icon, parentID: parentID, document: document)
        pages[id] = page
        items[id] = LibraryItem(
            id: id,
            kind: .page,
            parentID: parentID,
            sortKey: nextSortKey(in: parentID),
            title: page.title,
            icon: icon,
            createdAt: page.createdAt,
            updatedAt: page.updatedAt
        )
        return page
    }

    @discardableResult
    public mutating func createFolder(
        title: String,
        parentID: String,
        icon: String = "folder",
        id: String = UUID().uuidString.lowercased()
    ) throws -> LibraryItem {
        guard let parent = items[parentID], parent.trashedAt == nil else {
            throw PageWorkspaceError.invalidParent(parentID)
        }
        guard parent.kind == .folder else {
            throw PageWorkspaceError.folderRequiresFolderParent(parentID)
        }
        guard items[id] == nil else { throw PageWorkspaceError.duplicatePageID(id) }
        let folder = LibraryItem(
            id: id,
            kind: .folder,
            parentID: parentID,
            sortKey: nextSortKey(in: parentID),
            title: title,
            icon: icon
        )
        items[id] = folder
        return folder
    }

    public mutating func saveDocument(_ document: BlockDocument, for pageID: String) throws {
        guard var page = pages[pageID] else { throw PageWorkspaceError.pageNotFound(pageID) }
        var anchoredDocument = document
        anchoredDocument.ensureStableBlockIDs()
        try anchoredDocument.validate()
        page.document = anchoredDocument
        page.updatedAt = .now
        pages[pageID] = page
        if var item = items[pageID] {
            item.updatedAt = page.updatedAt
            items[pageID] = item
        }
    }

    public mutating func renamePage(_ pageID: String, to title: String) throws {
        guard var page = pages[pageID] else { throw PageWorkspaceError.pageNotFound(pageID) }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        page.title = trimmed.isEmpty ? "Untitled" : trimmed
        page.updatedAt = .now
        pages[pageID] = page
        if var item = items[pageID] {
            item.title = page.title
            item.updatedAt = page.updatedAt
            items[pageID] = item
        }
    }

    public mutating func reparentPage(_ pageID: String, to parentID: String) throws {
        guard pages[pageID] != nil else { throw PageWorkspaceError.pageNotFound(pageID) }
        try moveItem(pageID, to: parentID)
    }

    public mutating func renameItem(_ itemID: String, to title: String) throws {
        guard var item = items[itemID] else { throw PageWorkspaceError.itemNotFound(itemID) }
        if item.kind == .page {
            try renamePage(itemID, to: title)
            return
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.title = trimmed.isEmpty ? "New folder" : trimmed
        item.updatedAt = .now
        items[itemID] = item
    }

    public mutating func moveItem(_ itemID: String, to parentID: String, at index: Int? = nil) throws {
        guard itemID != rootPageID, itemID != libraryRootID else { throw PageWorkspaceError.cannotReparentRoot }
        guard var item = items[itemID] else { throw PageWorkspaceError.itemNotFound(itemID) }
        guard let parent = items[parentID], parent.trashedAt == nil else { throw PageWorkspaceError.invalidParent(parentID) }
        if item.kind == .folder, parent.kind != .folder {
            throw PageWorkspaceError.folderRequiresFolderParent(parentID)
        }
        guard itemID != parentID else { throw PageWorkspaceError.cyclicHierarchy }

        var ancestorID: String? = parentID
        while let id = ancestorID {
            guard id != itemID else { throw PageWorkspaceError.cyclicHierarchy }
            ancestorID = items[id]?.parentID
        }

        let now = Date.now
        item.parentID = parentID
        item.updatedAt = now
        items[itemID] = item
        if var page = pages[itemID] {
            page.parentID = parentID
            page.updatedAt = now
            pages[itemID] = page
        }

        var siblings = libraryChildren(of: parentID).filter { $0.id != itemID }
        let target = min(max(0, index ?? siblings.count), siblings.count)
        siblings.insert(item, at: target)
        for (position, sibling) in siblings.enumerated() {
            guard var updated = items[sibling.id] else { continue }
            updated.sortKey = Double(position) * 1_024
            items[sibling.id] = updated
        }
    }

    public mutating func toggleFavorite(_ itemID: String) throws {
        guard var item = items[itemID] else { throw PageWorkspaceError.itemNotFound(itemID) }
        item.isFavorite.toggle()
        item.updatedAt = .now
        items[itemID] = item
    }

    @discardableResult
    public mutating func duplicateItem(_ itemID: String) throws -> LibraryItem {
        guard itemID != rootPageID, itemID != libraryRootID,
              let sourceRoot = items[itemID], let destinationParentID = sourceRoot.parentID else {
            throw PageWorkspaceError.cannotReparentRoot
        }
        let sourceIDs = subtreeIDs(rootedAt: itemID)
        let idMap = Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0, UUID().uuidString.lowercased()) })

        for sourceID in sourceIDs {
            guard let source = items[sourceID], let newID = idMap[sourceID] else { continue }
            let parentID = sourceID == itemID
                ? destinationParentID
                : source.parentID.flatMap { idMap[$0] } ?? destinationParentID
            let title = sourceID == itemID ? "\(source.title) copy" : source.title
            if source.kind == .folder {
                _ = try createFolder(title: title, parentID: parentID, icon: source.icon, id: newID)
            } else if let page = pages[sourceID] {
                var duplicatedDocument = page.document
                Self.rewritePageTargets(in: &duplicatedDocument.root.children, using: idMap)
                _ = try createPage(
                    title: title,
                    parentID: parentID,
                    icon: source.icon,
                    document: duplicatedDocument,
                    id: newID
                )
            }
        }
        guard let duplicated = items[idMap[itemID] ?? ""] else {
            throw PageWorkspaceError.itemNotFound(itemID)
        }
        return duplicated
    }

    public mutating func markOpened(_ pageID: String, at date: Date = .now) throws {
        guard var item = items[pageID], item.kind == .page else {
            throw PageWorkspaceError.pageNotFound(pageID)
        }
        item.lastOpenedAt = date
        items[pageID] = item
    }

    public mutating func trashItem(_ itemID: String, at date: Date = .now) throws {
        guard itemID != rootPageID, itemID != libraryRootID else { throw PageWorkspaceError.cannotDeleteRoot }
        guard items[itemID] != nil else { throw PageWorkspaceError.itemNotFound(itemID) }
        for id in subtreeIDs(rootedAt: itemID) {
            guard var item = items[id] else { continue }
            item.trashedAt = date
            item.updatedAt = date
            items[id] = item
        }
    }

    public mutating func restoreItem(_ itemID: String) throws {
        guard items[itemID] != nil else { throw PageWorkspaceError.itemNotFound(itemID) }
        for id in subtreeIDs(rootedAt: itemID) {
            guard var item = items[id] else { continue }
            item.trashedAt = nil
            item.updatedAt = .now
            items[id] = item
        }
    }

    public mutating func permanentlyDeleteItem(_ itemID: String) throws {
        guard itemID != rootPageID, itemID != libraryRootID else { throw PageWorkspaceError.cannotDeleteRoot }
        guard items[itemID] != nil else { throw PageWorkspaceError.itemNotFound(itemID) }
        for id in subtreeIDs(rootedAt: itemID) {
            items.removeValue(forKey: id)
            pages.removeValue(forKey: id)
        }
    }

    public func validate() throws {
        guard let libraryRoot = items[libraryRootID], libraryRoot.kind == .folder, libraryRoot.parentID == nil,
              let root = pages[rootPageID], root.parentID == libraryRootID,
              let rootItem = items[rootPageID], rootItem.kind == .page, rootItem.parentID == libraryRootID else {
            throw PageWorkspaceError.pageNotFound(rootPageID)
        }
        guard pages.keys.allSatisfy({ items[$0]?.kind == .page }) else {
            throw PageWorkspaceError.itemNotFound("page metadata")
        }
        for page in pages.values {
            try page.document.validate()
            if let parentID = page.parentID, items[parentID] == nil {
                throw PageWorkspaceError.invalidParent(parentID)
            }
        }
        for item in items.values {
            if let parentID = item.parentID, items[parentID] == nil {
                throw PageWorkspaceError.invalidParent(parentID)
            }
            if item.kind == .folder, item.id != libraryRootID,
               let parentID = item.parentID, items[parentID]?.kind != .folder {
                throw PageWorkspaceError.folderRequiresFolderParent(parentID)
            }
            var visited: Set<String> = []
            var currentID: String? = item.id
            while let id = currentID {
                guard visited.insert(id).inserted else { throw PageWorkspaceError.cyclicHierarchy }
                currentID = items[id]?.parentID
            }
        }
    }

    public init(rootPageID: String, pages: [String: PageRecord], items: [String: LibraryItem]) throws {
        self.rootPageID = rootPageID
        self.pages = pages
        self.items = items
        normalizeLibraryRoot()
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case rootPageID
        case pages
        case items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootPageID = try container.decode(String.self, forKey: .rootPageID)
        pages = try container.decode([String: PageRecord].self, forKey: .pages)
        if let decodedItems = try container.decodeIfPresent([String: LibraryItem].self, forKey: .items) {
            items = decodedItems
        } else {
            items = Dictionary(uniqueKeysWithValues: pages.values.enumerated().map { index, page in
                (page.id, LibraryItem(
                    id: page.id,
                    kind: .page,
                    parentID: page.parentID,
                    sortKey: Double(index) * 1_024,
                    title: page.title,
                    icon: page.icon,
                    createdAt: page.createdAt,
                    updatedAt: page.updatedAt
                ))
            })
        }
        normalizeLibraryRoot()
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rootPageID, forKey: .rootPageID)
        try container.encode(pages, forKey: .pages)
        try container.encode(items, forKey: .items)
    }

    private static func itemOrder(_ lhs: LibraryItem, _ rhs: LibraryItem) -> Bool {
        if lhs.sortKey == rhs.sortKey { return lhs.id < rhs.id }
        return lhs.sortKey < rhs.sortKey
    }

    /// Repairs libraries written before the organizational root existed.
    /// Legacy folders directly beneath pages are lifted to the nearest folder
    /// ancestor (or the library root) without altering their descendants.
    private mutating func normalizeLibraryRoot() {
        let reference = pages[rootPageID]
        if items[libraryRootID] == nil {
            items[libraryRootID] = LibraryItem(
                id: libraryRootID,
                kind: .folder,
                title: "Library",
                icon: "books.vertical",
                createdAt: reference?.createdAt ?? .now,
                updatedAt: reference?.updatedAt ?? .now
            )
        }

        for itemID in Array(items.keys) where itemID != libraryRootID {
            guard var item = items[itemID] else { continue }
            if item.parentID == nil {
                item.parentID = libraryRootID
            } else if item.kind == .folder, let parentID = item.parentID,
                      items[parentID]?.kind == .page {
                var destinationID: String? = parentID
                while let candidateID = destinationID, items[candidateID]?.kind == .page {
                    destinationID = items[candidateID]?.parentID
                }
                item.parentID = destinationID.flatMap { items[$0]?.kind == .folder ? $0 : nil } ?? libraryRootID
            }
            items[itemID] = item
            if var page = pages[itemID] {
                page.parentID = item.parentID
                pages[itemID] = page
            }
        }
    }

    private func nextSortKey(in parentID: String) -> Double {
        (items.values.filter { $0.parentID == parentID }.map(\.sortKey).max() ?? -1_024) + 1_024
    }

    private func subtreeIDs(rootedAt itemID: String) -> [String] {
        var result: [String] = []
        var pending = [itemID]
        while let current = pending.popLast() {
            result.append(current)
            pending.append(contentsOf: items.values.filter { $0.parentID == current }.map(\.id))
        }
        return result
    }

    private static func rewritePageTargets(in nodes: inout [BlockNode], using idMap: [String: String]) {
        for index in nodes.indices {
            if let targetID = nodes[index].data["page_id"]?.stringValue,
               let duplicatedTargetID = idMap[targetID] {
                nodes[index].data["page_id"] = .string(duplicatedTargetID)
            }
            rewritePageTargets(in: &nodes[index].children, using: idMap)
        }
    }
}
