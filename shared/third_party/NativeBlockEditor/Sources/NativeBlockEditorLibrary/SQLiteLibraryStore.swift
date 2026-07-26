import CryptoKit
import Foundation
import NativeBlockEditorEngine
import SQLite3

public enum LibraryStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case sqlite(code: Int32, message: String)
    case corruptData(String)
    case revisionConflict(pageID: String, expected: Int64, actual: Int64)
}

extension LibraryStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .openFailed(message): "The library database could not be opened: \(message)"
        case let .sqlite(code, message): "SQLite error \(code): \(message)"
        case let .corruptData(message): "The library database contains invalid data: \(message)"
        case let .revisionConflict(pageID, expected, actual):
            "Page \(pageID) changed from revision \(expected) to \(actual). Reload it before saving."
        }
    }
}

public struct PersistedLibrary: Sendable {
    public var workspace: PageWorkspace
    public var lastOpenPageID: String?

    public init(workspace: PageWorkspace, lastOpenPageID: String?) {
        self.workspace = workspace
        self.lastOpenPageID = lastOpenPageID
    }
}

public struct LibrarySearchResult: Hashable, Identifiable, Sendable {
    public var id: String { pageID }
    public var pageID: String
    public var title: String
    public var snippet: String
    public var score: Double

    public init(pageID: String, title: String, snippet: String, score: Double) {
        self.pageID = pageID
        self.title = title
        self.snippet = snippet
        self.score = score
    }
}

public struct PageHistoryEntry: Hashable, Identifiable, Sendable {
    public var id: String
    public var pageID: String
    public var createdAt: Date
    public var label: String?

    public init(id: String, pageID: String, createdAt: Date, label: String? = nil) {
        self.id = id
        self.pageID = pageID
        self.createdAt = createdAt
        self.label = label
    }
}

public struct LibraryMutationReceipt: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var changedPageIDs: [String]
    public var deletedItemIDs: [String]
    public var requiresFullInventory: Bool
    public var createdAt: Date

    public init(
        id: String,
        changedPageIDs: [String],
        deletedItemIDs: [String],
        requiresFullInventory: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.changedPageIDs = changedPageIDs
        self.deletedItemIDs = deletedItemIDs
        self.requiresFullInventory = requiresFullInventory
        self.createdAt = createdAt
    }
}

