import XCTest
@testable import Litter

@MainActor
final class CourseLearningPathLayoutTests: XCTestCase {
    private func lesson(
        _ id: String,
        _ status: CourseLearningNode.GenerationStatus = .pendingGeneration
    ) -> CourseLearningNode {
        CourseLearningNode(
            id: id, title: id, kind: .markdown, status: status, role: .lesson,
            pageID: status == .generated ? "page-\(id)" : nil
        )
    }

    private func section(_ id: String, _ children: [CourseLearningNode]) -> CourseLearningNode {
        CourseLearningNode(
            id: id, title: id, kind: .folder, status: .pendingGeneration,
            role: .subchapter, children: children
        )
    }

    private func entries(_ children: [CourseLearningNode]) -> [CourseLearningPathLayout.Entry] {
        let chapter = CourseLearningNode(
            id: "chapter", title: "Chapter", kind: .folder, status: .pendingGeneration,
            role: .chapter, children: children
        )
        return CourseLearningPathLayout.entries(
            for: chapter, chapterNumber: 3, runtimeID: CourseAgentProvider.codex
        )
    }

    func testNestedSectionsAreNumberedByDepthAndRestartTheTrail() {
        let result = entries([
            lesson("intro"),
            section("pricing", [lesson("a", .generated), lesson("b")]),
            section("yields", [
                lesson("c"),
                section("bey", [lesson("d"), lesson("e")]),
            ]),
        ])

        let sections = result.compactMap { entry -> CourseLearningPathLayout.Section? in
            if case .section(let section) = entry.kind { return section }
            return nil
        }
        XCTAssertEqual(sections.map(\.number), ["3.1", "3.2", "3.2.1"])
        XCTAssertEqual(sections.map(\.depth), [1, 1, 2])
        XCTAssertEqual(sections[0].readyCount, 1)
        XCTAssertEqual(sections[1].lessonCount, 3)

        let stops = result.compactMap { entry -> CourseLearningPathLayout.Stop? in
            if case .lesson(let stop) = entry.kind { return stop }
            return nil
        }
        XCTAssertEqual(stops.map(\.node.id), ["intro", "a", "b", "c", "d", "e"])
        XCTAssertEqual(stops.map(\.step), [0, 0, 1, 0, 0, 1])
        XCTAssertEqual(stops.first { $0.node.id == "d" }?.sectionTitle, "bey")
    }

    func testOnlyTheFirstCreatableStopInASectionShowsTheHint() {
        let result = entries([section("pricing", [lesson("a", .generated), lesson("b"), lesson("c")])])
        let hints = result.compactMap { entry -> Bool? in
            if case .lesson(let stop) = entry.kind { return stop.showsCreateHint }
            return nil
        }
        XCTAssertEqual(hints, [false, true, false])
    }

    func testSingleLessonSectionFoldsIntoAnEyebrow() {
        let result = entries([
            section("pricing", [lesson("a"), lesson("b")]),
            section("lab", [lesson("build")]),
        ])
        XCTAssertFalse(result.contains { $0.id == "section-lab" })
        guard case .lesson(let stop) = result.last?.kind else {
            return XCTFail("Expected the lab lesson")
        }
        XCTAssertEqual(stop.eyebrow, "3.2 · lab")
    }
}

extension CourseLearningPathLayoutTests {
    func testLessonsAfterANestedSectionGetAContinuationMarker() {
        let result = entries([
            section("yields", [
                lesson("a"),
                section("bey", [lesson("b"), lesson("c")]),
                lesson("d"),
            ]),
        ])
        XCTAssertEqual(result.map(\.id), [
            "section-yields", "a", "section-bey", "b", "c", "continuation-3.1-d", "d",
        ])
        guard case .continuation(let label) = result[5].kind else {
            return XCTFail("Expected a continuation marker")
        }
        XCTAssertEqual(label, "3.1 yields, continued")
    }
}
