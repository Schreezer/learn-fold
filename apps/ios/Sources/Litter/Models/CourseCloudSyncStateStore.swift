import Foundation
@preconcurrency import SQLite3

enum CourseCloudChangeKind: String, Codable, Sendable {
    case save
    case delete
    case zoneDelete
    case zonePurge
    case encryptedDataReset
}

struct CourseCloudInboxEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let accountID: String
    let zoneName: String
    let recordName: String
    let changeKind: CourseCloudChangeKind
    let payload: Data?
    let durableAssetPath: String?
    let checksum: String?
    let receivedAt: Date
}

struct CourseCloudOutboxEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let accountID: String
    let workspaceID: String
    let zoneName: String
    let recordName: String
    let changeKind: CourseCloudChangeKind
    let payload: Data?
    let mutationVersion: CourseSyncMutationVersion?
    let createdAt: Date
}

enum CourseCloudCourseProvenance: String, Codable, Sendable {
    case localOnly
    case cloudAccount
    case copiedFromAccount
}

struct CourseCloudCourseProvenanceRecord: Equatable, Sendable {
    let provenance: CourseCloudCourseProvenance
    let accountID: String?
    let copiedFromAccountID: String?
}

struct CourseCloudStoredHead: Equatable, Sendable {
    let head: CourseCloudHead
    let systemFields: Data
}

struct CourseCloudAccountChange: Codable, Equatable, Sendable {
    let previousAccountID: String?
    let currentAccountID: String?
    let occurredAt: Date
}

