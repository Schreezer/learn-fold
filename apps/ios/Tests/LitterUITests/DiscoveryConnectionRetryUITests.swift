import XCTest

final class DiscoveryConnectionRetryUITests: XCTestCase {
    private enum Route {
        static let serverLifecycle = "--ui-test-server-lifecycle"
    }

    private enum State: String {
        case failureAlert = "server-lifecycle-lf16-failure-alert"
        case postRetry = "server-lifecycle-lf16-post-retry"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLF16ConnectionFailureOffersRetryAndRecoversInStrictRoot() {
        let app = launch(.failureAlert)

        assertValue("failure-alert", for: "lf16-connection-retry-state", in: app)
        assertValue("1", for: "lf16-connection-retry-attempts", in: app)
        assertValue("lf-16-fault-hook", for: "lf16-connection-retry-hook", in: app)
        XCTAssertEqual(
            element("discovery.server.codex.retry-target_example", in: app).value as? String,
            "disconnected"
        )

        let alert = app.alerts["Connection Failed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        let safeFailure = "The server did not respond. Check that it is online and try again."
        let alertMessage = alert.staticTexts[safeFailure]
        XCTAssertTrue(alertMessage.exists)
        XCTAssertEqual(alertMessage.label, safeFailure)
        XCTAssertTrue(alert.buttons["Retry"].isEnabled)
        XCTAssertTrue(alert.buttons["OK"].exists)
        assertStrictIsolation(in: app)
        attachScreenshot(named: "LF-16 failure-alert", app: app)

        alert.buttons["Retry"].tap()

        assertValue("post-retry", for: "lf16-connection-retry-state", in: app)
        assertValue("2", for: "lf16-connection-retry-attempts", in: app)
        assertValue("lf-16-fault-hook", for: "lf16-connection-retry-hook", in: app)
        assertValue("post-retry", for: "lf16-connection-retry-receipt", in: app)
        assertValue(
            "receipt>selection",
            for: "lf16-connection-retry-order",
            in: app
        )
        XCTAssertEqual(
            element("discovery.server.codex.retry-target_example", in: app).value as? String,
            "connected"
        )
        XCTAssertFalse(app.alerts["Connection Failed"].exists)
        assertStrictIsolation(in: app)
        attachScreenshot(named: "LF-16 post-retry after product Retry", app: app)
        app.terminate()
    }

    @MainActor
    func testLF16PostRetryTypedStateReplaysTheRecoveredReceipt() {
        let app = launch(.postRetry)

        assertValue("post-retry", for: "lf16-connection-retry-state", in: app)
        assertValue("2", for: "lf16-connection-retry-attempts", in: app)
        assertValue("lf-16-fault-hook", for: "lf16-connection-retry-hook", in: app)
        assertValue("post-retry", for: "lf16-connection-retry-receipt", in: app)
        assertValue(
            "receipt>selection",
            for: "lf16-connection-retry-order",
            in: app
        )
        XCTAssertEqual(
            element("discovery.server.codex.retry-target_example", in: app).value as? String,
            "connected"
        )
        XCTAssertFalse(app.alerts["Connection Failed"].exists)
        assertStrictIsolation(in: app)
        attachScreenshot(named: "LF-16 post-retry typed state", app: app)
        app.terminate()
    }

    @MainActor
    private func launch(_ state: State) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchArguments += [Route.serverLifecycle, state.rawValue]
        app.launch()

        XCTAssertTrue(
            element("lf16-connection-retry-checkpoint-root", in: app)
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            element("serverCheckpoint.strictRoot", in: app)
                .waitForExistence(timeout: 10)
        )
        return app
    }

    @MainActor
    private func assertValue(
        _ expected: String,
        for identifier: String,
        in app: XCUIApplication
    ) {
        let marker = element(identifier, in: app)
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected),
            object: marker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    @MainActor
    private func assertStrictIsolation(in app: XCUIApplication) {
        let counter = element("serverCheckpoint.forbiddenSideEffects", in: app)
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        let zero = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@ AND value == %@",
                "Forbidden production entry events · 0",
                "0"
            ),
            object: counter
        )
        let details = element("serverCheckpoint.forbiddenSideEffectDetails", in: app)
        let failure = "LF-16 strict route entered production lifecycle: \(details.exists ? details.label : "none")"
        XCTAssertEqual(
            XCTWaiter.wait(for: [zero], timeout: 10),
            .completed,
            failure
        )
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
