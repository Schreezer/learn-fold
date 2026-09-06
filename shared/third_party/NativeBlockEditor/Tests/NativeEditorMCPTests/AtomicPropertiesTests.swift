import Foundation
import NativeBlockEditorCore
import NativeEditorMCP
import XCTest

final class AtomicPropertiesTests: XCTestCase {
    func testSingleAsteriskEmphasisDecodesAsItalic() throws {
        let document = try AppFlowyMarkdownCodec().decode(
            "Why is a *different* string not the same commitment?"
        )
        let paragraph = try XCTUnwrap(document.root.children.first)
        let delta = try XCTUnwrap(paragraph.delta)

        XCTAssertEqual(
            delta.plainText,
            "Why is a different string not the same commitment?"
        )
        XCTAssertTrue(delta.operations.contains { operation in
            guard case let .insert(text, attributes) = operation else { return false }
            return text == "different" && attributes?["italic"]?.boolValue == true
        })
        XCTAssertEqual(
            AppFlowyMarkdownCodec().encode(document),
            "Why is a _different_ string not the same commitment?"
        )
    }

    func testReplaceContentAppliesPropertiesInOneRevisionCheckedCommit() async throws {
        let (service, directory) = try await makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try await service.rootPageSnapshot()
        try await clearReceipts(service)

        let result = try await service.updatePage([
            "page_id": .string(before.id),
            "command": "replace_content",
            "expected_revision": .integer(Int(before.revision)),
            "new_str": "# Atomic lesson\nThe phone wrote this lesson.",
            "properties": .object([
                "title": "Atomic Phone Proof",
                "course_node_id": "atomic-phone-proof-lesson",
                "course_role": "lesson",
                "generation_status": "generated",
            ]),
        ])

        let value = try XCTUnwrap(result.objectValue)
        let metadata = try XCTUnwrap(value["course_metadata"]?.objectValue)
        XCTAssertEqual(value["revision"]?.intValue, Int(before.revision + 1))
        XCTAssertEqual(value["title"]?.stringValue, "Atomic Phone Proof")
        XCTAssertEqual(metadata["node_id"]?.stringValue, "atomic-phone-proof-lesson")
        XCTAssertEqual(metadata["role"]?.stringValue, "lesson")
        XCTAssertEqual(metadata["generation_status"]?.stringValue, "generated")
        let receipts = try await service.pendingSyncMutationReceipts()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].changedPageIDs, [before.id])
    }

    func testReplaceContentPreservesUnspecifiedCourseMetadata() async throws {
        let (service, directory) = try await makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try await service.rootPageSnapshot()
        _ = try await service.updatePage([
            "page_id": .string(initial.id),
            "command": "update_properties",
            "expected_revision": .integer(Int(initial.revision)),
            "properties": .object([
                "course_node_id": "preserved-node",
                "course_role": "lesson",
                "generation_status": "pending_generation",
            ]),
        ])
        try await clearReceipts(service)
        let before = try await service.pageSnapshot(id: initial.id)

        let result = try await service.updatePage([
            "page_id": .string(before.id),
            "command": "replace_content",
            "expected_revision": .integer(Int(before.revision)),
            "new_str": "# Updated lesson\nThe body changed.",
            "properties": .object(["generation_status": "generated"]),
        ])

        let metadata = try XCTUnwrap(result.objectValue?["course_metadata"]?.objectValue)
        XCTAssertEqual(metadata["node_id"]?.stringValue, "preserved-node")
        XCTAssertEqual(metadata["role"]?.stringValue, "lesson")
        XCTAssertEqual(metadata["generation_status"]?.stringValue, "generated")
        XCTAssertEqual(result.objectValue?["revision"]?.intValue, Int(before.revision + 1))
        let receipts = try await service.pendingSyncMutationReceipts()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].changedPageIDs, [before.id])
    }

    func testWorkspaceGenerationCASRejectsStaleWholeWorkspaceWithoutPartialPages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeEditorWorkspaceCAS-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("course-library.sqlite")
        let shellWriter = try await NativeEditorMCPService.open(databaseURL: databaseURL)
        let editorWriter = try await NativeEditorMCPService.open(databaseURL: databaseURL)
        let staleBase = try await shellWriter.workspaceSnapshotWithGeneration()
        let root = try await editorWriter.rootPageSnapshot()

        _ = try await editorWriter.updatePage([
            "page_id": .string(root.id),
            "command": "replace_content",
            "expected_revision": .integer(Int(root.revision)),
            "new_str": "# Learner edit\nThis edit won the interleaving race.",
        ])

        var staleCandidate = staleBase.workspace
        let candidate = try staleCandidate.createPage(
            title: "Partially staged shell page",
            parentID: staleCandidate.rootPageID,
            document: BlockDocument(root: BlockNode(type: "page", children: [
                .heading("Partially staged shell page", level: 1),
            ]))
        )
        if var parent = staleCandidate.page(id: staleCandidate.rootPageID)?.document {
            parent.root.children.append(
                .childPage(pageID: candidate.id, title: candidate.title, icon: candidate.icon)
            )
            try staleCandidate.saveDocument(parent, for: staleCandidate.rootPageID)
        }

        do {
            try await shellWriter.replaceWorkspace(
                staleCandidate,
                expectedGeneration: staleBase.generation
            )
            XCTFail("Expected the stale whole-workspace CAS to lose")
        } catch LibraryStoreError.workspaceGenerationConflict(
            let expected,
            let actual
        ) {
            XCTAssertEqual(expected, staleBase.generation)
            XCTAssertGreaterThan(actual, expected)
        }

        let durable = try await editorWriter.workspaceSnapshot()
        XCTAssertNil(durable.page(id: candidate.id))
        let durableRoot = try XCTUnwrap(durable.page(id: durable.rootPageID))
        XCTAssertTrue(
            AppFlowyMarkdownCodec().encode(durableRoot.document)
                .contains("This edit won the interleaving race.")
        )
    }

    private func makeService() async throws -> (NativeEditorMCPService, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeEditorAtomicProperties-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("course-library.sqlite")
        return (try await NativeEditorMCPService.open(databaseURL: databaseURL), directory)
    }

    private func clearReceipts(_ service: NativeEditorMCPService) async throws {
        let receipts = try await service.pendingSyncMutationReceipts()
        try await service.acknowledgeSyncMutationReceipts(ids: receipts.map(\.id))
    }
}
