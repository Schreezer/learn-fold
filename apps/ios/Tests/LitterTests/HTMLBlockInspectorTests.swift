import NativeBlockEditorCore
import NativeEditorMCP
import XCTest
@testable import Litter
@testable import NativeBlockEditorUI

@MainActor
final class HTMLBlockInspectorTests: XCTestCase {
    private func sample(_ id: String) throws -> String {
        try XCTUnwrap(VisualizationGallerySample.all.first { $0.id == id }).html
    }

    func testWellBuiltVisualizationsPass() async throws {
        for id in ["slider", "chart", "stepper", "canvas"] {
            let inspection = await HTMLBlockInspector.inspect(html: try sample(id))
            XCTAssertEqual(inspection.issues, [], id)
            XCTAssertNotNil(inspection.contentHeight, id)
        }
    }

    func testStartupErrorIsReportedWithLineAndEmptyFirstFrame() async throws {
        let inspection = await HTMLBlockInspector.inspect(html: try sample("startup-error"))
        XCTAssertTrue(
            inspection.issues.contains { $0.hasPrefix("JavaScript error while loading") && $0.contains("line 3") },
            "\(inspection.issues)"
        )
        XCTAssertTrue(inspection.issues.contains { $0.hasPrefix("The first frame is empty") }, "\(inspection.issues)")
    }

    func testErrorsAreAttributedToTheInteractionThatCausedThem() async throws {
        let inspection = await HTMLBlockInspector.inspect(html: try sample("tap-error"))
        XCTAssertTrue(
            inspection.issues.contains { $0.contains("after tapping “Compute yield”") && $0.contains("bond") },
            "\(inspection.issues)"
        )
    }

    func testNaNAtASliderEdgeIsReported() async throws {
        let inspection = await HTMLBlockInspector.inspect(html: try sample("nan"))
        XCTAssertTrue(
            inspection.issues.contains { $0.contains("NaN") && $0.contains("to its minimum") },
            "\(inspection.issues)"
        )
    }

    func testOverflowNamesTheElement() async throws {
        let inspection = await HTMLBlockInspector.inspect(html: try sample("overflow"))
        XCTAssertTrue(
            inspection.issues.contains { $0.contains("360px phone column") && $0.contains("<table.rates>") },
            "\(inspection.issues)"
        )
    }

    func testStrippedInlineHandlersAreExplained() async throws {
        let inspection = await HTMLBlockInspector.inspect(html: try sample("inline-handlers"))
        XCTAssertTrue(inspection.issues.contains { $0.contains("onclick=") }, "\(inspection.issues)")
    }

    func testUnlabeledControlsAndMissingLiveRegionAreReported() async throws {
        let inspection = await HTMLBlockInspector.inspect(html: try sample("unlabeled"))
        XCTAssertTrue(
            inspection.issues.contains { $0.hasPrefix("2 control(s) have no accessible name") },
            "\(inspection.issues)"
        )
        XCTAssertTrue(inspection.issues.contains { $0.contains("aria-live") }, "\(inspection.issues)")
    }

    func testTallContentIsReported() async throws {
        let inspection = await HTMLBlockInspector.inspect(html: try sample("tall"))
        XCTAssertGreaterThan(inspection.contentHeight ?? 0, 640)
        XCTAssertTrue(inspection.issues.contains { $0.contains("full screen") }, "\(inspection.issues)")
    }

    func testNetworkAccessIsReportedAsBlocked() async {
        let inspection = await HTMLBlockInspector.inspect(html: """
        <p>Rates</p>
        <img src="https://example.com/chart.png" alt="Chart">
        """)
        XCTAssertTrue(
            inspection.issues.contains { $0.contains("https://example.com/chart.png") },
            "\(inspection.issues)"
        )
    }

    func testEndlessLoopTimesOut() async {
        let inspection = await HTMLBlockInspector.inspect(
            html: "<p>Spinning</p><script>while (true) {}</script>",
            timeout: .seconds(2)
        )
        XCTAssertTrue(
            inspection.issues.contains { $0.contains("did not finish rendering within 2 seconds") },
            "\(inspection.issues)"
        )
    }

    // MARK: Tool-result shaping

    func testWrittenPageIDsCoverSyncListAndAsyncResults() {
        let page: JSONValue = .object(["object": "page_markdown", "id": "a"])
        let list: JSONValue = .object([
            "object": "list",
            "results": .array([.object(["id": "b"]), .object(["id": "c"])]),
        ])
        let task: JSONValue = .object(["object": "async_task", "result": list])
        XCTAssertEqual(CourseVisualizationCheck.writtenPageIDs(in: page), ["a"])
        XCTAssertEqual(CourseVisualizationCheck.writtenPageIDs(in: list), ["b", "c"])
        XCTAssertEqual(CourseVisualizationCheck.writtenPageIDs(in: task), ["b", "c"])
    }

    func testOnlyContentWritesAreChecked() {
        XCTAssertTrue(CourseVisualizationCheck.writesContent(
            tool: NativeEditorMCPToolCatalog.createPages, arguments: [:]
        ))
        XCTAssertTrue(CourseVisualizationCheck.writesContent(
            tool: NativeEditorMCPToolCatalog.updatePage, arguments: ["command": "replace_content"]
        ))
        XCTAssertFalse(CourseVisualizationCheck.writesContent(
            tool: NativeEditorMCPToolCatalog.updatePage, arguments: ["command": "update_properties"]
        ))
        XCTAssertFalse(CourseVisualizationCheck.writesContent(
            tool: NativeEditorMCPToolCatalog.movePages, arguments: [:]
        ))
    }

    func testCheckValueSummarisesPerVisualization() throws {
        XCTAssertNil(CourseVisualizationCheck.value(for: []))
        let value = try XCTUnwrap(CourseVisualizationCheck.value(for: [
            .init(pageID: "p", title: "Yield", visualizationIssues: [[], ["Too wide"]]),
        ]))
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, "needs_fixes")
        let visualizations = object["pages"]?.arrayValue?.first?.objectValue?["visualizations"]?.arrayValue
        XCTAssertEqual(visualizations?.map { $0.objectValue?["status"]?.stringValue }, ["passed", "needs_fixes"])

        let passed = try XCTUnwrap(CourseVisualizationCheck.value(for: [
            .init(pageID: "p", title: "Yield", visualizationIssues: [[]]),
        ]))
        XCTAssertEqual(passed.objectValue?["status"]?.stringValue, "passed")
    }
}
