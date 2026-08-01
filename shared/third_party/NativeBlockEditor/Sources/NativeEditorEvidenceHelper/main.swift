import CryptoKit
import Foundation
import NativeBlockEditorCore
import NativeBlockEditorLibrary
import NativeEditorMCP

private enum HelperError: Error, LocalizedError {
    case usage(String)
    case malformedResult(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .malformedResult(let message): message
        }
    }
}

private struct Inspection: Codable {
    var pageID: String
    var revision: Int64
    var markdown: String
    var plainText: String
    var documentSHA256: String
    var historyMarkdown: [String]
}

private struct Fixture: Codable {
    var rootPageID: String
    var contextPageIDs: [String]
    var chapterPageID: String
    var lessonPageID: String
    var preResult: JSONValue
    var mutationResult: JSONValue
    var postResult: JSONValue
}

@main
private enum NativeEditorEvidenceHelper {
    static func main() async {
        do {
            let output = try await run(Array(CommandLine.arguments.dropFirst()))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(output))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            Foundation.exit(2)
        }
    }

    private static func run(_ arguments: [String]) async throws -> JSONValue {
        guard let command = arguments.first else {
            throw HelperError.usage("usage: native-editor-evidence-helper inspect <database> <page-id> | create-fixture <database> <markdown-file>")
        }
        switch command {
        case "inspect":
            guard arguments.count == 3 else {
                throw HelperError.usage("inspect requires <database> <page-id>")
            }
            return try jsonValue(try await inspect(
                databaseURL: URL(fileURLWithPath: arguments[1]),
                pageID: arguments[2]
            ))
        case "create-fixture":
            guard arguments.count == 3 else {
                throw HelperError.usage("create-fixture requires <database> <markdown-file>")
            }
            let markdown = try String(contentsOfFile: arguments[2], encoding: .utf8)
            return try jsonValue(try await createFixture(
                databaseURL: URL(fileURLWithPath: arguments[1]),
                finalMarkdown: markdown
            ))
        default:
            throw HelperError.usage("unknown command: \(command)")
        }
    }

    private static func inspect(databaseURL: URL, pageID: String) async throws -> Inspection {
        let service = try await NativeEditorMCPService.open(databaseURL: databaseURL)
        let snapshot = try await service.pageSnapshot(id: pageID)
        let codec = NotionEnhancedMarkdownCodec()
        let documentEncoder = JSONEncoder()
        documentEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let documentData = try documentEncoder.encode(snapshot.document)
        let store = try SQLiteLibraryStore(url: databaseURL)
        let history = try await store.history(for: pageID)
        let historyMarkdown = try await history.asyncMap { entry in
            codec.encode(try await store.document(forHistoryEntry: entry.id))
        }
        return Inspection(
            pageID: pageID,
            revision: snapshot.revision,
            markdown: codec.encode(snapshot.document),
            plainText: snapshot.document.flattenedNodes()
                .compactMap { _, node in
                    guard let text = node.delta?.plainText, !text.isEmpty else { return nil }
                    return text
                }
                .joined(separator: "\n"),
            documentSHA256: SHA256.hash(data: documentData)
                .map { String(format: "%02x", $0) }
                .joined(),
            historyMarkdown: historyMarkdown
        )
    }

    private static func createFixture(databaseURL: URL, finalMarkdown: String) async throws -> Fixture {
        let service = try await NativeEditorMCPService.open(databaseURL: databaseURL)
        let root = try await service.rootPageSnapshot()
        let shellResult = try await service.createPages([
            "parent": .object(["page_id": .string(root.id)]),
            "pages": .array([
                fixturePage(
                    title: "Learner profile",
                    nodeID: "learner-profile",
                    role: "context",
                    status: "generated",
                    content: "# Learner profile\nNative proof context."
                ),
                fixturePage(
                    title: "Course design",
                    nodeID: "course-design",
                    role: "context",
                    status: "generated",
                    content: "# Course design\nNative proof context."
                ),
                fixturePage(
                    title: "Agent notes",
                    nodeID: "agent-notes",
                    role: "context",
                    status: "generated",
                    content: "# Agent notes\nApproved plan: phone-tool-proof, revision 1."
                ),
                fixturePage(
                    title: "Phone Proof",
                    nodeID: "proof",
                    role: "chapter",
                    status: "pending_generation",
                    content: "# Phone Proof\nExplain the complete lifecycle."
                ),
            ]),
        ])
        let shellPages = try createdPages(shellResult)
        guard shellPages.count == 4 else {
            throw HelperError.malformedResult("course shell did not create four pages")
        }
        let contextIDs = try shellPages.prefix(3).map { try pageID(in: $0) }
        let chapterID = try pageID(in: shellPages[3])
        let lessonResult = try await service.createPages([
            "parent": .object(["page_id": .string(chapterID)]),
            "pages": .array([
                fixturePage(
                    title: "1.1 · Phone Proof",
                    nodeID: "proof-lesson",
                    role: "lesson",
                    status: "pending_generation",
                    content: "# Phone Proof\nThis lesson is ready for the course agent to write."
                ),
            ]),
        ])
        let lessonPages = try createdPages(lessonResult)
        guard lessonPages.count == 1 else {
            throw HelperError.malformedResult("course shell did not create one lesson")
        }
        let lessonID = try pageID(in: lessonPages[0])
        let initialReceipts = try await service.pendingSyncMutationReceipts()
        try await service.acknowledgeSyncMutationReceipts(ids: initialReceipts.map(\.id))
        let before = try await service.pageSnapshot(id: lessonID)
        let pre = try await service.fetch(["id": .string(lessonID)])
        let mutation = try await service.updatePage([
            "page_id": .string(lessonID),
            "command": "replace_content",
            "expected_revision": .integer(Int(before.revision)),
            "new_str": .string(finalMarkdown),
            "properties": .object(["generation_status": "generated"]),
        ])
        let post = try await service.fetch(["id": .string(lessonID)])
        let rootBeforeReady = try await service.pageSnapshot(id: root.id)
        _ = try await service.updatePage([
            "page_id": .string(root.id),
            "command": "update_properties",
            "expected_revision": .integer(Int(rootBeforeReady.revision)),
            "properties": .object([
                "title": "Phone Tool Proof",
                "course_node_id": "phone-tool-proof",
                "course_role": "course",
                "bootstrap_status": "ready_for_learning",
            ]),
        ])
        let finalReceipts = try await service.pendingSyncMutationReceipts()
        try await service.acknowledgeSyncMutationReceipts(ids: finalReceipts.map(\.id))
        return Fixture(
            rootPageID: root.id,
            contextPageIDs: contextIDs,
            chapterPageID: chapterID,
            lessonPageID: lessonID,
            preResult: pre,
            mutationResult: mutation,
            postResult: post
        )
    }

    private static func fixturePage(
        title: String,
        nodeID: String,
        role: String,
        status: String,
        content: String
    ) -> JSONValue {
        .object([
            "properties": .object([
                "title": .string(title),
                "course_node_id": .string(nodeID),
                "course_role": .string(role),
                "generation_status": .string(status),
            ]),
            "content": .string(content),
        ])
    }

    private static func createdPages(_ result: JSONValue) throws -> [[String: JSONValue]] {
        guard let values = result.objectValue?["results"]?.arrayValue else {
            throw HelperError.malformedResult("create-pages result has no results")
        }
        return try values.map { value in
            guard let object = value.objectValue else {
                throw HelperError.malformedResult("create-pages returned a malformed page")
            }
            return object
        }
    }

    private static func pageID(in page: [String: JSONValue]) throws -> String {
        guard let id = page["id"]?.stringValue else {
            throw HelperError.malformedResult("create-pages omitted a page ID")
        }
        return id
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            values.append(try await transform(element))
        }
        return values
    }
}