/// Native SQLite persistence for a personal document library.
///
/// The actor owns the connection, so disk work and JSON encoding never block the
/// main actor. WAL mode provides crash recovery while `BEGIN IMMEDIATE` keeps
/// library metadata and page documents in the same atomic commit.
public actor SQLiteLibraryStore {
    public static let currentSchemaVersion = 3

    private let connection: SQLiteConnection
    private var database: OpaquePointer { connection.handle }
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let handle { sqlite3_close(handle) }
            throw LibraryStoreError.openFailed(message)
        }
        connection = SQLiteConnection(handle)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()

        sqlite3_busy_timeout(handle, 3_000)
        do {
            try Self.execute(handle, "PRAGMA journal_mode = WAL")
            try Self.execute(handle, "PRAGMA synchronous = NORMAL")
            try Self.execute(handle, "PRAGMA foreign_keys = ON")
            try Self.migrate(handle)
        } catch {
            throw error
        }
    }

    public func load() throws -> PersistedLibrary? {
        guard let rootPageID = try metadataValue(for: "root_page_id") else { return nil }

        var items: [String: LibraryItem] = [:]
        let itemSQL = """
        SELECT id, kind, parent_id, sort_key, title, icon, is_favorite,
               created_at, updated_at, last_opened_at, trashed_at
        FROM library_items
        """
        try query(itemSQL) { statement in
            guard let id = Self.text(statement, 0),
                  let kindValue = Self.text(statement, 1),
                  let kind = LibraryItemKind(rawValue: kindValue),
                  let title = Self.text(statement, 4),
                  let icon = Self.text(statement, 5) else {
                throw LibraryStoreError.corruptData("A library item is missing required metadata")
            }
            items[id] = LibraryItem(
                id: id,
                kind: kind,
                parentID: Self.text(statement, 2),
                sortKey: sqlite3_column_double(statement, 3),
                title: title,
                icon: icon,
                isFavorite: sqlite3_column_int(statement, 6) != 0,
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 7)),
                updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 8)),
                lastOpenedAt: Self.date(statement, 9),
                trashedAt: Self.date(statement, 10)
            )
        }

        var pages: [String: PageRecord] = [:]
        try query("SELECT page_id, document_json, updated_at FROM page_documents") { statement in
            guard let pageID = Self.text(statement, 0),
                  let item = items[pageID], item.kind == .page,
                  let data = Self.data(statement, 1) else {
                throw LibraryStoreError.corruptData("A page document is missing its library item")
            }
            let document: BlockDocument
            do { document = try decoder.decode(BlockDocument.self, from: data) }
            catch { throw LibraryStoreError.corruptData("Page \(pageID) could not be decoded: \(error.localizedDescription)") }
            pages[pageID] = PageRecord(
                id: pageID,
                title: item.title,
                icon: item.icon,
                parentID: item.parentID,
                document: document,
                createdAt: item.createdAt,
                updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
            )
        }

        do {
            let workspace = try PageWorkspace(rootPageID: rootPageID, pages: pages, items: items)
            return PersistedLibrary(
                workspace: workspace,
                lastOpenPageID: try metadataValue(for: "last_open_page_id")
            )
        } catch {
            throw LibraryStoreError.corruptData(error.localizedDescription)
        }
    }

    public func save(
        _ workspace: PageWorkspace,
        lastOpenPageID: String?,
        changedPageIDs: Set<String>? = nil,
        recordHistory: Bool = true,
        expectedRevisions: [String: Int64] = [:]
    ) throws {
        try workspace.validate()
        try execute("BEGIN IMMEDIATE")
        do {
            let previousItemIDs = try allItemIDs()
            for (pageID, expectedRevision) in expectedRevisions {
                let actualRevision = try existingPage(pageID)?.revision ?? 0
                guard actualRevision == expectedRevision else {
                    throw LibraryStoreError.revisionConflict(
                        pageID: pageID,
                        expected: expectedRevision,
                        actual: actualRevision
                    )
                }
            }
            try setMetadata("root_page_id", value: workspace.rootPageID)
            if let lastOpenPageID { try setMetadata("last_open_page_id", value: lastOpenPageID) }
            else { try deleteMetadata("last_open_page_id") }

            let currentItemIDs = Set(workspace.items.keys)
            for item in workspace.items.values {
                try upsert(item)
            }
            try deleteMissingRows(table: "library_items", idColumn: "id", keeping: currentItemIDs)

            let currentPageIDs = Set(workspace.pages.keys)
            let pagesToWrite = changedPageIDs.map { $0.intersection(currentPageIDs) } ?? currentPageIDs
            for pageID in pagesToWrite {
                guard let page = workspace.pages[pageID], let item = workspace.items[pageID] else { continue }
                try upsert(page: page, item: item, recordHistory: recordHistory)
            }
            try deleteMissingRows(table: "page_documents", idColumn: "page_id", keeping: currentPageIDs)
            try deleteMissingRows(table: "page_search", idColumn: "page_id", keeping: currentPageIDs)
            try execute("DELETE FROM page_history WHERE page_id NOT IN (SELECT page_id FROM page_documents)")
            try insertMutationReceipt(
                changedPageIDs: (changedPageIDs ?? currentPageIDs).sorted(),
                deletedItemIDs: previousItemIDs.subtracting(currentItemIDs).sorted()
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func search(_ queryText: String, limit: Int = 40) throws -> [LibrarySearchResult] {
        let tokens = queryText
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0).replacingOccurrences(of: "\"", with: "\"\"") }
        guard !tokens.isEmpty else { return [] }
        let expression = tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
        var results: [LibrarySearchResult] = []
        let sql = """
        SELECT page_search.page_id, page_search.title,
               snippet(page_search, 2, '‹', '›', ' … ', 18), bm25(page_search)
        FROM page_search
        JOIN library_items ON library_items.id = page_search.page_id
        WHERE page_search MATCH ? AND library_items.trashed_at IS NULL
        ORDER BY bm25(page_search)
        LIMIT ?
        """
        try query(sql, bindings: [.text(expression), .integer(Int64(max(1, limit)))]) { statement in
            guard let pageID = Self.text(statement, 0), let title = Self.text(statement, 1) else { return }
            results.append(LibrarySearchResult(
                pageID: pageID,
                title: title,
                snippet: Self.text(statement, 2) ?? "",
                score: sqlite3_column_double(statement, 3)
            ))
        }
        return results
    }

    public func history(for pageID: String, limit: Int = 100) throws -> [PageHistoryEntry] {
        var entries: [PageHistoryEntry] = []
        try query(
            "SELECT id, created_at, label FROM page_history WHERE page_id = ? ORDER BY created_at DESC LIMIT ?",
            bindings: [.text(pageID), .integer(Int64(max(1, limit)))]
        ) { statement in
            guard let id = Self.text(statement, 0) else { return }
            entries.append(PageHistoryEntry(
                id: id,
                pageID: pageID,
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)),
                label: Self.text(statement, 2)
            ))
        }
        return entries
    }

    public func document(forHistoryEntry id: String) throws -> BlockDocument {
        var result: BlockDocument?
        try query("SELECT document_json FROM page_history WHERE id = ?", bindings: [.text(id)]) { statement in
            guard let data = Self.data(statement, 0) else { return }
            result = try decoder.decode(BlockDocument.self, from: data)
        }
        guard let result else { throw LibraryStoreError.corruptData("History entry \(id) was not found") }
        return result
    }

    public func revision(for pageID: String) throws -> Int64? {
        try existingPage(pageID)?.revision
    }

    public func checkpoint() throws {
        try execute("PRAGMA wal_checkpoint(PASSIVE)")
    }

    public func pendingMutationReceipts(limit: Int = 256) throws -> [LibraryMutationReceipt] {
        var receipts: [LibraryMutationReceipt] = []
        try query(
            """
            SELECT id, changed_page_ids_json, deleted_item_ids_json,
                   requires_full_inventory, created_at
            FROM sync_mutation_receipts
            ORDER BY created_at, id
            LIMIT ?
            """,
            bindings: [.integer(Int64(max(1, limit)))]
        ) { statement in
            guard let id = Self.text(statement, 0),
                  let changedJSON = Self.text(statement, 1),
                  let deletedJSON = Self.text(statement, 2),
                  let changedData = changedJSON.data(using: .utf8),
                  let deletedData = deletedJSON.data(using: .utf8) else {
                throw LibraryStoreError.corruptData("A sync mutation receipt is unreadable")
            }
            receipts.append(
                LibraryMutationReceipt(
                    id: id,
                    changedPageIDs: try decoder.decode([String].self, from: changedData),
                    deletedItemIDs: try decoder.decode([String].self, from: deletedData),
                    requiresFullInventory: sqlite3_column_int(statement, 3) != 0,
                    createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4))
                )
            )
        }
        return receipts
    }

    public func acknowledgeMutationReceipts(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for id in ids {
                try run(
                    "DELETE FROM sync_mutation_receipts WHERE id = ?",
                    bindings: [.text(id)]
                )
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Creates a transactionally consistent, portable SQLite backup while the
    /// live WAL database remains open for normal reads and writes.
    public func backup(to destinationURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        var destination: OpaquePointer?
        let openResult = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let destination else {
            if let destination { sqlite3_close(destination) }
            throw LibraryStoreError.openFailed("The backup destination could not be opened")
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", database, "main") else {
            throw LibraryStoreError.sqlite(
                code: sqlite3_errcode(destination),
                message: String(cString: sqlite3_errmsg(destination))
            )
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw LibraryStoreError.sqlite(
                code: finishResult == SQLITE_OK ? stepResult : finishResult,
                message: String(cString: sqlite3_errmsg(destination))
            )
        }
    }

    private func upsert(_ item: LibraryItem) throws {
        let sql = """
        INSERT INTO library_items (
          id, kind, parent_id, sort_key, title, icon, is_favorite,
          created_at, updated_at, last_opened_at, trashed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          kind=excluded.kind, parent_id=excluded.parent_id, sort_key=excluded.sort_key,
          title=excluded.title, icon=excluded.icon, is_favorite=excluded.is_favorite,
          created_at=excluded.created_at, updated_at=excluded.updated_at,
          last_opened_at=excluded.last_opened_at, trashed_at=excluded.trashed_at
        """
        try run(sql, bindings: [
            .text(item.id), .text(item.kind.rawValue), item.parentID.map(Binding.text) ?? .null,
            .double(item.sortKey), .text(item.title), .text(item.icon), .integer(item.isFavorite ? 1 : 0),
            .double(item.createdAt.timeIntervalSinceReferenceDate), .double(item.updatedAt.timeIntervalSinceReferenceDate),
            item.lastOpenedAt.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null,
            item.trashedAt.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null,
        ])
        if item.kind == .page {
            try run("UPDATE page_search SET title = ? WHERE page_id = ?", bindings: [.text(item.title), .text(item.id)])
        }
    }

    private func upsert(page: PageRecord, item: LibraryItem, recordHistory: Bool) throws {
        let data = try encoder.encode(page.document)
        let previous = try existingPage(page.id)
        if recordHistory, let previous, previous.data != data {
            try run(
                "INSERT INTO page_history (id, page_id, document_json, created_at, label) VALUES (?, ?, ?, ?, NULL)",
                bindings: [.text(UUID().uuidString.lowercased()), .text(page.id), .blob(previous.data), .double(Date.now.timeIntervalSinceReferenceDate)]
            )
            try run(
                "DELETE FROM page_history WHERE page_id = ? AND id NOT IN (SELECT id FROM page_history WHERE page_id = ? ORDER BY created_at DESC LIMIT 100)",
                bindings: [.text(page.id), .text(page.id)]
            )
        }
        let revision = (previous?.revision ?? 0) + (previous?.data == data ? 0 : 1)
        let plainText = Self.plainText(page.document)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try run(
            """
            INSERT INTO page_documents (page_id, document_json, plain_text, revision, checksum, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(page_id) DO UPDATE SET document_json=excluded.document_json,
              plain_text=excluded.plain_text, revision=excluded.revision,
              checksum=excluded.checksum, updated_at=excluded.updated_at
            """,
            bindings: [
                .text(page.id), .blob(data), .text(plainText), .integer(revision),
                .text(checksum), .double(page.updatedAt.timeIntervalSinceReferenceDate),
            ]
        )
        try run("DELETE FROM page_search WHERE page_id = ?", bindings: [.text(page.id)])
        try run(
            "INSERT INTO page_search (page_id, title, body) VALUES (?, ?, ?)",
            bindings: [.text(page.id), .text(item.title), .text(plainText)]
        )
    }

    private func existingPage(_ pageID: String) throws -> (data: Data, revision: Int64)? {
        var result: (Data, Int64)?
        try query(
            "SELECT document_json, revision FROM page_documents WHERE page_id = ?",
            bindings: [.text(pageID)]
        ) { statement in
            if let data = Self.data(statement, 0) {
                result = (data, sqlite3_column_int64(statement, 1))
            }
        }
        return result
    }

    private func metadataValue(for key: String) throws -> String? {
        var value: String?
        try query("SELECT value FROM metadata WHERE key = ?", bindings: [.text(key)]) { statement in
            value = Self.text(statement, 0)
        }
        return value
    }

    private func setMetadata(_ key: String, value: String) throws {
        try run(
            "INSERT INTO metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            bindings: [.text(key), .text(value)]
        )
    }

    private func deleteMetadata(_ key: String) throws {
        try run("DELETE FROM metadata WHERE key = ?", bindings: [.text(key)])
    }

    private func deleteMissingRows(table: String, idColumn: String, keeping ids: Set<String>) throws {
        guard !ids.isEmpty else {
            try execute("DELETE FROM \(table)")
            return
        }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try run(
            "DELETE FROM \(table) WHERE \(idColumn) NOT IN (\(placeholders))",
            bindings: ids.sorted().map(Binding.text)
        )
    }

    private func allItemIDs() throws -> Set<String> {
        var ids: Set<String> = []
        try query("SELECT id FROM library_items") { statement in
            if let id = Self.text(statement, 0) { ids.insert(id) }
        }
        return ids
    }

    private func insertMutationReceipt(
        changedPageIDs: [String],
        deletedItemIDs: [String]
    ) throws {
        let changedData = try encoder.encode(changedPageIDs)
        let deletedData = try encoder.encode(deletedItemIDs)
        guard let changedJSON = String(data: changedData, encoding: .utf8),
              let deletedJSON = String(data: deletedData, encoding: .utf8) else {
            throw LibraryStoreError.corruptData("A sync mutation receipt could not be encoded")
        }
        try run(
            """
            INSERT INTO sync_mutation_receipts (
              id, changed_page_ids_json, deleted_item_ids_json,
              requires_full_inventory, created_at
            ) VALUES (?, ?, ?, 1, ?)
            """,
            bindings: [
                .text(UUID().uuidString.lowercased()),
                .text(changedJSON),
                .text(deletedJSON),
                .double(Date.now.timeIntervalSinceReferenceDate),
            ]
        )

        var count = 0
        try query("SELECT COUNT(*) FROM sync_mutation_receipts") { statement in
            count = Int(sqlite3_column_int64(statement, 0))
        }
        guard count > 256 else { return }

        // A full inventory receipt subsumes all earlier per-commit hints. The
        // sync adapter compares current membership against the last cloud
        // manifest, so deletions remain discoverable after compaction.
        try execute("DELETE FROM sync_mutation_receipts")
        let currentPageIDs = try allPageIDs().sorted()
        let currentData = try encoder.encode(currentPageIDs)
        guard let currentJSON = String(data: currentData, encoding: .utf8) else {
            throw LibraryStoreError.corruptData("A compacted sync receipt could not be encoded")
        }
        try run(
            """
            INSERT INTO sync_mutation_receipts (
              id, changed_page_ids_json, deleted_item_ids_json,
              requires_full_inventory, created_at
            ) VALUES (?, ?, '[]', 1, ?)
            """,
            bindings: [
                .text(UUID().uuidString.lowercased()),
                .text(currentJSON),
                .double(Date.now.timeIntervalSinceReferenceDate),
            ]
        )
    }

    private func allPageIDs() throws -> Set<String> {
        var ids: Set<String> = []
        try query("SELECT page_id FROM page_documents") { statement in
            if let id = Self.text(statement, 0) { ids.insert(id) }
        }
        return ids
    }

    private enum Binding {
        case text(String)
        case blob(Data)
        case integer(Int64)
        case double(Double)
        case null
    }

    private func execute(_ sql: String) throws {
        try Self.execute(database, sql)
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &message)
        guard code == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw LibraryStoreError.sqlite(code: code, message: detail)
        }
    }

    private func run(_ sql: String, bindings: [Binding] = []) throws {
        try withStatement(sql, bindings: bindings) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE else { throw sqliteError(code) }
        }
    }

    private func query(
        _ sql: String,
        bindings: [Binding] = [],
        row: (OpaquePointer) throws -> Void
    ) throws {
        try withStatement(sql, bindings: bindings) { statement in
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw sqliteError(code) }
                try row(statement)
            }
        }
    }

    private func withStatement(
        _ sql: String,
        bindings: [Binding],
        body: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw sqliteError(code) }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            try bind(binding, to: statement, index: Int32(offset + 1))
        }
        try body(statement)
    }

    private func bind(_ binding: Binding, to statement: OpaquePointer, index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let code: Int32
        switch binding {
        case let .text(value): code = sqlite3_bind_text(statement, index, value, -1, transient)
        case let .blob(data):
            code = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
            }
        case let .integer(value): code = sqlite3_bind_int64(statement, index, value)
        case let .double(value): code = sqlite3_bind_double(statement, index, value)
        case .null: code = sqlite3_bind_null(statement, index)
        }
        guard code == SQLITE_OK else { throw sqliteError(code) }
    }

    private func sqliteError(_ code: Int32) -> LibraryStoreError {
        LibraryStoreError.sqlite(code: code, message: String(cString: sqlite3_errmsg(database)))
    }

    private static func migrate(_ database: OpaquePointer) throws {
        let version = sqlite3_user_version(database)
        guard version <= currentSchemaVersion else {
            throw LibraryStoreError.corruptData("Database schema \(version) is newer than supported schema \(currentSchemaVersion)")
        }
        try execute(database, "BEGIN IMMEDIATE")
        do {
            if version < 1 {
                try execute(database, "CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
                try execute(database, """
                CREATE TABLE library_items (
                  id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, parent_id TEXT,
                  sort_key REAL NOT NULL, title TEXT NOT NULL, icon TEXT NOT NULL,
                  is_favorite INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL,
                  updated_at REAL NOT NULL, last_opened_at REAL, trashed_at REAL
                )
                """)
                try execute(database, "CREATE INDEX library_parent_sort ON library_items(parent_id, sort_key)")
                try execute(database, "CREATE INDEX library_recents ON library_items(last_opened_at DESC)")
                try execute(database, """
                CREATE TABLE page_documents (
                  page_id TEXT PRIMARY KEY NOT NULL, document_json BLOB NOT NULL,
                  plain_text TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
                  checksum TEXT NOT NULL, updated_at REAL NOT NULL
                )
                """)
                try execute(database, """
                CREATE TABLE page_history (
                  id TEXT PRIMARY KEY NOT NULL, page_id TEXT NOT NULL,
                  document_json BLOB NOT NULL, created_at REAL NOT NULL, label TEXT,
                  FOREIGN KEY(page_id) REFERENCES page_documents(page_id) ON DELETE CASCADE
                )
                """)
                try execute(database, "CREATE INDEX page_history_page_date ON page_history(page_id, created_at DESC)")
                try execute(database, "CREATE VIRTUAL TABLE page_search USING fts5(page_id UNINDEXED, title, body, tokenize='unicode61')")
                try execute(database, "PRAGMA user_version = 1")
            }
            if version < 2 {
                // Version 1 used Unix-relative seconds. Foundation stores Date
                // relative to 2001, so subtraction and addition lost precision.
                let offset = 978_307_200
                try execute(database, "UPDATE library_items SET created_at = created_at - \(offset), updated_at = updated_at - \(offset), last_opened_at = CASE WHEN last_opened_at IS NULL THEN NULL ELSE last_opened_at - \(offset) END, trashed_at = CASE WHEN trashed_at IS NULL THEN NULL ELSE trashed_at - \(offset) END")
                try execute(database, "UPDATE page_documents SET updated_at = updated_at - \(offset)")
                try execute(database, "UPDATE page_history SET created_at = created_at - \(offset)")
                try execute(database, "PRAGMA user_version = 2")
            }
            if version < 3 {
                try execute(database, """
                CREATE TABLE sync_mutation_receipts (
                  id TEXT PRIMARY KEY NOT NULL,
                  changed_page_ids_json TEXT NOT NULL,
                  deleted_item_ids_json TEXT NOT NULL,
                  requires_full_inventory INTEGER NOT NULL DEFAULT 1,
                  created_at REAL NOT NULL
                )
                """)
                try execute(database, "CREATE INDEX sync_mutation_receipts_created ON sync_mutation_receipts(created_at, id)")
                try execute(database, """
                INSERT INTO sync_mutation_receipts (
                  id, changed_page_ids_json, deleted_item_ids_json,
                  requires_full_inventory, created_at
                )
                SELECT lower(hex(randomblob(16))), '[]', '[]', 1,
                       CAST(strftime('%s', 'now') AS REAL) - 978307200
                WHERE EXISTS (SELECT 1 FROM page_documents LIMIT 1)
                """)
                try execute(database, "PRAGMA user_version = 3")
            }
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    private static func plainText(_ document: BlockDocument) -> String {
        document.flattenedNodes()
            .compactMap { _, node in node.delta?.plainText.nilIfEmpty }
            .joined(separator: "\n")
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private static func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private static func date(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private func sqlite3_user_version(_ database: OpaquePointer) -> Int32 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
          let statement else { return 0 }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return sqlite3_column_int(statement, 0)
}
