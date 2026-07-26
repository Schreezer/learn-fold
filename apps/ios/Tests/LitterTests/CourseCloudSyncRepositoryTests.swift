import NativeBlockEditorCore
import XCTest
@testable import Litter

final class CourseCloudSyncRepositoryTests: XCTestCase {
    func testRepositoryExportsCompleteWorkspaceSnapshot() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = try await repository.exportSyncSnapshot(generationID: "generation-1")
        let workspace = try snapshot.validatedWorkspace()
        let workspaceID = await repository.workspaceID

        XCTAssertEqual(snapshot.manifest.workspaceID, workspaceID)
        XCTAssertEqual(workspace.rootPageID, snapshot.manifest.rootPageID)
        XCTAssertEqual(Set(workspace.items.keys), Set(snapshot.manifest.itemIDs))
    }

    func testRemoteApplyMergesNonOverlappingLearnerAndCloudBlocks() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try await repository.exportSyncSnapshot(generationID: "base")
        let rootID = base.manifest.rootPageID
        let basePage = try XCTUnwrap(base.pages.first(where: { $0.id == rootID }))
        let baseRevision = try await repository.pageSnapshot(id: rootID).revision

        var localDocument = basePage.document
        localDocument.root.children.append(.paragraph("local learner note"))
        try await repository.stageUserEdit(
            pageID: rootID,
            document: localDocument,
            capturedBaseDocument: basePage.document,
            capturedBaseRevision: baseRevision
        )
        try await repository.flushPendingUserEdits()

        var remoteWorkspace = try base.validatedWorkspace()
        var remoteDocument = try XCTUnwrap(remoteWorkspace.page(id: rootID)).document
        remoteDocument.root.children.append(.paragraph("remote device note"))
        try remoteWorkspace.saveDocument(remoteDocument, for: rootID)
        let workspaceID = await repository.workspaceID
        let remote = try CourseSyncWorkspaceSnapshot(
            workspaceID: workspaceID,
            workspace: remoteWorkspace,
            generationID: "remote"
        )

        _ = try await repository.applyRemoteSyncSnapshot(remote, baseSnapshot: base)
        let applied = try await repository.pageSnapshot(id: rootID)
        let markdown = AppFlowyMarkdownCodec().encode(applied.document)

        XCTAssertTrue(markdown.contains("local learner note"))
        XCTAssertTrue(markdown.contains("remote device note"))
    }

    func testConcurrentStructuralConflictDoesNotReplaceLocalWorkspace() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try await repository.exportSyncSnapshot(generationID: "base")
        let rootID = base.manifest.rootPageID

        var localWorkspace = try base.validatedWorkspace()
        try localWorkspace.renamePage(rootID, to: "Local title")
        let workspaceID = await repository.workspaceID
        let local = try CourseSyncWorkspaceSnapshot(
            workspaceID: workspaceID,
            workspace: localWorkspace,
            generationID: "local"
        )
        try await repository.materializeRemoteSyncSnapshot(
            local,
            expectedLocalChecksum: base.checksum
        )

        var remoteWorkspace = try base.validatedWorkspace()
        try remoteWorkspace.renamePage(rootID, to: "Remote title")
        let remote = try CourseSyncWorkspaceSnapshot(
            workspaceID: workspaceID,
            workspace: remoteWorkspace,
            generationID: "remote"
        )

        do {
            _ = try await repository.applyRemoteSyncSnapshot(remote, baseSnapshot: base)
            XCTFail("Expected structural conflict")
        } catch CourseCloudSyncRepositoryError.structuralConflict(let ids) {
            XCTAssertTrue(ids.contains(rootID))
        }
        let resultingTitle = try await repository.pageSnapshot(id: rootID).title
        XCTAssertEqual(resultingTitle, "Local title")
    }

    func testSQLiteCommitProducesDurableMutationReceipt() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = try await repository.pendingSyncMutationReceipts()
        try await repository.acknowledgeSyncMutationReceipts(ids: existing.map(\.id))

        let root = try await repository.rootPageSnapshot()
        var document = root.document
        document.root.children.append(.paragraph("receipt test"))
        try await repository.stageUserEdit(
            pageID: root.id,
            document: document,
            capturedBaseDocument: root.document,
            capturedBaseRevision: root.revision
        )
        try await repository.flushPendingUserEdits()

        let receipts = try await repository.pendingSyncMutationReceipts()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertTrue(receipts[0].requiresFullInventory)
        XCTAssertTrue(receipts[0].changedPageIDs.contains(root.id))
    }

    private func makeRepository() async throws -> (CourseDocumentRepository, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseCloudSyncRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        let repository = try await CourseDocumentRepository.open(
            workspaceID: UUID().uuidString.lowercased(),
            databaseURL: directory.appendingPathComponent(".course/course-library.sqlite"),
            rootTitle: "Cloud Sync Course",
            autosaveDelay: .seconds(60)
        )
        return (repository, directory)
    }
}
