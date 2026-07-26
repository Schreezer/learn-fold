import XCTest
@testable import Litter

final class CourseCloudSyncStateStoreTests: XCTestCase {
    func testFetchedInboxAndEngineStateCommitTogether() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = inboxEntry(id: "change-1", accountID: "account-a")

        try await store.commitFetchedBatch(
            accountID: "account-a",
            stateSerialization: Data("state-1".utf8),
            entries: [entry]
        )

        let engineState = try await store.engineState(accountID: "account-a")
        let inbox = try await store.pendingInbox(accountID: "account-a")
        XCTAssertEqual(engineState, Data("state-1".utf8))
        XCTAssertEqual(inbox, [entry])
    }

    func testAccountMismatchRejectsWholeFetchedTransaction() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try await store.commitFetchedBatch(
                accountID: "account-a",
                stateSerialization: Data("must-not-commit".utf8),
                entries: [inboxEntry(id: "change-1", accountID: "account-b")]
            )
            XCTFail("Expected account scope mismatch")
        } catch {
            XCTAssertEqual(error as? CourseCloudSyncStateError, .accountScopeMismatch)
        }

        let engineState = try await store.engineState(accountID: "account-a")
        let inbox = try await store.pendingInbox(accountID: "account-a")
        XCTAssertNil(engineState)
        XCTAssertEqual(inbox, [])
    }

    func testDuplicateFetchedDeliveryIsIdempotentWhileStateAdvances() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = inboxEntry(id: "stable-change-id", accountID: "account-a")

        try await store.commitFetchedBatch(
            accountID: "account-a",
            stateSerialization: Data("state-1".utf8),
            entries: [entry]
        )
        try await store.commitFetchedBatch(
            accountID: "account-a",
            stateSerialization: Data("state-2".utf8),
            entries: [entry]
        )

        let inbox = try await store.pendingInbox(accountID: "account-a")
        let engineState = try await store.engineState(accountID: "account-a")
        XCTAssertEqual(inbox, [entry])
        XCTAssertEqual(engineState, Data("state-2".utf8))
    }

    func testSealingAccountPreservesButQuarantinesPendingOutbox() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = CourseCloudOutboxEntry(
            id: "outbox-1",
            accountID: "old-account",
            workspaceID: "workspace",
            zoneName: CourseCloudSyncSchema.contentZoneName,
            recordName: "record",
            changeKind: .save,
            payload: Data("payload".utf8),
            mutationVersion: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try await store.enqueue(outbox)

        try await store.sealAccount(
            "old-account",
            change: CourseCloudAccountChange(
                previousAccountID: "old-account",
                currentAccountID: "new-account",
                occurredAt: Date(timeIntervalSince1970: 2)
            )
        )

        let isSealed = try await store.isAccountSealed("old-account")
        let oldOutbox = try await store.pendingOutbox(accountID: "old-account")
        let newOutbox = try await store.pendingOutbox(accountID: "new-account")
        XCTAssertTrue(isSealed)
        XCTAssertEqual(oldOutbox, [outbox])
        XCTAssertEqual(newOutbox, [])
    }

    func testMigrationReceiptsAreAccountAndChecksumScoped() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.recordMigrationReceipt(
            accountID: "account-a",
            workspaceID: "workspace",
            contentChecksum: "checksum-1"
        )

        let matchingReceipt = try await store.hasMigrationReceipt(
            accountID: "account-a",
            workspaceID: "workspace",
            contentChecksum: "checksum-1"
        )
        let otherAccountReceipt = try await store.hasMigrationReceipt(
            accountID: "account-b",
            workspaceID: "workspace",
            contentChecksum: "checksum-1"
        )
        let otherChecksumReceipt = try await store.hasMigrationReceipt(
            accountID: "account-a",
            workspaceID: "workspace",
            contentChecksum: "checksum-2"
        )
        XCTAssertTrue(matchingReceipt)
        XCTAssertFalse(otherAccountReceipt)
        XCTAssertFalse(otherChecksumReceipt)
    }

    func testCloudMergeBasesArePartitionedByAccount() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = Data("trusted-base".utf8)

        try await store.setCloudBase(
            accountID: "account-a",
            workspaceID: "workspace",
            checksum: "checksum",
            snapshot: snapshot
        )

        let matching = try await store.cloudBase(
            accountID: "account-a",
            workspaceID: "workspace"
        )
        let otherAccount = try await store.cloudBase(
            accountID: "account-b",
            workspaceID: "workspace"
        )
        XCTAssertEqual(matching, snapshot)
        XCTAssertNil(otherAccount)
    }

    func testMutationVectorsAdvancePerAccountWorkspace() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try await store.nextMutationVersion(
            accountID: "account-a",
            workspaceID: "workspace",
            ancestorChecksum: "base-1"
        )
        let second = try await store.nextMutationVersion(
            accountID: "account-a",
            workspaceID: "workspace",
            ancestorChecksum: "base-2"
        )
        let otherAccount = try await store.nextMutationVersion(
            accountID: "account-b",
            workspaceID: "workspace",
            ancestorChecksum: nil
        )

        XCTAssertEqual(first.dot.counter, 1)
        XCTAssertEqual(second.dot.replicaID, first.dot.replicaID)
        XCTAssertEqual(second.dot.counter, 2)
        XCTAssertTrue(second.observed.observes(first.dot))
        XCTAssertEqual(second.ancestorChecksum, "base-2")
        XCTAssertEqual(otherAccount.dot.counter, 1)
    }

    private func makeStore() throws -> (CourseCloudSyncStateStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseCloudSyncStateStoreTests-\(UUID().uuidString)", isDirectory: true)
        let store = try CourseCloudSyncStateStore(
            url: directory.appendingPathComponent("course-cloud-sync.sqlite")
        )
        return (store, directory)
    }

    private func inboxEntry(id: String, accountID: String) -> CourseCloudInboxEntry {
        CourseCloudInboxEntry(
            id: id,
            accountID: accountID,
            zoneName: CourseCloudSyncSchema.contentZoneName,
            recordName: "record-1",
            changeKind: .save,
            payload: Data("payload".utf8),
            durableAssetPath: nil,
            checksum: "checksum",
            receivedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
