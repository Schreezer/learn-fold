import NativeBlockEditorCore
import NativeEditorMCP
import XCTest

final class NativeEditorMCPAtomicPropertiesTests: XCTestCase {
    func testReplaceContentAppliesCoursePropertiesInOneRevisionCheckedCommit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeEditorAtomicProperties-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("course-library.sqlite")
        let service = try await NativeEditorMCPService.open(databaseURL: databaseURL)
        let before = try await service.rootPageSnapshot()
        let existingReceipts = try await service.pendingSyncMutationReceipts()
        try await service.acknowledgeSyncMutationReceipts(ids: existingReceipts.map(\.id))

        let markdown = """
        # Atomic lesson
        The native editor writes content and course state together.

        ```swift
        let executedOn = "mobile_device"
        print(executedOn)
        ```

        Exercise: Explain why Hermes waits for this result.
        """
        let result = try await service.updatePage([
            "page_id": .string(before.id),
            "command": "replace_content",
            "expected_revision": .integer(Int(before.revision)),
            "new_str": .string(markdown),
            "properties": .object([
                "title": "Atomic Phone Proof",
                "course_node_id": "atomic-phone-proof-lesson",
                "course_role": "lesson",
                "generation_status": "generated",
            ]),
        ])

        let resultObject = try XCTUnwrap(result.objectValue)
        let resultMetadata = try XCTUnwrap(resultObject["course_metadata"]?.objectValue)
        XCTAssertEqual(resultObject["title"]?.stringValue, "Atomic Phone Proof")
        XCTAssertEqual(resultObject["revision"]?.intValue, Int(before.revision + 1))
        XCTAssertEqual(resultMetadata["node_id"]?.stringValue, "atomic-phone-proof-lesson")
        XCTAssertEqual(resultMetadata["role"]?.stringValue, "lesson")
        XCTAssertEqual(resultMetadata["generation_status"]?.stringValue, "generated")

        let after = try await service.pageSnapshot(id: before.id)
        XCTAssertEqual(after.revision, before.revision + 1)
        XCTAssertEqual(after.title, "Atomic Phone Proof")
        XCTAssertEqual(
            after.document.root.data["course_generation_status"]?.stringValue,
            "generated"
        )
        XCTAssertEqual(after.document.root.data["course_role"]?.stringValue, "lesson")
        XCTAssertEqual(after.document.root.data["course_node_id"]?.stringValue, "atomic-phone-proof-lesson")
        let canonicalMarkdown = markdown.replacingOccurrences(
            of: "# Atomic lesson\n",
            with: "# Atomic lesson\n\n"
        )
        XCTAssertEqual(AppFlowyMarkdownCodec().encode(after.document), canonicalMarkdown)

        let receipts = try await service.pendingSyncMutationReceipts()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertTrue(receipts[0].changedPageIDs.contains(before.id))
    }

    func testReplaceContentPreservesUnspecifiedCourseMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeEditorPreservedMetadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("course-library.sqlite")
        let service = try await NativeEditorMCPService.open(databaseURL: databaseURL)
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
        let seedReceipts = try await service.pendingSyncMutationReceipts()
        try await service.acknowledgeSyncMutationReceipts(ids: seedReceipts.map(\.id))
        let before = try await service.pageSnapshot(id: initial.id)

        let result = try await service.updatePage([
            "page_id": .string(before.id),
            "command": "replace_content",
            "expected_revision": .integer(Int(before.revision)),
            "new_str": "# Preserved metadata\nThe lesson body changed.",
            "properties": .object(["generation_status": "generated"]),
        ])

        let metadata = try XCTUnwrap(result.objectValue?["course_metadata"]?.objectValue)
        XCTAssertEqual(metadata["node_id"]?.stringValue, "preserved-node")
        XCTAssertEqual(metadata["role"]?.stringValue, "lesson")
        XCTAssertEqual(metadata["generation_status"]?.stringValue, "generated")
        XCTAssertEqual(result.objectValue?["revision"]?.intValue, Int(before.revision + 1))

        let after = try await service.pageSnapshot(id: before.id)
        XCTAssertEqual(after.document.root.data["course_node_id"]?.stringValue, "preserved-node")
        XCTAssertEqual(after.document.root.data["course_role"]?.stringValue, "lesson")
        XCTAssertEqual(after.document.root.data["course_generation_status"]?.stringValue, "generated")
        let receipts = try await service.pendingSyncMutationReceipts()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].changedPageIDs, [before.id])
    }
}
