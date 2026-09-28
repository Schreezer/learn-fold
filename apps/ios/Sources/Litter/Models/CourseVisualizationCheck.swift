import Foundation
import NativeBlockEditorCore
import NativeEditorMCP

/// Dry-runs the interactive visualizations on pages an agent just wrote and
/// reports what a learner would hit in the tool result, so the agent can fix
/// them before anyone opens the lesson. The write itself always stands:
/// failing it would make the agent redo the whole page.
enum CourseVisualizationCheck {
    static let resultKey = "visualization_check"

    struct PageReport: Equatable {
        var pageID: String
        var title: String
        /// Issues for each visualization on the page, in page order.
        var visualizationIssues: [[String]]
    }

    /// Whether a tool call can have changed page content.
    static func writesContent(tool: String, arguments: [String: JSONValue]) -> Bool {
        switch tool {
        case NativeEditorMCPToolCatalog.createPages:
            return true
        case NativeEditorMCPToolCatalog.updatePage:
            let command = arguments["command"]?.stringValue ?? ""
            return ["update_content", "replace_content", "insert_content", "replace_content_range"]
                .contains(command)
        default:
            return false
        }
    }

    /// Pages written by a create or update result, including the terminal
    /// result of an async task.
    static func writtenPageIDs(in value: JSONValue) -> [String] {
        guard let object = value.objectValue else { return [] }
        switch object["object"]?.stringValue {
        case "async_task":
            return object["result"].map(writtenPageIDs) ?? []
        case "page_markdown":
            return object["id"]?.stringValue.map { [$0] } ?? []
        case "list":
            return object["results"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue } ?? []
        default:
            return []
        }
    }

    static func visualizations(in document: BlockDocument) -> [String] {
        document.flattenedNodes().compactMap { _, node in
            guard node.type == "nbe/html",
                  node.data["allow_javascript"]?.boolValue == true,
                  let html = node.data["html"]?.stringValue else { return nil }
            return html
        }
    }

    /// The tool-result entry, or nil when no written page has a visualization.
    static func value(for reports: [PageReport]) -> JSONValue? {
        guard !reports.isEmpty else { return nil }
        let needsFixes = reports.contains { $0.visualizationIssues.contains { !$0.isEmpty } }
        let pages: [JSONValue] = reports.map { report in
            .object([
                "page_id": .string(report.pageID),
                "title": .string(report.title),
                "visualizations": .array(report.visualizationIssues.enumerated().map { index, issues in
                    .object([
                        "position": .integer(index + 1),
                        "status": .string(issues.isEmpty ? "passed" : "needs_fixes"),
                        "issues": .array(issues.map(JSONValue.string)),
                    ])
                }),
            ])
        }
        return .object([
            "status": .string(needsFixes ? "needs_fixes" : "passed"),
            "message": .string(needsFixes ? needsFixesMessage : passedMessage),
            "pages": .array(pages),
        ])
    }

    static let needsFixesMessage = """
    The page was saved, but Learnfold rendered its interactive visualization in a phone-width reader and found problems a learner would see. Fix every issue now by rewriting only the `learnfold-visualization` block with native-editor-update-page, then check this result again. Do not describe the lesson as finished while this status is needs_fixes.
    """

    static let passedMessage = """
    Learnfold rendered the visualization in a phone-width reader, used its controls, and found no problems.
    """

    /// Adds the check to a successful write's result.
    static func attaching(_ check: JSONValue, to result: NativeEditorMCPToolResult) -> NativeEditorMCPToolResult {
        guard case .object(var object) = result.value else { return result }
        object[resultKey] = check
        return NativeEditorMCPToolResult(value: .object(object), isError: result.isError)
    }
}
