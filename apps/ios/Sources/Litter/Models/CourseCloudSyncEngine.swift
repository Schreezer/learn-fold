import CloudKit
import CryptoKit
import Foundation

enum CourseCloudRecordType {
    static let workspaceGeneration = "LFWorkspaceGenerationV1"
    static let generationCommit = "LFGenerationCommitV1"
    static let catalogEntry = "LFCourseCatalogEntryV1"
}

struct CourseCloudRecordEnvelope: Codable, Equatable, Sendable {
    let recordType: String
    let fields: [String: String]
    let assetPayload: Data?
}

enum CourseCloudSyncAvailability: Equatable, Sendable {
    case available
    case missingEntitlement
    case noAccount
    case failed(String)
}

enum CourseCloudSyncEngineError: LocalizedError {
    case notStarted
    case invalidEnvelope(String)
    case missingAsset(String)
    case checksumMismatch(String)
    case missingMergeBase(String)

    var errorDescription: String? {
        switch self {
        case .notStarted:
            "Course iCloud sync has not started."
        case .invalidEnvelope(let recordName):
            "The queued CloudKit record \(recordName) is invalid."
        case .missingAsset(let recordName):
            "The CloudKit record \(recordName) is missing its course payload."
        case .checksumMismatch(let recordName):
            "The CloudKit payload checksum did not match for \(recordName)."
        case .missingMergeBase(let workspaceID):
            "Course \(workspaceID) exists locally but has no trusted cloud merge base."
        }
    }
}

enum CourseCloudEntitlement {
    static let containerIdentifier = "iCloud.com.chirag.learnfold"

    static var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "LearnfoldCourseCloudSyncEnabled") as? Bool == true
    }
}

