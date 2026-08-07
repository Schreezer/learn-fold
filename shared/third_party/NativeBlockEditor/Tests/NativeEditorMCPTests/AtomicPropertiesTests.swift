import Foundation
import NativeBlockEditorCore
import NativeEditorMCP
import XCTest

final class AtomicPropertiesTests: XCTestCase {
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