/// Durable local state for CKSyncEngine.
///
/// The CloudKit delegate must first copy temporary CKAsset files into durable
/// app staging, then call `commitFetchedBatch`. Inbox rows and the matching
/// engine state serialization commit in one SQLite transaction, so a crash
/// cannot advance the CloudKit cursor past unapplied course data.
actor CourseCloudSyncStateStore {
    // SQLite owns this handle for the store's entire lifetime. It never leaves
    // this actor, but actor deinits are nonisolated under strict concurrency.
    // The immutable pointer must therefore be explicitly available to deinit
    // for `sqlite3_close`; all database use still occurs on this actor.
    private nonisolated(unsafe) let database: OpaquePointer
    private let path: String

    init(url: URL) throws {
        path = url.path
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw CourseCloudSyncStateError.openFailed(url.path)
        }
        database = handle
        sqlite3_busy_timeout(handle, 3_000)

        do {
            try Self.execute("PRAGMA journal_mode = WAL", database: handle)
            try Self.execute("PRAGMA synchronous = FULL", database: handle)
            try Self.execute("PRAGMA foreign_keys = ON", database: handle)
            try Self.migrate(database: handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func engineState(accountID: String) throws -> Data? {
        try queryOne(
            "SELECT state_blob FROM engine_state WHERE account_id = ?",
            bindings: [.text(accountID)]
        ) { statement in
            guard let state = Self.data(statement, column: 0) else {
                throw CourseCloudSyncStateError.corruptRow("engine_state")
            }
            return state
        }
    }

    func commitFetchedBatch(
        accountID: String,
        stateSerialization: Data,
        entries: [CourseCloudInboxEntry]
    ) throws {
        guard !accountID.isEmpty,
              entries.allSatisfy({ $0.accountID == accountID }) else {
            throw CourseCloudSyncStateError.accountScopeMismatch
        }

        try transaction {
            try ensureAccountPartition(accountID)
            for entry in entries {
                try run(
                    """
                    INSERT OR IGNORE INTO inbox (
                      id, account_id, zone_name, record_name, change_kind,
                      payload, durable_asset_path, checksum, received_at, applied_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                    bindings: [
                        .text(entry.id),
                        .text(accountID),
                        .text(entry.zoneName),
                        .text(entry.recordName),
                        .text(entry.changeKind.rawValue),
                        entry.payload.map(Binding.blob) ?? .null,
                        entry.durableAssetPath.map(Binding.text) ?? .null,
                        entry.checksum.map(Binding.text) ?? .null,
                        .double(entry.receivedAt.timeIntervalSince1970),
                    ]
                )
            }
            try run(
                """
                INSERT INTO engine_state (account_id, state_blob, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(account_id) DO UPDATE SET
                  state_blob=excluded.state_blob, updated_at=excluded.updated_at
                """,
                bindings: [
                    .text(accountID),
                    .blob(stateSerialization),
                    .double(Date.now.timeIntervalSince1970),
                ]
            )
        }
    }

    func pendingInbox(accountID: String, limit: Int = 200) throws -> [CourseCloudInboxEntry] {
        var result: [CourseCloudInboxEntry] = []
        try query(
            """
            SELECT id, zone_name, record_name, change_kind, payload,
                   durable_asset_path, checksum, received_at
            FROM inbox
            WHERE account_id = ? AND applied_at IS NULL
            ORDER BY received_at, id
            LIMIT ?
            """,
            bindings: [.text(accountID), .integer(Int64(max(1, limit)))]
        ) { statement in
            guard let id = Self.text(statement, column: 0),
                  let zoneName = Self.text(statement, column: 1),
                  let recordName = Self.text(statement, column: 2),
                  let kindRaw = Self.text(statement, column: 3),
                  let kind = CourseCloudChangeKind(rawValue: kindRaw) else {
                throw CourseCloudSyncStateError.corruptRow("inbox")
            }
            result.append(
                CourseCloudInboxEntry(
                    id: id,
                    accountID: accountID,
                    zoneName: zoneName,
                    recordName: recordName,
                    changeKind: kind,
                    payload: Self.data(statement, column: 4),
                    durableAssetPath: Self.text(statement, column: 5),
                    checksum: Self.text(statement, column: 6),
                    receivedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
                )
            )
        }
        return result
    }

    func markInboxApplied(accountID: String, entryIDs: [String]) throws {
        guard !entryIDs.isEmpty else { return }
        try transaction {
            for id in entryIDs {
                try run(
                    "UPDATE inbox SET applied_at = ? WHERE account_id = ? AND id = ?",
                    bindings: [
                        .double(Date.now.timeIntervalSince1970),
                        .text(accountID),
                        .text(id),
                    ]
                )
            }
        }
    }

    func enqueue(_ entry: CourseCloudOutboxEntry) throws {
        guard !entry.accountID.isEmpty else {
            throw CourseCloudSyncStateError.accountScopeMismatch
        }
        let versionData = try entry.mutationVersion.map {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode($0)
        }

        try transaction {
            try ensureAccountPartition(entry.accountID)
            try run(
                """
                INSERT OR IGNORE INTO outbox (
                  id, account_id, workspace_id, zone_name, record_name,
                  change_kind, payload, mutation_version, created_at, sent_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                bindings: [
                    .text(entry.id),
                    .text(entry.accountID),
                    .text(entry.workspaceID),
                    .text(entry.zoneName),
                    .text(entry.recordName),
                    .text(entry.changeKind.rawValue),
                    entry.payload.map(Binding.blob) ?? .null,
                    versionData.map(Binding.blob) ?? .null,
                    .double(entry.createdAt.timeIntervalSince1970),
                ]
            )
        }
    }

    func pendingOutbox(accountID: String, limit: Int = 200) throws -> [CourseCloudOutboxEntry] {
        var result: [CourseCloudOutboxEntry] = []
        try query(
            """
            SELECT outbox.id, outbox.workspace_id, outbox.zone_name,
                   outbox.record_name, outbox.change_kind, outbox.payload,
                   outbox.mutation_version, outbox.created_at
            FROM outbox
            JOIN account_partitions USING (account_id)
            WHERE outbox.account_id = ? AND outbox.sent_at IS NULL
              AND account_partitions.sealed_at IS NULL
            ORDER BY outbox.created_at, outbox.id
            LIMIT ?
            """,
            bindings: [.text(accountID), .integer(Int64(max(1, limit)))]
        ) { statement in
            guard let id = Self.text(statement, column: 0),
                  let workspaceID = Self.text(statement, column: 1),
                  let zoneName = Self.text(statement, column: 2),
                  let recordName = Self.text(statement, column: 3),
                  let kindRaw = Self.text(statement, column: 4),
                  let kind = CourseCloudChangeKind(rawValue: kindRaw) else {
                throw CourseCloudSyncStateError.corruptRow("outbox")
            }
            let version: CourseSyncMutationVersion?
            if let data = Self.data(statement, column: 6) {
                version = try JSONDecoder().decode(CourseSyncMutationVersion.self, from: data)
            } else {
                version = nil
            }
            result.append(
                CourseCloudOutboxEntry(
                    id: id,
                    accountID: accountID,
                    workspaceID: workspaceID,
                    zoneName: zoneName,
                    recordName: recordName,
                    changeKind: kind,
                    payload: Self.data(statement, column: 5),
                    mutationVersion: version,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
                )
            )
        }
        return result
    }

    func outboxEntry(
        accountID: String,
        recordName: String
    ) throws -> CourseCloudOutboxEntry? {
        var result: CourseCloudOutboxEntry?
        try query(
            """
            SELECT id, workspace_id, zone_name, record_name, change_kind,
                   payload, mutation_version, created_at
            FROM outbox
            WHERE account_id = ? AND record_name = ?
            ORDER BY created_at DESC, id DESC
            LIMIT 1
            """,
            bindings: [.text(accountID), .text(recordName)]
        ) { statement in
            guard let id = Self.text(statement, column: 0),
                  let workspaceID = Self.text(statement, column: 1),
                  let zoneName = Self.text(statement, column: 2),
                  let resolvedRecordName = Self.text(statement, column: 3),
                  let kindRaw = Self.text(statement, column: 4),
                  let kind = CourseCloudChangeKind(rawValue: kindRaw) else {
                throw CourseCloudSyncStateError.corruptRow("outbox")
            }
            let version = try Self.data(statement, column: 6).map {
                try JSONDecoder().decode(CourseSyncMutationVersion.self, from: $0)
            }
            result = CourseCloudOutboxEntry(
                id: id,
                accountID: accountID,
                workspaceID: workspaceID,
                zoneName: zoneName,
                recordName: resolvedRecordName,
                changeKind: kind,
                payload: Self.data(statement, column: 5),
                mutationVersion: version,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            )
        }
        return result
    }

    func supersedePendingHead(
        accountID: String,
        workspaceID: String,
        recordName: String
    ) throws {
        try run(
            """
            UPDATE outbox SET sent_at = ?
            WHERE account_id = ? AND workspace_id = ? AND record_name = ?
              AND sent_at IS NULL
            """,
            bindings: [
                .double(Date.now.timeIntervalSince1970),
                .text(accountID),
                .text(workspaceID),
                .text(recordName),
            ]
        )
    }

    func replaceOutboxPayload(entryID: String, payload: Data) throws {
        try run(
            "UPDATE outbox SET payload = ? WHERE id = ? AND sent_at IS NULL",
            bindings: [.blob(payload), .text(entryID)]
        )
    }

    func markOutboxSent(accountID: String, entryIDs: [String]) throws {
        guard !entryIDs.isEmpty else { return }
        try transaction {
            for id in entryIDs {
                try run(
                    "UPDATE outbox SET sent_at = ? WHERE account_id = ? AND id = ?",
                    bindings: [
                        .double(Date.now.timeIntervalSince1970),
                        .text(accountID),
                        .text(id),
                    ]
                )
            }
        }
    }

    func markOutboxSent(accountID: String, recordIDs: [String]) throws {
        guard !recordIDs.isEmpty else { return }
        try transaction {
            for recordID in recordIDs {
                try run(
                    "UPDATE outbox SET sent_at = ? WHERE account_id = ? AND record_name = ?",
                    bindings: [
                        .double(Date.now.timeIntervalSince1970),
                        .text(accountID),
                        .text(recordID),
                    ]
                )
            }
        }
    }

    func pendingOutbox(
        accountID: String,
        recordName: String
    ) throws -> CourseCloudOutboxEntry? {
        try pendingOutbox(accountID: accountID, limit: 10_000)
            .first(where: { $0.recordName == recordName })
    }

    func sealAccount(_ accountID: String, change: CourseCloudAccountChange) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let changeData = try encoder.encode(change)
        try transaction {
            try ensureAccountPartition(accountID)
            try run(
                "UPDATE account_partitions SET sealed_at = ?, account_change = ? WHERE account_id = ?",
                bindings: [
                    .double(change.occurredAt.timeIntervalSince1970),
                    .blob(changeData),
                    .text(accountID),
                ]
            )
        }
    }

    func activateAccount(_ accountID: String) throws {
        try transaction {
            try ensureAccountPartition(accountID)
            try run(
                """
                UPDATE account_partitions
                SET sealed_at = NULL, account_change = NULL
                WHERE account_id = ?
                """,
                bindings: [.text(accountID)]
            )
        }
    }

    func isAccountSealed(_ accountID: String) throws -> Bool {
        try queryOne(
            "SELECT sealed_at FROM account_partitions WHERE account_id = ?",
            bindings: [.text(accountID)]
        ) { statement in
            sqlite3_column_type(statement, 0) != SQLITE_NULL
        } ?? false
    }

    func recordMigrationReceipt(
        accountID: String,
        workspaceID: String,
        contentChecksum: String
    ) throws {
        try transaction {
            try ensureAccountPartition(accountID)
            try run(
                """
                INSERT OR IGNORE INTO migration_receipts (
                  account_id, workspace_id, content_checksum, migrated_at
                ) VALUES (?, ?, ?, ?)
                """,
                bindings: [
                    .text(accountID),
                    .text(workspaceID),
                    .text(contentChecksum),
                    .double(Date.now.timeIntervalSince1970),
                ]
            )
        }
    }

    func hasMigrationReceipt(
        accountID: String,
        workspaceID: String,
        contentChecksum: String
    ) throws -> Bool {
        try queryOne(
            """
            SELECT 1 FROM migration_receipts
            WHERE account_id = ? AND workspace_id = ? AND content_checksum = ?
            """,
            bindings: [.text(accountID), .text(workspaceID), .text(contentChecksum)]
        ) { _ in true } ?? false
    }

    func setCourseProvenance(
        workspaceID: String,
        provenance: CourseCloudCourseProvenance,
        accountID: String?,
        copiedFromAccountID: String? = nil
    ) throws {
        try run(
            """
            INSERT INTO course_provenance (
              workspace_id, provenance, account_id, copied_from_account_id, updated_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(workspace_id) DO UPDATE SET
              provenance=excluded.provenance,
              account_id=excluded.account_id,
              copied_from_account_id=excluded.copied_from_account_id,
              updated_at=excluded.updated_at
            """,
            bindings: [
                .text(workspaceID),
                .text(provenance.rawValue),
                accountID.map(Binding.text) ?? .null,
                copiedFromAccountID.map(Binding.text) ?? .null,
                .double(Date.now.timeIntervalSince1970),
            ]
        )
    }

    func courseProvenance(
        workspaceID: String
    ) throws -> CourseCloudCourseProvenanceRecord? {
        try queryOne(
            """
            SELECT provenance, account_id, copied_from_account_id
            FROM course_provenance
            WHERE workspace_id = ?
            """,
            bindings: [.text(workspaceID)]
        ) { statement in
            guard let rawValue = Self.text(statement, column: 0),
                  let provenance = CourseCloudCourseProvenance(rawValue: rawValue) else {
                throw CourseCloudSyncStateError.corruptRow("course_provenance")
            }
            return CourseCloudCourseProvenanceRecord(
                provenance: provenance,
                accountID: Self.text(statement, column: 1),
                copiedFromAccountID: Self.text(statement, column: 2)
            )
        }
    }

    func cloudHead(
        accountID: String,
        workspaceID: String
    ) throws -> CourseCloudStoredHead? {
        try queryOne(
            """
            SELECT head_blob, system_fields
            FROM cloud_heads
            WHERE account_id = ? AND workspace_id = ?
            """,
            bindings: [.text(accountID), .text(workspaceID)]
        ) { statement in
            guard let headData = Self.data(statement, column: 0),
                  let systemFields = Self.data(statement, column: 1) else {
                throw CourseCloudSyncStateError.corruptRow("cloud_heads")
            }
            return CourseCloudStoredHead(
                head: try JSONDecoder().decode(CourseCloudHead.self, from: headData),
                systemFields: systemFields
            )
        }
    }

    func setCloudHead(
        accountID: String,
        head: CourseCloudHead,
        systemFields: Data
    ) throws {
        let encoded = try JSONEncoder().encode(head)
        try transaction {
            try ensureAccountPartition(accountID)
            try run(
                """
                INSERT INTO cloud_heads (
                  account_id, workspace_id, head_blob, system_fields, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(account_id, workspace_id) DO UPDATE SET
                  head_blob=excluded.head_blob,
                  system_fields=excluded.system_fields,
                  updated_at=excluded.updated_at
                """,
                bindings: [
                    .text(accountID),
                    .text(head.workspaceID),
                    .blob(encoded),
                    .blob(systemFields),
                    .double(Date.now.timeIntervalSince1970),
                ]
            )
        }
    }

    func acceptSavedHead(
        accountID: String,
        entryID: String,
        head: CourseCloudHead,
        systemFields: Data,
        snapshot: Data
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let headData = try encoder.encode(head)
        try transaction {
            try ensureAccountPartition(accountID)
            try run(
                """
                UPDATE outbox SET sent_at = ?
                WHERE account_id = ? AND id = ? AND sent_at IS NULL
                """,
                bindings: [
                    .double(Date.now.timeIntervalSince1970),
                    .text(accountID),
                    .text(entryID),
                ]
            )
            guard sqlite3_changes(database) == 1 else {
                throw CourseCloudSyncStateError.accountScopeMismatch
            }
            try run(
                """
                INSERT INTO cloud_heads (
                  account_id, workspace_id, head_blob, system_fields, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(account_id, workspace_id) DO UPDATE SET
                  head_blob=excluded.head_blob,
                  system_fields=excluded.system_fields,
                  updated_at=excluded.updated_at
                """,
                bindings: [
                    .text(accountID),
                    .text(head.workspaceID),
                    .blob(headData),
                    .blob(systemFields),
                    .double(Date.now.timeIntervalSince1970),
                ]
            )
            try run(
                """
                INSERT INTO cloud_bases (
                  account_id, workspace_id, checksum, snapshot_blob, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(account_id, workspace_id) DO UPDATE SET
                  checksum=excluded.checksum,
                  snapshot_blob=excluded.snapshot_blob,
                  updated_at=excluded.updated_at
                """,
                bindings: [
                    .text(accountID),
                    .text(head.workspaceID),
                    .text(head.checksum),
                    .blob(snapshot),
                    .double(Date.now.timeIntervalSince1970),
                ]
            )
            let current: CourseSyncVersionVector
            if let data: Data = try queryOne(
                """
                SELECT vector_blob FROM workspace_vectors
                WHERE account_id = ? AND workspace_id = ?
                """,
                bindings: [.text(accountID), .text(head.workspaceID)]
            ) { statement in
                guard let data = Self.data(statement, column: 0) else {
                    throw CourseCloudSyncStateError.corruptRow("workspace_vectors")
                }
                return data
            } {
                current = try JSONDecoder().decode(CourseSyncVersionVector.self, from: data)
            } else {
                current = .init()
            }
            let vectorData = try encoder.encode(current.merged(with: head.version))
            try run(
                """
                INSERT INTO workspace_vectors (
                  account_id, workspace_id, vector_blob, updated_at
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(account_id, workspace_id) DO UPDATE SET
                  vector_blob=excluded.vector_blob,
                  updated_at=excluded.updated_at
                """,
                bindings: [
                    .text(accountID),
                    .text(head.workspaceID),
                    .blob(vectorData),
                    .double(Date.now.timeIntervalSince1970),
                ]
            )
        }
    }

    func observeWorkspaceVector(
        accountID: String,
        workspaceID: String,
        vector: CourseSyncVersionVector
    ) throws {
        try transaction {
            try ensureAccountPartition(accountID)
            let current: CourseSyncVersionVector
            if let data: Data = try queryOne(
                """
                SELECT vector_blob FROM workspace_vectors
                WHERE account_id = ? AND workspace_id = ?
                """,
                bindings: [.text(accountID), .text(workspaceID)]
            ) { statement in
                guard let data = Self.data(statement, column: 0) else {
                    throw CourseCloudSyncStateError.corruptRow("workspace_vectors")
                }
                return data
            } {
                current = try JSONDecoder().decode(CourseSyncVersionVector.self, from: data)
            } else {
                current = .init()
            }
            let encoded = try JSONEncoder().encode(current.merged(with: vector))
            try run(
                """
                INSERT INTO workspace_vectors (
                  account_id, workspace_id, vector_blob, updated_at
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(account_id, workspace_id) DO UPDATE SET
                  vector_blob=excluded.vector_blob,
                  updated_at=excluded.updated_at
                """,
                bindings: [
                    .text(accountID),
                    .text(workspaceID),
                    .blob(encoded),
                    .double(Date.now.timeIntervalSince1970),
                ]
            )
        }
    }

    func cloudBase(accountID: String, workspaceID: String) throws -> Data? {
        try queryOne(
            """
            SELECT snapshot_blob FROM cloud_bases
            WHERE account_id = ? AND workspace_id = ?
            """,
            bindings: [.text(accountID), .text(workspaceID)]
        ) { statement in
            guard let data = Self.data(statement, column: 0) else {
                throw CourseCloudSyncStateError.corruptRow("cloud_bases")
            }
            return data
        }
    }

    func setCloudBase(
        accountID: String,
        workspaceID: String,
        checksum: String,
        snapshot: Data
    ) throws {
        try transaction {
            try ensureAccountPartition(accountID)
            try run(
                """
                INSERT INTO cloud_bases (
                  account_id, workspace_id, checksum, snapshot_blob, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(account_id, workspace_id) DO UPDATE SET
                  checksum=excluded.checksum,
                  snapshot_blob=excluded.snapshot_blob,
                  updated_at=excluded.updated_at
                """,
                bindings: [
                    .text(accountID),
                    .text(workspaceID),
                    .text(checksum),
                    .blob(snapshot),
                    .double(Date.now.timeIntervalSince1970),
                ]
            )
        }
    }

    func nextMutationVersion(
        accountID: String,
        workspaceID: String,
        ancestorChecksum: String?
    ) throws -> CourseSyncMutationVersion {
        var result: CourseSyncMutationVersion?
        try transaction {
            try ensureAccountPartition(accountID)
            let replicaID: String
            if let existing: String = try queryOne(
                "SELECT value FROM sync_metadata WHERE key = 'replica_id'"
            ) { statement in
                guard let value = Self.text(statement, column: 0) else {
                    throw CourseCloudSyncStateError.corruptRow("sync_metadata")
                }
                return value
            } {
                replicaID = existing
            } else {
                replicaID = UUID().uuidString.lowercased()
                try run(
                    "INSERT INTO sync_metadata (key, value) VALUES ('replica_id', ?)",
                    bindings: [.text(replicaID)]
                )
            }

            let observed: CourseSyncVersionVector
            if let data: Data = try queryOne(
                """
                SELECT vector_blob FROM workspace_vectors
                WHERE account_id = ? AND workspace_id = ?
                """,
                bindings: [.text(accountID), .text(workspaceID)]
            ) { statement in
                guard let data = Self.data(statement, column: 0) else {
                    throw CourseCloudSyncStateError.corruptRow("workspace_vectors")
                }
                return data
            } {
                observed = try JSONDecoder().decode(CourseSyncVersionVector.self, from: data)
            } else {
                observed = CourseSyncVersionVector()
            }

            var advanced = observed
            let dot = advanced.nextDot(replicaID: replicaID)
            let encoded = try JSONEncoder().encode(advanced)
            try run(
                """
                INSERT INTO workspace_vectors (
                  account_id, workspace_id, vector_blob, updated_at
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(account_id, workspace_id) DO UPDATE SET
                  vector_blob=excluded.vector_blob,
                  updated_at=excluded.updated_at
                """,
                bindings: [
                    .text(accountID),
                    .text(workspaceID),
                    .blob(encoded),
                    .double(Date.now.timeIntervalSince1970),
                ]
            )
            result = CourseSyncMutationVersion(
                dot: dot,
                observed: observed,
                ancestorChecksum: ancestorChecksum
            )
        }
        guard let result else {
            throw CourseCloudSyncStateError.corruptRow("workspace_vectors")
        }
        return result
    }

    private nonisolated static func migrate(database: OpaquePointer) throws {
        func execute(_ sql: String) throws {
            try Self.execute(sql, database: database)
        }
        try execute(
            """
            CREATE TABLE IF NOT EXISTS account_partitions (
              account_id TEXT PRIMARY KEY NOT NULL,
              created_at REAL NOT NULL,
              sealed_at REAL,
              account_change BLOB
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS engine_state (
              account_id TEXT PRIMARY KEY NOT NULL,
              state_blob BLOB NOT NULL,
              updated_at REAL NOT NULL,
              FOREIGN KEY(account_id) REFERENCES account_partitions(account_id)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS inbox (
              id TEXT PRIMARY KEY NOT NULL,
              account_id TEXT NOT NULL,
              zone_name TEXT NOT NULL,
              record_name TEXT NOT NULL,
              change_kind TEXT NOT NULL,
              payload BLOB,
              durable_asset_path TEXT,
              checksum TEXT,
              received_at REAL NOT NULL,
              applied_at REAL,
              FOREIGN KEY(account_id) REFERENCES account_partitions(account_id)
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS inbox_pending ON inbox(account_id, applied_at, received_at)")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS outbox (
              id TEXT PRIMARY KEY NOT NULL,
              account_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              zone_name TEXT NOT NULL,
              record_name TEXT NOT NULL,
              change_kind TEXT NOT NULL,
              payload BLOB,
              mutation_version BLOB,
              created_at REAL NOT NULL,
              sent_at REAL,
              FOREIGN KEY(account_id) REFERENCES account_partitions(account_id)
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS outbox_pending ON outbox(account_id, sent_at, created_at)")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS migration_receipts (
              account_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              content_checksum TEXT NOT NULL,
              migrated_at REAL NOT NULL,
              PRIMARY KEY(account_id, workspace_id, content_checksum),
              FOREIGN KEY(account_id) REFERENCES account_partitions(account_id)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS course_provenance (
              workspace_id TEXT PRIMARY KEY NOT NULL,
              provenance TEXT NOT NULL,
              account_id TEXT,
              copied_from_account_id TEXT,
              updated_at REAL NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS cloud_bases (
              account_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              checksum TEXT NOT NULL,
              snapshot_blob BLOB NOT NULL,
              updated_at REAL NOT NULL,
              PRIMARY KEY(account_id, workspace_id),
              FOREIGN KEY(account_id) REFERENCES account_partitions(account_id)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_metadata (
              key TEXT PRIMARY KEY NOT NULL,
              value TEXT NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS workspace_vectors (
              account_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              vector_blob BLOB NOT NULL,
              updated_at REAL NOT NULL,
              PRIMARY KEY(account_id, workspace_id),
              FOREIGN KEY(account_id) REFERENCES account_partitions(account_id)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS cloud_heads (
              account_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              head_blob BLOB NOT NULL,
              system_fields BLOB NOT NULL,
              updated_at REAL NOT NULL,
              PRIMARY KEY(account_id, workspace_id),
              FOREIGN KEY(account_id) REFERENCES account_partitions(account_id)
            )
            """
        )
    }

    private func ensureAccountPartition(_ accountID: String) throws {
        try run(
            """
            INSERT OR IGNORE INTO account_partitions (account_id, created_at)
            VALUES (?, ?)
            """,
            bindings: [.text(accountID), .double(Date.now.timeIntervalSince1970)]
        )
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        try Self.execute(sql, database: database)
    }

    private nonisolated static func execute(
        _ sql: String,
        database: OpaquePointer
    ) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown"
            throw CourseCloudSyncStateError.sqlite(
                code: result,
                message: message,
                path: "course-cloud-sync.sqlite"
            )
        }
    }

    private func run(_ sql: String, bindings: [Binding] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(sqlite3_errcode(database))
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw sqliteError(result) }
    }

    private func query(
        _ sql: String,
        bindings: [Binding] = [],
        row: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(sqlite3_errcode(database))
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            case let code: throw sqliteError(code)
            }
        }
    }

    private func queryOne<T>(
        _ sql: String,
        bindings: [Binding] = [],
        row: (OpaquePointer) throws -> T
    ) throws -> T? {
        var result: T?
        try query(sql, bindings: bindings) { statement in
            if result == nil { result = try row(statement) }
        }
        return result
    }

    private enum Binding {
        case text(String)
        case blob(Data)
        case integer(Int64)
        case double(Double)
        case null
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor)
            case .blob(let value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        bytes.baseAddress,
                        Int32(bytes.count),
                        Self.transientDestructor
                    )
                }
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw sqliteError(result) }
        }
    }

    private static let transientDestructor = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }

    private static func data(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func sqliteError(_ code: Int32) -> CourseCloudSyncStateError {
        CourseCloudSyncStateError.sqlite(
            code: code,
            message: String(cString: sqlite3_errmsg(database)),
            path: path
        )
    }
}

enum CourseCloudSyncStateError: Error, Equatable, LocalizedError {
    case openFailed(String)
    case sqlite(code: Int32, message: String, path: String)
    case corruptRow(String)
    case accountScopeMismatch

    var errorDescription: String? {
        switch self {
        case .openFailed(let path): "Could not open course cloud sync state at \(path)."
        case .sqlite(let code, let message, let path):
            "Course cloud sync SQLite error \(code) at \(path): \(message)"
        case .corruptRow(let table): "Course cloud sync \(table) contains an unreadable row."
        case .accountScopeMismatch: "Course cloud sync data crossed iCloud account scopes."
        }
    }
}
