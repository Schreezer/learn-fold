import XCTest

final class CourseGenerationCheckpointUITests: XCTestCase {
    private enum Scenario: String, CaseIterable {
        case lf39Milestone1 = "--ui-test-lf39-milestone-1"
        case lf39Milestone2 = "--ui-test-lf39-milestone-2"
        case lf39Milestone3 = "--ui-test-lf39-milestone-3"
        case lf39Milestone4 = "--ui-test-lf39-milestone-4"
        case lf39Milestone5 = "--ui-test-lf39-milestone-5"
        case lf40GenerationError = "--ui-test-lf40-generation-error"
        case lf40ReturnedAgent = "--ui-test-lf40-returned-agent"
        case lf44Pending = "--ui-test-lf44-pending"
        case lf44Generating = "--ui-test-lf44-generating"
        case lf44PartialGenerated = "--ui-test-lf44-partial-generated"
        case lf44Error = "--ui-test-lf44-error"

        var route: String {
            switch self {
            case .lf39Milestone1, .lf39Milestone2, .lf39Milestone3,
                 .lf39Milestone4, .lf39Milestone5:
                "--ui-test-lf-39-fixture-hook"
            case .lf40GenerationError, .lf40ReturnedAgent:
                "--ui-test-lf-40-fault-hook"
            case .lf44Pending, .lf44Generating, .lf44PartialGenerated,
                 .lf44Error:
                "--ui-test-lf-44-fault-hook"
            }
        }

        var hook: String {
            switch route {
            case "--ui-test-lf-39-fixture-hook": "lf-39-fixture-hook"
            case "--ui-test-lf-40-fault-hook": "lf-40-fault-hook"
            default: "lf-44-fault-hook"
            }
        }
    }

    @MainActor
    func testLF39FiveMilestonesUseTheProductionPresentation() {
        let scenarios: [Scenario] = [
            .lf39Milestone1,
            .lf39Milestone2,
            .lf39Milestone3,
            .lf39Milestone4,
            .lf39Milestone5,
        ]

        for (activeIndex, scenario) in scenarios.enumerated() {
            let app = launch(scenario)
            assertValue(
                "milestone-\(activeIndex + 1)",
                for: "course-building-state",
                in: app
            )
            for index in 0..<5 {
                let expected = if index < activeIndex {
                    "complete"
                } else if index == activeIndex {
                    "active"
                } else {
                    "upcoming"
                }
                assertValue(
                    expected,
                    for: "course-building-milestone-\(index + 1)",
                    in: app
                )
            }
            XCTAssertTrue(element("course-building-close", in: app).isEnabled)
            assertStrictIsolation(in: app)
            attachScreenshot(named: "LF-39 milestone \(activeIndex + 1)", app: app)
            assertStrictIsolation(in: app)
            app.terminate()
        }
    }

    @MainActor
    func testLF40GenerationErrorReturnsToExplicitNonLiveAgentReceipt() {
        let app = launch(.lf40GenerationError)
        assertValue("generation-error", for: "course-building-state", in: app)
        assertValue(
            "failed",
            for: "course-building-milestone-4",
            in: app
        )
        XCTAssertTrue(element("course-building-error", in: app).exists)
        XCTAssertFalse(
            app.staticTexts[
                "You can close this screen while generation continues with the app open."
            ].exists
        )
        let returnAction = element("course-building-return-agent", in: app)
        XCTAssertTrue(returnAction.isEnabled)
        assertStrictIsolation(in: app)

        returnAction.tap()

        XCTAssertTrue(
            element("course-building-returned-agent", in: app)
                .waitForExistence(timeout: 5)
        )
        assertValue(
            "--ui-test-lf40-returned-agent",
            for: "courseGenerationCheckpoint.state",
            in: app
        )
        assertValue(
            "1",
            for: "courseGenerationCheckpoint.memoryOnlyActions",
            in: app
        )
        XCTAssertTrue(
            element("course-building-returned-agent-boundary", in: app).exists
        )
        assertPersistentMutationsRemainZero(in: app)
        assertStrictIsolation(in: app)
        attachScreenshot(named: "LF-40 returned agent receipt", app: app)
        assertStrictIsolation(in: app)
        app.terminate()
    }

    @MainActor
    func testLF40ReturnedAgentDirectStateNeverClaimsLiveRuntimeProof() {
        let app = launch(.lf40ReturnedAgent)
        XCTAssertTrue(element("course-building-returned-agent", in: app).exists)
        XCTAssertTrue(
            element("course-building-returned-agent-boundary", in: app).exists
        )
        assertValue(
            "0",
            for: "courseGenerationCheckpoint.memoryOnlyActions",
            in: app
        )
        assertPersistentMutationsRemainZero(in: app)
        assertStrictIsolation(in: app)
        app.terminate()
    }

