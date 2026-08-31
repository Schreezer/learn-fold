import XCTest

final class CourseRouteFallbackUITests: XCTestCase {
    private enum Scenario: String {
        case missingCourse = "missing-course"
        case missingCoursePage = "missing-course-page"
        case missingCourseFile = "missing-course-file"
        case stalePage = "stale-page"
        case staleFile = "stale-file"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMissingParentRoutesShareCourseUnavailableRecovery() {
        for scenario in [
            Scenario.missingCourse,
            .missingCoursePage,
            .missingCourseFile,
        ] {
            let app = launch(scenario)

            assertUnavailableState(
                kind: "course",
                title: "Course unavailable",
                description: "This course is no longer available on this device. Return to your course library to continue.",
                in: app
            )
            XCTAssertFalse(
                button("Open Course Structure", in: app).exists,
                "A missing parent course cannot safely recover to its old structure"
            )

            attachScreenshot(named: "LF-54 \(scenario.rawValue) fallback", app: app)
            returnToLibrary(in: app)
            assertStrictIsolation(
                in: app,
                context: "\(scenario.rawValue) after library recovery"
            )
            attachScreenshot(named: "LF-54 \(scenario.rawValue) library recovery", app: app)
            app.terminate()
        }
    }

    @MainActor
    func testStalePageRecoversToCourseStructure() {
        let app = launch(.stalePage)

        assertUnavailableState(
            kind: "page",
            title: "Page unavailable",
            description: "This page is no longer available in Route Recovery Course. Open the course structure to choose an available page.",
            in: app
        )
        attachScreenshot(named: "LF-54 stale page fallback", app: app)
        assertCourseStructureRecovery(in: app)
        assertStrictIsolation(in: app, context: "stale-page after structure recovery")
        attachScreenshot(named: "LF-54 stale page structure recovery", app: app)
        app.terminate()
    }

    @MainActor
    func testStaleFileRecoversToCourseStructureAndRetainsLibraryEscape() {
        let app = launch(.staleFile)

        assertUnavailableState(
            kind: "file",
            title: "File unavailable",
            description: "This file is no longer available in Route Recovery Course. Open the course structure to choose an available file.",
            in: app
        )
        let returnButton = button("Return to Course Library", in: app)
        XCTAssertTrue(returnButton.exists)
        XCTAssertEqual(returnButton.label, "Return to Course Library")
        XCTAssertTrue(returnButton.isEnabled)

        attachScreenshot(named: "LF-54 stale file fallback", app: app)
        assertCourseStructureRecovery(in: app)
        assertStrictIsolation(in: app, context: "stale-file after structure recovery")
        attachScreenshot(named: "LF-54 stale file structure recovery", app: app)
        app.terminate()
    }

    @MainActor
    private func launch(_ scenario: Scenario) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments += [
            "--ui-test-course-route-fallback",
            scenario.rawValue,
        ]
        app.launch()
        assertStrictIsolation(in: app, context: "\(scenario.rawValue) before action")
        return app
    }

    @MainActor
    private func assertStrictIsolation(
        in app: XCUIApplication,
        context: String
    ) {
        let root = element("courseRouteFallbackCheckpoint.strictRoot", in: app)
        XCTAssertTrue(
            root.waitForExistence(timeout: 10),
            "The LF-54 strict root marker is missing \(context)"
        )
        XCTAssertTrue(
            waitUntilHittable(root, timeout: 10),
            "The LF-54 strict root marker is not visible \(context)"
        )
        let counter = element(
            "courseRouteFallbackCheckpoint.forbiddenSideEffects",
            in: app
        )
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Forbidden production entry events · 0"
            ),
            object: counter
        )
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
        let details = element(
            "courseRouteFallbackCheckpoint.forbiddenSideEffectDetails",
            in: app
        )
        XCTAssertEqual(
            counter.value as? String,
            "0",
            "LF-54 entered production \(context): \(details.exists ? details.label : "no details")"
        )
        XCTAssertEqual(counter.label, "Forbidden production entry events · 0")
    }

    @MainActor
    private func assertUnavailableState(
        kind: String,
        title: String,
        description: String,
        in app: XCUIApplication
    ) {
        let fallback = element("course-route-unavailable-\(kind)", in: app)
        XCTAssertTrue(
            fallback.waitForExistence(timeout: 10),
            "The \(kind) fallback did not appear"
        )

        let titleElement = app.staticTexts[title].firstMatch
        XCTAssertTrue(titleElement.exists)
        XCTAssertEqual(titleElement.label, title)

        let descriptionElement = app.staticTexts[description].firstMatch
        XCTAssertTrue(descriptionElement.exists)
        XCTAssertEqual(descriptionElement.label, description)

        let primary = kind == "course"
            ? button("Return to Course Library", in: app)
            : button("Open Course Structure", in: app)
        XCTAssertTrue(primary.exists)
        XCTAssertTrue(primary.isEnabled)
        XCTAssertTrue(
            waitUntilHittable(primary, timeout: 10),
            "The \(kind) recovery action remained covered by the launch splash"
        )
    }

    @MainActor
    private func assertCourseStructureRecovery(in app: XCUIApplication) {
        let structure = button("Open Course Structure", in: app)
        XCTAssertEqual(structure.label, "Open Course Structure")
        structure.tap()

        let picker = element("course-detail-section-picker", in: app)
        XCTAssertTrue(
            picker.waitForExistence(timeout: 10),
            "Course Structure recovery did not open the course detail shell"
        )
        XCTAssertEqual(picker.value as? String, "Structure")
        XCTAssertTrue(
            app.staticTexts["Course pages"].firstMatch.waitForExistence(timeout: 10),
            "The production course structure presentation did not render"
        )
        let structureRow = element("course-page-row-route-recovery-section", in: app)
        XCTAssertTrue(structureRow.exists)
        XCTAssertEqual(
            structureRow.label,
            "1, Chapter, Route Recovery, Editable page"
        )
    }

    @MainActor
    private func returnToLibrary(in app: XCUIApplication) {
        let library = button("Return to Course Library", in: app)
        XCTAssertEqual(library.label, "Return to Course Library")
        XCTAssertTrue(library.isHittable)
        library.tap()

        XCTAssertTrue(
            element("course-library-root", in: app).waitForExistence(timeout: 10),
            "Return to Course Library did not reach the real library shell"
        )
        XCTAssertTrue(app.staticTexts["My Courses"].exists)
        XCTAssertTrue(app.staticTexts["Route Recovery Course"].firstMatch.exists)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func button(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons[label].firstMatch
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