/// Owns CKSyncEngine transport for the private CloudKit database.
///
/// Local course SQLite remains authoritative. This actor only moves immutable,
/// checksummed workspace generations through CloudKit and durably journals
/// fetched changes before the CKSyncEngine cursor is advanced.
actor CourseCloudSyncEngine: CKSyncEngineDelegate {
    static let shared = CourseCloudSyncEngine()

    private var container: CKContainer?
    private let stateStore: CourseCloudSyncStateStore?
    private let stagingDirectory: URL?
    private var engine: CKSyncEngine?
    private var accountID: String?
    private var bufferedFetchedEntries: [CourseCloudInboxEntry] = []
    private var workspacesBeingQueued: Set<String> = []
    private(set) var availability: CourseCloudSyncAvailability = .missingEntitlement

    init(
        container: CKContainer? = nil,
        stateStore: CourseCloudSyncStateStore? = nil,
        stagingDirectory: URL? = nil
    ) {
        self.container = container
        if let stateStore, let stagingDirectory {
            self.stateStore = stateStore
            self.stagingDirectory = stagingDirectory
            return
        }

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let root = support.appendingPathComponent("Learnfold/CourseCloudSync", isDirectory: true)
        self.stagingDirectory = root.appendingPathComponent("Staging", isDirectory: true)
        self.stateStore = try? CourseCloudSyncStateStore(
            url: root.appendingPathComponent("course-cloud-sync.sqlite")
        )
    }

    func startIfAvailable() async {
        guard CourseCloudEntitlement.isEnabled else {
            availability = .missingEntitlement
            return
        }
        guard let stateStore, let stagingDirectory else {
            availability = .failed("Could not open the course sync state database.")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            let resolvedContainer = container
                ?? CKContainer(identifier: CourseCloudEntitlement.containerIdentifier)
            container = resolvedContainer
            let userRecordID = try await resolvedContainer.userRecordID()
            let resolvedAccountID = userRecordID.recordName
            let serializedData = try await stateStore.engineState(accountID: resolvedAccountID)
            let serializedState = try serializedData.map {
                try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
            }

            var configuration = CKSyncEngine.Configuration(
                database: resolvedContainer.privateCloudDatabase,
                stateSerialization: serializedState,
                delegate: self
            )
            configuration.automaticallySync = true
            configuration.subscriptionID = "learnfold-course-sync-v1"

            let syncEngine = CKSyncEngine(configuration)
            accountID = resolvedAccountID
            engine = syncEngine
            availability = .available

            if serializedState == nil {
                syncEngine.state.add(
                    pendingDatabaseChanges: Self.zoneIDs.map {
                        .saveZone(CKRecordZone(zoneID: $0))
                    }
                )
            }
            try await restorePendingOutbox(into: syncEngine, accountID: resolvedAccountID)
            let repositories = await CourseDocumentRegistry.shared.openRepositories()
            for repository in repositories {
                await queueRepositoryChangesIfNeeded(repository: repository)
            }
        } catch let error as CKError where error.code == .notAuthenticated {
            availability = .noAccount
        } catch {
            availability = .failed(error.localizedDescription)
        }
    }

    func fetchChanges() async -> Bool {
        guard let engine else { return false }
        do {
            try await engine.fetchChanges()
            return true
        } catch {
            availability = .failed(error.localizedDescription)
            return false
        }
    }

    func applyPendingFetchedChanges() async {
        guard let accountID else { return }
        do {
            try await drainInbox(accountID: accountID)
            availability = .available
        } catch {
            availability = .failed(error.localizedDescription)
        }
    }

    func queueWorkspaceGeneration(
        repository: CourseDocumentRepository,
        title: String? = nil
    ) async throws {
        guard let engine, let accountID, let stateStore else {
            throw CourseCloudSyncEngineError.notStarted
        }

        let mutationReceipts = try await repository.pendingSyncMutationReceipts(limit: 10_000)
        let draft = try await repository.exportSyncSnapshot(generationID: "checksum-probe")
        let workspaceID = draft.manifest.workspaceID
        let baseData = try await stateStore.cloudBase(
            accountID: accountID,
            workspaceID: workspaceID
        )
        let ancestorChecksum = try baseData.map {
            try Self.decoder.decode(CourseSyncWorkspaceSnapshot.self, from: $0).checksum
        }
        let mutationVersion = try await stateStore.nextMutationVersion(
            accountID: accountID,
            workspaceID: workspaceID,
            ancestorChecksum: ancestorChecksum
        )
        let receiptSeed = mutationReceipts.map(\.id).sorted().joined(separator: "\u{0}")
        let generationID = String(
            Self.sha256(
                Data(
                    "\(workspaceID)\u{0}\(draft.checksum)\u{0}\(receiptSeed)\u{0}\(CourseCloudSyncSchema.version)".utf8
                )
            ).prefix(32)
        )
        let snapshot = try await repository.exportSyncSnapshot(
            generationID: generationID,
            version: mutationVersion.resultingVector
        )
        let resolvedTitle = title
            ?? snapshot.items.first(where: { $0.id == snapshot.manifest.rootPageID })?.title
            ?? "Course"
        let payload = try Self.encoder.encode(snapshot)
        let generationBaseName = CourseSyncRecordName.generation(
            workspaceID: workspaceID,
            generationID: generationID
        )
        let generationRecordName = "\(generationBaseName).workspace.\(snapshot.checksum)"
        let commitRecordName = "\(generationBaseName).commit"
        let catalogRecordName = "\(generationBaseName).catalog"
        let commit = try CourseSyncGenerationCommit(
            workspaceID: workspaceID,
            generationID: generationID,
            previousGenerationID: snapshot.manifest.previousGenerationID,
            manifestShardNames: [],
            records: [
                .init(
                    recordName: generationRecordName,
                    kind: .workspaceManifest,
                    checksum: snapshot.checksum
                ),
            ],
            version: snapshot.manifest.version,
            createdAt: .now
        )

        let contentZone = CourseCloudSyncSchema.contentZoneName
        let catalogZone = CourseCloudSyncSchema.catalogZoneName
        let entries = [
            try Self.outboxEntry(
                accountID: accountID,
                workspaceID: workspaceID,
                zoneName: contentZone,
                recordName: generationRecordName,
                envelope: CourseCloudRecordEnvelope(
                    recordType: CourseCloudRecordType.workspaceGeneration,
                    fields: [
                        "workspaceID": workspaceID,
                        "generationID": generationID,
                        "checksum": snapshot.checksum,
                    ],
                    assetPayload: payload
                ),
                mutationVersion: mutationVersion
            ),
            try Self.outboxEntry(
                accountID: accountID,
                workspaceID: workspaceID,
                zoneName: contentZone,
                recordName: commitRecordName,
                envelope: CourseCloudRecordEnvelope(
                    recordType: CourseCloudRecordType.generationCommit,
                    fields: [
                        "workspaceID": workspaceID,
                        "generationID": generationID,
                        "checksum": snapshot.checksum,
                    ],
                    assetPayload: try Self.encoder.encode(commit)
                ),
                mutationVersion: mutationVersion
            ),
            try Self.outboxEntry(
                accountID: accountID,
                workspaceID: workspaceID,
                zoneName: catalogZone,
                recordName: catalogRecordName,
                envelope: CourseCloudRecordEnvelope(
                    recordType: CourseCloudRecordType.catalogEntry,
                    fields: [
                        "workspaceID": workspaceID,
                        "generationID": generationID,
                        "generationRecordName": generationRecordName,
                        "commitRecordName": commitRecordName,
                        "checksum": snapshot.checksum,
                        "title": resolvedTitle,
                    ],
                    assetPayload: nil
                ),
                mutationVersion: mutationVersion
            ),
        ]

        for entry in entries {
            try await stateStore.enqueue(entry)
        }
        try await repository.acknowledgeSyncMutationReceipts(ids: mutationReceipts.map(\.id))
        engine.state.add(
            pendingRecordZoneChanges: entries.map {
                .saveRecord(Self.recordID(zoneName: $0.zoneName, recordName: $0.recordName))
            }
        )
        try await engine.sendChanges()
        try await stateStore.recordMigrationReceipt(
            accountID: accountID,
            workspaceID: workspaceID,
            contentChecksum: snapshot.checksum
        )
        try await stateStore.setCourseProvenance(
            workspaceID: workspaceID,
            provenance: .cloudAccount,
            accountID: accountID
        )
    }

    func queueRepositoryChangesIfNeeded(
        repository: CourseDocumentRepository
    ) async {
        guard availability == .available else { return }
        let workspaceID = repository.workspaceID
        guard !workspacesBeingQueued.contains(workspaceID) else { return }
        workspacesBeingQueued.insert(workspaceID)
        defer { workspacesBeingQueued.remove(workspaceID) }
        do {
            guard !(try await repository.pendingSyncMutationReceipts()).isEmpty else { return }
            try await queueWorkspaceGeneration(repository: repository)
        } catch {
            availability = .failed(error.localizedDescription)
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let stateStore else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                guard let accountID else { return }
                let stateData = try Self.encoder.encode(update.stateSerialization)
                try await stateStore.commitFetchedBatch(
                    accountID: accountID,
                    stateSerialization: stateData,
                    entries: bufferedFetchedEntries
                )
                bufferedFetchedEntries.removeAll(keepingCapacity: true)
                try await drainInbox(accountID: accountID)

            case .accountChange(let change):
                try await handleAccountChange(change, syncEngine: syncEngine)

            case .fetchedRecordZoneChanges(let changes):
                guard let accountID else { return }
                for modification in changes.modifications {
                    bufferedFetchedEntries.append(
                        try stageFetchedRecord(modification.record, accountID: accountID)
                    )
                }
                for deletion in changes.deletions {
                    bufferedFetchedEntries.append(
                        CourseCloudInboxEntry(
                            id: Self.changeID(
                                recordID: deletion.recordID,
                                version: "delete-\(deletion.recordType)"
                            ),
                            accountID: accountID,
                            zoneName: deletion.recordID.zoneID.zoneName,
                            recordName: deletion.recordID.recordName,
                            changeKind: .delete,
                            payload: nil,
                            durableAssetPath: nil,
                            checksum: nil,
                            receivedAt: .now
                        )
                    )
                }

            case .fetchedDatabaseChanges(let changes):
                guard let accountID else { return }
                for deletion in changes.deletions where Self.zoneIDs.contains(deletion.zoneID) {
                    let kind: CourseCloudChangeKind
                    switch deletion.reason {
                    case .deleted: kind = .zoneDelete
                    case .purged: kind = .zonePurge
                    case .encryptedDataReset: kind = .encryptedDataReset
                    @unknown default: kind = .zonePurge
                    }
                    bufferedFetchedEntries.append(
                        CourseCloudInboxEntry(
                            id: Self.sha256(
                                Data(
                                    "\(accountID)\u{0}\(deletion.zoneID.zoneName)\u{0}\(kind.rawValue)".utf8
                                )
                            ),
                            accountID: accountID,
                            zoneName: deletion.zoneID.zoneName,
                            recordName: "__zone__",
                            changeKind: kind,
                            payload: nil,
                            durableAssetPath: nil,
                            checksum: nil,
                            receivedAt: .now
                        )
                    )
                }

            case .sentRecordZoneChanges(let changes):
                guard let accountID else { return }
                try await stateStore.markOutboxSent(
                    accountID: accountID,
                    recordIDs: changes.savedRecords.map(\.recordID.recordName)
                )
                try await acceptIdempotentServerRecords(
                    changes.failedRecordSaves,
                    accountID: accountID,
                    syncEngine: syncEngine
                )
                syncEngine.state.remove(
                    pendingRecordZoneChanges: changes.deletedRecordIDs.map {
                        .deleteRecord($0)
                    }
                )

            default:
                break
            }
        } catch {
            availability = .failed(error.localizedDescription)
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let accountID, let stateStore else { return nil }
        do {
            let outbox = try await stateStore.pendingOutbox(accountID: accountID, limit: 500)
            let byID = Dictionary(uniqueKeysWithValues: outbox.map {
                (Self.recordID(zoneName: $0.zoneName, recordName: $0.recordName), $0)
            })
            let pending = syncEngine.state.pendingRecordZoneChanges.filter {
                context.options.scope.contains($0)
            }
            return await CKSyncEngine.RecordZoneChangeBatch(
                pendingChanges: pending
            ) { recordID in
                guard let entry = byID[recordID] else { return nil }
                return try? await self.makeRecord(from: entry)
            }
        } catch {
            availability = .failed(error.localizedDescription)
            return nil
        }
    }

    private func restorePendingOutbox(
        into engine: CKSyncEngine,
        accountID: String
    ) async throws {
        guard let stateStore else { return }
        let outbox = try await stateStore.pendingOutbox(accountID: accountID, limit: 10_000)
        let alreadyPending = Set(engine.state.pendingRecordZoneChanges)
        let missing = outbox.compactMap { entry -> CKSyncEngine.PendingRecordZoneChange? in
            let change: CKSyncEngine.PendingRecordZoneChange
            let recordID = Self.recordID(zoneName: entry.zoneName, recordName: entry.recordName)
            switch entry.changeKind {
            case .save: change = .saveRecord(recordID)
            case .delete: change = .deleteRecord(recordID)
            default: return nil
            }
            return alreadyPending.contains(change) ? nil : change
        }
        engine.state.add(pendingRecordZoneChanges: missing)
    }

    private func makeRecord(from entry: CourseCloudOutboxEntry) async throws -> CKRecord? {
        guard entry.changeKind == .save, let payload = entry.payload else { return nil }
        let envelope = try Self.decoder.decode(CourseCloudRecordEnvelope.self, from: payload)
        let recordID = Self.recordID(zoneName: entry.zoneName, recordName: entry.recordName)
        let record = CKRecord(recordType: envelope.recordType, recordID: recordID)
        for (key, value) in envelope.fields {
            record[key] = value as CKRecordValue
        }
        record["schemaVersion"] = CourseCloudSyncSchema.version as CKRecordValue
        if let assetPayload = envelope.assetPayload {
            guard let stagingDirectory else { throw CourseCloudSyncEngineError.missingAsset(entry.recordName) }
            let outgoing = stagingDirectory
                .appendingPathComponent("Outgoing", isDirectory: true)
                .appendingPathComponent(entry.accountID, isDirectory: true)
            try FileManager.default.createDirectory(
                at: outgoing,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            let assetURL = outgoing.appendingPathComponent("\(entry.id).payload")
            if !FileManager.default.fileExists(atPath: assetURL.path) {
                try assetPayload.write(to: assetURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            record["payload"] = CKAsset(fileURL: assetURL)
            record["payloadChecksum"] = Self.sha256(assetPayload) as CKRecordValue
        }
        return record
    }

    private func stageFetchedRecord(
        _ record: CKRecord,
        accountID: String
    ) throws -> CourseCloudInboxEntry {
        let checksum = record["payloadChecksum"] as? String
        var durableAssetPath: String?
        if let asset = record["payload"] as? CKAsset {
            guard let sourceURL = asset.fileURL, let stagingDirectory else {
                throw CourseCloudSyncEngineError.missingAsset(record.recordID.recordName)
            }
            let incoming = stagingDirectory
                .appendingPathComponent("Incoming", isDirectory: true)
                .appendingPathComponent(accountID, isDirectory: true)
            try FileManager.default.createDirectory(
                at: incoming,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            let destination = incoming.appendingPathComponent(
                "\(Self.changeID(recordID: record.recordID, version: record.recordChangeTag ?? "new")).payload"
            )
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: destination.path
                )
            }
            if let checksum {
                let data = try Data(contentsOf: destination, options: .mappedIfSafe)
                guard Self.sha256(data) == checksum else {
                    try? FileManager.default.removeItem(at: destination)
                    throw CourseCloudSyncEngineError.checksumMismatch(record.recordID.recordName)
                }
            }
            durableAssetPath = destination.path
        }

        let metadata = CourseCloudFetchedRecordMetadata(
            recordType: record.recordType,
            fields: record.allKeys().reduce(into: [:]) { result, key in
                if let string = record[key] as? String { result[key] = string }
            }
        )
        return CourseCloudInboxEntry(
            id: Self.changeID(
                recordID: record.recordID,
                version: record.recordChangeTag ?? checksum ?? "new"
            ),
            accountID: accountID,
            zoneName: record.recordID.zoneID.zoneName,
            recordName: record.recordID.recordName,
            changeKind: .save,
            payload: try Self.encoder.encode(metadata),
            durableAssetPath: durableAssetPath,
            checksum: checksum,
            receivedAt: .now
        )
    }

    private func handleAccountChange(
        _ event: CKSyncEngine.Event.AccountChange,
        syncEngine: CKSyncEngine
    ) async throws {
        guard let stateStore else { return }
        let previous = accountID
        let current: String?
        switch event.changeType {
        case .signIn(let currentUser):
            current = currentUser.recordName
        case .signOut:
            current = nil
        case .switchAccounts(_, let currentUser):
            current = currentUser.recordName
        @unknown default:
            current = nil
        }
        if let previous, previous != current {
            try await stateStore.sealAccount(
                previous,
                change: CourseCloudAccountChange(
                    previousAccountID: previous,
                    currentAccountID: current,
                    occurredAt: .now
                )
            )
        }
        bufferedFetchedEntries.removeAll()
        accountID = current
        if let current {
            try await restorePendingOutbox(into: syncEngine, accountID: current)
            availability = .available
        } else {
            availability = .noAccount
        }
    }

    private func acceptIdempotentServerRecords(
        _ failures: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
        accountID: String,
        syncEngine: CKSyncEngine
    ) async throws {
        guard let stateStore else { return }
        for failure in failures {
            guard failure.error.code == .serverRecordChanged,
                  let server = failure.error.serverRecord,
                  let localChecksum = failure.record["checksum"] as? String,
                  server["checksum"] as? String == localChecksum else {
                continue
            }
            let recordID = failure.record.recordID
            try await stateStore.markOutboxSent(
                accountID: accountID,
                recordIDs: [recordID.recordName]
            )
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        }
    }

    private func drainInbox(accountID: String) async throws {
        guard let stateStore else { return }
        let pending = try await stateStore.pendingInbox(accountID: accountID, limit: 500)
        guard !pending.isEmpty else { return }

        let zoneEvents = pending.filter {
            $0.changeKind == .zoneDelete
                || $0.changeKind == .zonePurge
                || $0.changeKind == .encryptedDataReset
        }
        if !zoneEvents.isEmpty, let engine {
            let zones = Set(zoneEvents.map(\.zoneName))
            engine.state.add(
                pendingDatabaseChanges: Self.zoneIDs
                    .filter { zones.contains($0.zoneName) }
                    .map { .saveZone(CKRecordZone(zoneID: $0)) }
            )
            try await stateStore.markInboxApplied(
                accountID: accountID,
                entryIDs: zoneEvents.map(\.id)
            )
            for repository in await CourseDocumentRegistry.shared.openRepositories() {
                try await queueWorkspaceGeneration(repository: repository)
            }
        }
        let recordDeletionIDs = pending
            .filter { $0.changeKind == .delete }
            .map(\.id)
        if !recordDeletionIDs.isEmpty {
            // Immutable generation records are historical transport objects.
            // Their deletion never authorizes deleting the authoritative local
            // course; a later local mutation or zone recovery can re-upload.
            try await stateStore.markInboxApplied(
                accountID: accountID,
                entryIDs: recordDeletionIDs
            )
        }

        struct DecodedEntry {
            let entry: CourseCloudInboxEntry
            let metadata: CourseCloudFetchedRecordMetadata
        }
        let decoded: [DecodedEntry] = pending.compactMap { entry in
            guard entry.changeKind == .save,
                  let payload = entry.payload,
                  let metadata = try? Self.decoder.decode(
                    CourseCloudFetchedRecordMetadata.self,
                    from: payload
                  ) else {
                return nil
            }
            return DecodedEntry(entry: entry, metadata: metadata)
        }
        let commits = decoded.filter {
            $0.metadata.recordType == CourseCloudRecordType.generationCommit
        }
        let generations = decoded.filter {
            $0.metadata.recordType == CourseCloudRecordType.workspaceGeneration
        }
        let catalogs = decoded.filter {
            $0.metadata.recordType == CourseCloudRecordType.catalogEntry
        }

        for generation in generations {
            guard let workspaceID = generation.metadata.fields["workspaceID"],
                  let generationID = generation.metadata.fields["generationID"],
                  let assetPath = generation.entry.durableAssetPath,
                  let commitEntry = commits.first(where: {
                      $0.metadata.fields["workspaceID"] == workspaceID
                          && $0.metadata.fields["generationID"] == generationID
                  }),
                  let commitPath = commitEntry.entry.durableAssetPath else {
                continue
            }
            let snapshotData = try Data(contentsOf: URL(fileURLWithPath: assetPath))
            let commitData = try Data(contentsOf: URL(fileURLWithPath: commitPath))
            let snapshot = try Self.decoder.decode(
                CourseSyncWorkspaceSnapshot.self,
                from: snapshotData
            )
            let commit = try Self.decoder.decode(CourseSyncGenerationCommit.self, from: commitData)
            _ = try snapshot.validatedWorkspace()
            guard snapshot.manifest.workspaceID == workspaceID,
                  snapshot.manifest.generationID == generationID,
                  commit.workspaceID == workspaceID,
                  commit.generationID == generationID,
                  commit.records.contains(where: {
                      $0.recordName == generation.entry.recordName
                          && $0.checksum == snapshot.checksum
                  }) else {
                throw CourseCloudSyncEngineError.invalidEnvelope(generation.entry.recordName)
            }

            let base = try await stateStore.cloudBase(
                accountID: accountID,
                workspaceID: workspaceID
            ).map {
                try Self.decoder.decode(CourseSyncWorkspaceSnapshot.self, from: $0)
            }
            let title = catalogs.first(where: {
                $0.metadata.fields["workspaceID"] == workspaceID
                    && $0.metadata.fields["generationID"] == generationID
            })?.metadata.fields["title"] ?? "Synced Course"

            try await CourseCloudSyncApplyBridge.shared.apply(
                snapshot: snapshot,
                base: base,
                title: title
            )
            try await stateStore.setCloudBase(
                accountID: accountID,
                workspaceID: workspaceID,
                checksum: snapshot.checksum,
                snapshot: snapshotData
            )
            try await stateStore.setCourseProvenance(
                workspaceID: workspaceID,
                provenance: .cloudAccount,
                accountID: accountID
            )
            var appliedIDs = [generation.entry.id, commitEntry.entry.id]
            if let catalog = catalogs.first(where: {
                $0.metadata.fields["workspaceID"] == workspaceID
                    && $0.metadata.fields["generationID"] == generationID
            }) {
                appliedIDs.append(catalog.entry.id)
            }
            try await stateStore.markInboxApplied(accountID: accountID, entryIDs: appliedIDs)
            for path in [assetPath, commitPath] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    private static let zoneIDs = [
        CKRecordZone.ID(zoneName: CourseCloudSyncSchema.catalogZoneName, ownerName: CKCurrentUserDefaultName),
        CKRecordZone.ID(zoneName: CourseCloudSyncSchema.contentZoneName, ownerName: CKCurrentUserDefaultName),
    ]

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private static func outboxEntry(
        accountID: String,
        workspaceID: String,
        zoneName: String,
        recordName: String,
        envelope: CourseCloudRecordEnvelope,
        mutationVersion: CourseSyncMutationVersion?
    ) throws -> CourseCloudOutboxEntry {
        CourseCloudOutboxEntry(
            id: sha256(Data("\(accountID)\u{0}\(zoneName)\u{0}\(recordName)".utf8)),
            accountID: accountID,
            workspaceID: workspaceID,
            zoneName: zoneName,
            recordName: recordName,
            changeKind: .save,
            payload: try encoder.encode(envelope),
            mutationVersion: mutationVersion,
            createdAt: .now
        )
    }

    private static func recordID(zoneName: String, recordName: String) -> CKRecord.ID {
        CKRecord.ID(
            recordName: recordName,
            zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        )
    }

    private static func changeID(recordID: CKRecord.ID, version: String) -> String {
        sha256(
            Data(
                "\(recordID.zoneID.zoneName)\u{0}\(recordID.recordName)\u{0}\(version)".utf8
            )
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CourseCloudFetchedRecordMetadata: Codable, Equatable, Sendable {
    let recordType: String
    let fields: [String: String]
}

@MainActor
final class CourseCloudSyncApplyBridge {
    static let shared = CourseCloudSyncApplyBridge()

    private weak var store: CourseExperienceStore?

    func register(store: CourseExperienceStore) {
        self.store = store
        Task {
            await CourseCloudSyncEngine.shared.applyPendingFetchedChanges()
        }
    }

    func apply(
        snapshot: CourseSyncWorkspaceSnapshot,
        base: CourseSyncWorkspaceSnapshot?,
        title: String
    ) async throws {
        guard let store else { throw CourseCloudSyncEngineError.notStarted }
        let workspaceID = snapshot.manifest.workspaceID
        let databaseURL = store.courseDatabaseURL(workspaceID: workspaceID)
        let existedBeforeSync = FileManager.default.fileExists(atPath: databaseURL.path)
        let repository = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID,
            databaseURL: databaseURL,
            rootTitle: title
        )

        if let base {
            _ = try await repository.applyRemoteSyncSnapshot(snapshot, baseSnapshot: base)
        } else {
            let current = try await repository.exportSyncSnapshot(generationID: "pre-cloud-import")
            if current.checksum == snapshot.checksum {
                // The local workspace is already the fetched generation.
            } else if !existedBeforeSync {
                try await repository.materializeRemoteSyncSnapshot(
                    snapshot,
                    expectedLocalChecksum: current.checksum
                )
            } else {
                throw CourseCloudSyncEngineError.missingMergeBase(workspaceID)
            }
        }
        await store.recoverReadyCourses()
    }
}
