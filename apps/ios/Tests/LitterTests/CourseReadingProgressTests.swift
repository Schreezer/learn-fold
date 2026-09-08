import XCTest
@testable import Litter

final class CourseReadingProgressTests: XCTestCase {
    func testOrderCrossesNestedFoldersWithoutSkippingPendingLessons() {
        let nodes = [folder("first", [folder("nested", [lesson("a"), lesson("b", ready: false)])]),
                     folder("second", [lesson("c")])]
        XCTAssertEqual(CourseReadingOrder.lessons(in: nodes).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(CourseReadingOrder.next(after: "page-a", in: nodes)?.id, "b")
        XCTAssertEqual(CourseReadingOrder.next(after: "page-b", in: nodes)?.id, "c")
        XCTAssertNil(CourseReadingOrder.next(after: "page-c", in: nodes))
        XCTAssertNil(CourseReadingOrder.next(after: "deleted", in: nodes))
    }

    func testContinueKeepsCompletedArticleAndFallsBackWhenPageWasDeleted() {
        let nodes = [folder("first", [lesson("a"), lesson("b")])]
        XCTAssertEqual(CourseReadingOrder.resume(in: nodes, bookmark: .init(
            pageID: "page-a", offset: 1420, isAtEnd: true
        ))?.id, "a")
        XCTAssertEqual(CourseReadingOrder.resume(in: nodes, bookmark: .init(
            pageID: "deleted", offset: 1420, isAtEnd: true
        ))?.id, "a")
        XCTAssertNil(CourseReadingOrder.resume(in: [], bookmark: nil))
    }

    @MainActor
    func testBookmarkSurvivesNewStoreAndIsScopedToCourseAndWorkspace() throws {
        let suite = "CourseReadingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let course = makeCourse(id: "one", workspace: "one")
        let bookmark = CourseReadingBookmark(pageID: "page-a", offset: 1024.5, isAtEnd: true)
        var store: CourseExperienceStore? = CourseExperienceStore(defaults: defaults, coursesRootURL: root)
        store?.saveReadingBookmark(bookmark, for: course)
        store = nil
        let reopened = CourseExperienceStore(defaults: defaults, coursesRootURL: root)
        XCTAssertEqual(reopened.readingBookmark(for: course), bookmark)
        XCTAssertNil(reopened.readingBookmark(for: makeCourse(id: "two", workspace: "one")))
        XCTAssertNil(reopened.readingBookmark(for: makeCourse(id: "one", workspace: "two")))
        reopened.saveReadingBookmark(.init(pageID: "bad", offset: .infinity, isAtEnd: false), for: course)
        XCTAssertEqual(reopened.readingBookmark(for: course), bookmark)
    }

    @MainActor
    func testNextReplacesReaderSoBackReturnsToCourse() throws {
        let suite = "CourseReadingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let course = makeCourse(id: "one", workspace: "one")
        defaults.set(try JSONEncoder().encode([course]), forKey: "snappy.course.savedCourses")
        let store = CourseExperienceStore(defaults: defaults, coursesRootURL: root)
        store.navigationPath = [.course(course.id), .coursePage(courseID: course.id, pageID: "a")]
        store.openReadingPage(courseID: course.id, pageID: "b", replacingCurrentPage: true)
        XCTAssertEqual(store.navigationPath, [.course(course.id), .coursePage(courseID: course.id, pageID: "b")])
        store.openReadingPage(courseID: "missing", pageID: "c", replacingCurrentPage: true)
        XCTAssertEqual(store.navigationPath.count, 2)
    }

    private func lesson(_ id: String, ready: Bool = true) -> CourseLearningNode {
        .init(id: id, title: id, kind: .markdown, status: ready ? .generated : .pendingGeneration,
              role: .lesson, pageID: "page-\(id)")
    }

    private func folder(_ id: String, _ children: [CourseLearningNode]) -> CourseLearningNode {
        .init(id: id, title: id, kind: .folder, status: .partiallyGenerated, children: children)
    }

    private func makeCourse(id: String, workspace: String) -> LearningCourse {
        .init(id: id, title: "Reading test", subtitle: "", accentHex: "007AFF", progress: 0,
              lessonCount: 3, duration: "", status: .ready, workspaceID: workspace)
    }
}