    @MainActor
    func testLF44PendingGeneratingAndPartialGeneratedStates() {
        let pending = launch(.lf44Pending)
        assertValue(
            "pending",
            for: "course-node-generation-checkpoint",
            in: pending
        )
        assertValue(
            "pending_generation",
            for: "course-learning-node-lf44-chapter",
            in: pending
        )
        let generate = element("generate-course-node-lf44-chapter", in: pending)
        XCTAssertTrue(generate.isEnabled)
        assertValue("pending_generation", for: generate)
        generate.tap()
        assertValue(
            "1",
            for: "courseGenerationCheckpoint.memoryOnlyActions",
            in: pending
        )
        assertPersistentMutationsRemainZero(in: pending)
        assertStrictIsolation(in: pending)
        attachScreenshot(named: "LF-44 pending", app: pending)
        pending.terminate()

        let generating = launch(.lf44Generating)
        assertValue(
            "generating",
            for: "course-node-generation-checkpoint",
            in: generating
        )
        assertValue(
            "partially_generated",
            for: "course-learning-node-lf44-chapter",
            in: generating
        )
        assertValue(
            "generating",
            for: "course-node-generation-status-lf44-lesson-ready",
            in: generating
        )
        assertStrictIsolation(in: generating)
        attachScreenshot(named: "LF-44 generating", app: generating)
        generating.terminate()

        let partial = launch(.lf44PartialGenerated)
        assertValue(
            "partial-generated",
            for: "course-node-generation-checkpoint",
            in: partial
        )
        assertValue(
            "partially_generated",
            for: "course-learning-node-lf44-chapter",
            in: partial
        )
        assertValue(
            "generated",
            for: "course-node-generation-status-lf44-lesson-ready",
            in: partial
        )
        assertValue(
            "pending_generation",
            for: "course-learning-node-lf44-lesson-next",
            in: partial
        )
        assertStrictIsolation(in: partial)
        attachScreenshot(named: "LF-44 partially generated", app: partial)
        partial.terminate()
    }

    @MainActor
    func testLF44BackgroundErrorOffersMemoryOnlyRecoveryAction() {
        let app = launch(.lf44Error)
        assertValue("error", for: "course-node-generation-checkpoint", in: app)
        XCTAssertTrue(element("course-node-generation-error", in: app).exists)
        let recovery = element(
            "course-node-generation-error-open-agent",
            in: app
        )
        XCTAssertTrue(recovery.isEnabled)
        assertStrictIsolation(in: app)
        recovery.tap()
        assertValue(
            "1",
            for: "courseGenerationCheckpoint.memoryOnlyActions",
            in: app
        )
        assertPersistentMutationsRemainZero(in: app)
        assertStrictIsolation(in: app)
        attachScreenshot(named: "LF-44 actionable error", app: app)
        app.terminate()
    }

    @MainActor
    private func launch(_ scenario: Scenario) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments = [scenario.route, scenario.rawValue]
        app.launch()

        let root = element("courseGenerationCheckpoint.root", in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        assertValue(
            scenario.route,
            for: "courseGenerationCheckpoint.route",
            in: app
        )
        assertValue(
            scenario.rawValue,
            for: "courseGenerationCheckpoint.state",
            in: app
        )
        assertValue(
            scenario.hook,
            for: "courseGenerationCheckpoint.hook",
            in: app
        )
        assertPersistentMutationsRemainZero(in: app)
        assertStrictIsolation(in: app)
        return app
    }

    @MainActor
    private func assertStrictIsolation(in app: XCUIApplication) {
        XCTAssertTrue(
            element("courseGenerationCheckpoint.strictRoot", in: app)
                .waitForExistence(timeout: 10)
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let counter = element(
            "courseGenerationCheckpoint.forbiddenSideEffects",
            in: app
        )
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        let zero = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@ AND value == %@",
                "Forbidden production entry events · 0",
                "0"
            ),
            object: counter
        )
        let details = element(
            "courseGenerationCheckpoint.forbiddenSideEffectDetails",
            in: app
        )
        let failure = "Strict generation root reached forbidden production entries: \(details.exists ? details.label : "none")"
        XCTAssertEqual(
            XCTWaiter.wait(for: [zero], timeout: 5),
            .completed,
            failure
        )
    }

    @MainActor
    private func assertPersistentMutationsRemainZero(in app: XCUIApplication) {
        let marker = element(
            "courseGenerationCheckpoint.persistentMutations",
            in: app
        )
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        XCTAssertEqual(marker.label, "Persistent mutations · 0")
        XCTAssertEqual(
            marker.value as? String,
            "keychain=0,defaults=0,pasteboard=0,network=0,files=0"
        )
    }

    @MainActor
    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func assertValue(
        _ expected: String,
        for identifier: String,
        in app: XCUIApplication
    ) {
        let target = element(identifier, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5), identifier)
        assertValue(expected, for: target)
    }

    @MainActor
    private func assertValue(
        _ expected: String,
        for target: XCUIElement
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                block: { object, _ in
                    (object as? XCUIElement)?.value as? String == expected
                }
            ),
            object: target
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "\(target.identifier) never reached value \(expected)"
        )
    }

    @MainActor
    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
