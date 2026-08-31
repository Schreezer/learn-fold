import XCTest

final class ServerLifecycleCheckpointUITests: XCTestCase {
    private enum Route {
        static let lifecycle = "--ui-test-server-lifecycle"
        static let sshLogin = "--ui-test-ssh-login"
        static let sshAgentPicker = "--ui-test-ssh-agent-picker"
        static let manualServer = "--ui-test-manual-server"
        static let slingshotBrowser = "--ui-test-slingshot-browser"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLF09ServerLifecycleCheckpointsAndDisconnectedRecovery() {
        for state in ["connecting", "waking", "progress", "connected", "disconnected"] {
            let app = launch(route: Route.lifecycle, state: "server-lifecycle-\(state)")

            XCTAssertTrue(
                element("server-lifecycle-checkpoint-root", in: app).waitForExistence(timeout: 10)
            )
            assertStatus("server-lifecycle-status", equals: state, in: app)
            assertValue("server-lifecycle-live-root", equals: state, in: app)

            let row = element("discovery.server.codex.redacted_invalid", in: app)
            XCTAssertTrue(row.exists)
            let expectedRowStatus = switch state {
            case "progress": "starting"
            default: state
            }
            XCTAssertEqual(row.value as? String, expectedRowStatus)
            attachScreenshot(named: "LF-09 \(state) baseline", app: app)

            if state == "disconnected" {
                XCTAssertTrue(waitUntilHittable(row, timeout: 10))
                row.tap()
                assertStatus("server-lifecycle-status", equals: "progress", in: app)
                assertValue("server-lifecycle-live-root", equals: "progress", in: app)
                XCTAssertEqual(row.value as? String, "starting")
                assertStrictIsolation(in: app)
                attachScreenshot(named: "LF-09 disconnected recovery progress", app: app)
            } else if state == "connecting" || state == "waking" {
                XCTAssertFalse(row.isEnabled)
            }

            assertStrictIsolation(in: app)
            app.terminate()
        }
    }

    @MainActor
    func testLF11SSHLoginCheckpointsPreserveInputsAndHoldSubmission() {
        for state in ["empty", "auth-error", "submitted"] {
            let app = launch(route: Route.sshLogin, state: "ssh-login-\(state)")

            XCTAssertTrue(
                element("ssh-login-checkpoint-root", in: app).waitForExistence(timeout: 10)
            )
            assertStatus("ssh-login-status", equals: state, in: app)

            let username = element("ssh-login-username", in: app)
            let password = element("ssh-login-password", in: app)
            let passwordState = element("ssh-login-password-state", in: app)
            let connect = element("ssh-login-connect", in: app)
            XCTAssertTrue(username.exists)
            XCTAssertTrue(password.exists)
            XCTAssertTrue(passwordState.exists)
            XCTAssertTrue(scrollUntilHittable(connect, in: app))

            switch state {
            case "empty":
                XCTAssertFalse(connect.isEnabled)
                XCTAssertFalse(element("ssh-login-error", in: app).exists)
                XCTAssertEqual(passwordState.label, "credential empty")
            case "auth-error":
                XCTAssertEqual(username.value as? String, "checkpoint-user")
                XCTAssertEqual(passwordState.label, "credential retained")
                let error = element("ssh-login-error", in: app)
                XCTAssertTrue(error.waitForExistence(timeout: 10))
                XCTAssertEqual(
                    error.label,
                    "Authentication failed for the redacted test host."
                )
                XCTAssertTrue(scrollUntilHittable(error, in: app))
                attachScreenshot(named: "LF-11 auth-error baseline", app: app)
                XCTAssertTrue(scrollUntilHittable(connect, in: app))
                connect.tap()
                assertStatus(
                    "ssh-login-status",
                    equals: "submitted",
                    in: app,
                    requireHittable: false
                )
                XCTAssertFalse(element("ssh-login-error", in: app).exists)
                XCTAssertEqual(username.value as? String, "checkpoint-user")
                XCTAssertEqual(passwordState.label, "credential retained")
                assertStrictIsolation(in: app)
                attachScreenshot(named: "LF-11 auth-error retry submitted", app: app)
            default:
                XCTAssertEqual(username.value as? String, "checkpoint-user")
                XCTAssertEqual(passwordState.label, "credential retained")
                XCTAssertFalse(connect.isEnabled)
                XCTAssertFalse(element("ssh-login-error", in: app).exists)
            }

            if state != "auth-error" {
                attachScreenshot(named: "LF-11 \(state) baseline", app: app)
            }
            assertStrictIsolation(in: app)
            app.terminate()
        }
    }

    @MainActor
    func testLF12SSHAgentPickerCheckpointsAndSelectionRecovery() {
        for state in ["loading", "error", "populated"] {
            let app = launch(
                route: Route.sshAgentPicker,
                state: "ssh-agent-picker-\(state)"
            )

            XCTAssertTrue(
                element("ssh-agent-picker-checkpoint-root", in: app).waitForExistence(timeout: 10)
            )
            assertStatus("ssh-agent-picker-status", equals: state, in: app)

            let claude = element("ssh-agent-row-claude", in: app)
            let pi = element("ssh-agent-row-pi", in: app)
            let unavailable = element("ssh-agent-row-opencode", in: app)
            let connect = element("ssh-agent-connect", in: app)
            XCTAssertTrue(claude.exists)
            XCTAssertTrue(pi.exists)
            XCTAssertTrue(unavailable.exists)

            attachScreenshot(named: "LF-12 \(state) baseline", app: app)

            switch state {
            case "loading":
                XCTAssertFalse(claude.isEnabled)
                XCTAssertFalse(connect.isEnabled)
            case "error":
                XCTAssertTrue(element("ssh-agent-picker-error", in: app).exists)
                XCTAssertEqual(claude.value as? String, "selected")
                XCTAssertEqual(pi.value as? String, "selected")
                XCTAssertTrue(scrollUntilHittable(connect, in: app))
                connect.tap()
                assertStatus("ssh-agent-picker-status", equals: "loading", in: app)
                XCTAssertFalse(element("ssh-agent-picker-error", in: app).exists)
                assertStrictIsolation(in: app)
                attachScreenshot(named: "LF-12 error retry loading", app: app)
            default:
                XCTAssertEqual(claude.value as? String, "selected")
                XCTAssertEqual(pi.value as? String, "selected")
                XCTAssertFalse(unavailable.isEnabled)
                XCTAssertTrue(scrollUntilHittable(claude, in: app))
                claude.tap()
                XCTAssertEqual(claude.value as? String, "not selected")
                XCTAssertTrue(connect.isEnabled, "The remaining selected Pi agent should keep Connect enabled")
                assertStrictIsolation(in: app)
                attachScreenshot(named: "LF-12 populated selection changed", app: app)
            }

            assertStrictIsolation(in: app)
            app.terminate()
        }
    }

    @MainActor
    func testLF13ManualServerInvalidAndSubmittedCheckpoints() {
        let invalid = launch(route: Route.manualServer, state: "manual-server-invalid")
        let invalidRoot = element("manual-server-checkpoint-root", in: invalid)
        XCTAssertTrue(invalidRoot.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForEither(
                element("manual-server-error", in: invalid),
                invalid.alerts["Connection Failed"],
                timeout: 10
            ),
            "Invalid URL validation did not surface an error"
        )

        if invalid.alerts["Connection Failed"].exists {
            invalid.alerts["Connection Failed"].buttons["OK"].tap()
        }
        assertStatus("manual-server-status", equals: "invalid", in: invalid)
        let url = element("manual-server-url", in: invalid)
        XCTAssertEqual(url.value as? String, "https://redacted.invalid")
        attachScreenshot(named: "LF-13 invalid baseline", app: invalid)
        let cancel = element("manual-server-cancel", in: invalid)
        XCTAssertTrue(waitUntilHittable(cancel, timeout: 10))
        cancel.tap()
        XCTAssertTrue(
            element("discovery.chooser.manual", in: invalid).waitForExistence(timeout: 5),
            "Cancelling validation should return safely to the chooser"
        )
        assertStrictIsolation(in: invalid)
        attachScreenshot(named: "LF-13 invalid cancel recovery", app: invalid)
        invalid.terminate()

        let submitted = launch(route: Route.manualServer, state: "manual-server-submitted")
        XCTAssertTrue(
            element("manual-server-submitted-root", in: submitted).waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            element("manual-server-checkpoint-root", in: submitted).waitForNonExistence(timeout: 10),
            "The valid manual form did not advance to connection progress"
        )
        assertStatus("manual-server-status", equals: "submitted", in: submitted)
        XCTAssertTrue(submitted.staticTexts["starting"].exists)
        assertStrictIsolation(in: submitted)
        attachScreenshot(named: "LF-13 submitted baseline", app: submitted)
        submitted.terminate()
    }

    @MainActor
    func testLF14SlingshotBrowserCheckpointsAndRetryRecovery() {
        for state in ["loading", "error", "results"] {
            let app = launch(
                route: Route.slingshotBrowser,
                state: "slingshot-browser-\(state)"
            )

            XCTAssertTrue(
                element("slingshot-browser-checkpoint-root", in: app).waitForExistence(timeout: 10)
            )
            assertStatus("slingshot-browser-status", equals: state, in: app)

            switch state {
            case "loading":
                XCTAssertFalse(element("slingshot-browser-row-redacted-test-mac", in: app).exists)
            case "error":
                XCTAssertTrue(element("slingshot-browser-error", in: app).exists)
                attachScreenshot(named: "LF-14 error baseline", app: app)
                let retry = element("slingshot-browser-retry", in: app)
                XCTAssertTrue(scrollUntilHittable(retry, in: app))
                retry.tap()
                assertStatus("slingshot-browser-status", equals: "results", in: app)
                XCTAssertTrue(
                    element("slingshot-browser-row-redacted-test-mac", in: app)
                        .waitForExistence(timeout: 5)
                )
                assertStrictIsolation(in: app)
                attachScreenshot(named: "LF-14 error retry results", app: app)
            default:
                XCTAssertTrue(element("slingshot-browser-row-redacted-test-mac", in: app).exists)
                XCTAssertTrue(element("slingshot-browser-row-redacted-test-linux", in: app).exists)
                XCTAssertFalse(element("slingshot-browser-row-redacted-test-linux", in: app).isEnabled)
            }

            if state != "error" {
                attachScreenshot(named: "LF-14 \(state) baseline", app: app)
            }
            assertStrictIsolation(in: app)
            app.terminate()
        }
    }

    @MainActor
    func testAlternateCheckpointNavigationKeepsSSHCredentialStoreInert() {
        let cases: [(route: String, state: String, initialRoot: String)] = [
            (
                Route.sshAgentPicker,
                "ssh-agent-picker-populated",
                "ssh-agent-picker-checkpoint-root"
            ),
            (
                Route.manualServer,
                "manual-server-invalid",
                "manual-server-checkpoint-root"
            ),
            (
                Route.slingshotBrowser,
                "slingshot-browser-results",
                "slingshot-browser-checkpoint-root"
            ),
        ]

        for testCase in cases {
            let app = launch(route: testCase.route, state: testCase.state)
            XCTAssertTrue(
                element(testCase.initialRoot, in: app).waitForExistence(timeout: 10)
            )

            switch testCase.route {
            case Route.sshAgentPicker:
                let cancel = app.buttons["Cancel"].firstMatch
                XCTAssertTrue(waitUntilHittable(cancel, timeout: 10))
                cancel.tap()
            case Route.manualServer:
                let alert = app.alerts["Connection Failed"]
                if alert.waitForExistence(timeout: 2) {
                    alert.buttons["OK"].tap()
                }
                let cancel = element("manual-server-cancel", in: app)
                XCTAssertTrue(waitUntilHittable(cancel, timeout: 10))
                cancel.tap()
            default:
                let cancel = element("slingshot-browser-cancel", in: app)
                XCTAssertTrue(waitUntilHittable(cancel, timeout: 10))
                cancel.tap()
            }

            let manual = element("discovery.chooser.manual", in: app)
            XCTAssertTrue(manual.waitForExistence(timeout: 10))
            XCTAssertTrue(waitUntilHittable(manual, timeout: 10))
            manual.tap()

            var host = element("manual-server-host", in: app)
            if !host.waitForExistence(timeout: 2) {
                let sshMode = app.buttons["SSH"].firstMatch
                XCTAssertTrue(waitUntilHittable(sshMode, timeout: 10))
                sshMode.tap()
                host = element("manual-server-host", in: app)
            }
            XCTAssertTrue(host.waitForExistence(timeout: 10))
            replaceText(in: host, with: "redacted.invalid")

            let port = element("manual-server-ssh-port", in: app)
            XCTAssertTrue(port.exists)
            replaceText(in: port, with: "2222")

            let submit = element("manual-server-submit", in: app)
            XCTAssertTrue(scrollUntilHittable(submit, in: app))
            submit.tap()

            XCTAssertTrue(
                element("ssh-login-checkpoint-root", in: app)
                    .waitForExistence(timeout: 10),
                "Alternate \(testCase.state) navigation did not reach SSH login"
            )
            assertStrictIsolation(in: app)
            attachScreenshot(
                named: "P2 \(testCase.state) alternate SSH login remains inert",
                app: app
            )
            app.terminate()
        }
    }

    @MainActor
    func testMalformedCheckpointConfigurationsFailClosedInProductShell() {
        let cases: [(name: String, arguments: [String], includeTestingEnvironment: Bool, code: String)] = [
            (
                "environment absent",
                [Route.lifecycle, "server-lifecycle-connected"],
                false,
                "testing-environment-required"
            ),
            (
                "environment absent malformed route",
                ["--ui-test-server-lifecycle-malformed", "server-lifecycle-connected"],
                false,
                "testing-environment-required"
            ),
            ("missing route", ["ssh-login-empty"], true, "missing-route"),
            ("missing state", [Route.lifecycle], true, "missing-state"),
            (
                "unknown state",
                [Route.lifecycle, "server-lifecycle-unknown"],
                true,
                "unknown-state"
            ),
            (
                "malformed route",
                ["--ui-test-server-lifecycle-malformed", "server-lifecycle-connected"],
                true,
                "missing-route"
            ),
            (
                "route mismatch",
                [Route.lifecycle, "ssh-login-empty"],
                true,
                "route-state-mismatch"
            ),
            (
                "duplicate route",
                [
                    Route.lifecycle, "server-lifecycle-connected",
                    Route.lifecycle, "server-lifecycle-connected",
                ],
                true,
                "duplicate-route"
            ),
            (
                "multiple routes",
                [
                    Route.lifecycle, "server-lifecycle-connected",
                    Route.sshLogin, "ssh-login-empty",
                ],
                true,
                "multiple-routes"
            ),
            (
                "malformed then valid",
                [
                    Route.lifecycle, "not-a-state",
                    Route.lifecycle, "server-lifecycle-connected",
                ],
                true,
                "duplicate-route"
            ),
            (
                "extra state",
                [Route.lifecycle, "server-lifecycle-connected", "ssh-login-empty"],
                true,
                "multiple-states"
            ),
            (
                "duplicate state",
                [
                    Route.lifecycle,
                    "server-lifecycle-connected",
                    "server-lifecycle-connected",
                ],
                true,
                "multiple-states"
            ),
            (
                "extra malformed state",
                [
                    Route.lifecycle, "server-lifecycle-connected",
                    "ssh-login-not-a-state",
                ],
                true,
                "multiple-states"
            ),
            (
                "unregistered checkpoint",
                [
                    Route.lifecycle,
                    "server-lifecycle-connected",
                    "--ui-test-unregistered-checkpoint",
                ],
                true,
                "unregistered-checkpoint"
            ),
        ]

        for testCase in cases {
            let app = launch(
                arguments: testCase.arguments,
                includeTestingEnvironment: testCase.includeTestingEnvironment
            )
            let configurationRoot = element("server-checkpoint-config-error-root", in: app)
            XCTAssertTrue(
                configurationRoot.waitForExistence(timeout: 10),
                "Missing fail-closed UI for \(testCase.name)"
            )
            XCTAssertEqual(configurationRoot.value as? String, testCase.code)
            XCTAssertFalse(element("server-lifecycle-checkpoint-root", in: app).exists)
            XCTAssertFalse(element("ssh-login-checkpoint-root", in: app).exists)
            assertStrictIsolation(in: app)
            attachScreenshot(named: "P2 config rejected - \(testCase.name)", app: app)
            app.terminate()
        }
    }

    @MainActor
    private func launch(route: String, state: String) -> XCUIApplication {
        launch(arguments: [route, state], includeTestingEnvironment: true)
    }

    @MainActor
    private func launch(
        arguments: [String],
        includeTestingEnvironment: Bool
    ) -> XCUIApplication {
        let app = XCUIApplication()
        if includeTestingEnvironment {
            app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        }
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["CODEXIOS_UI_TEST_FORCE_DISCOVERY"] = "1"
        app.launchArguments += arguments
        app.launch()
        assertStrictIsolation(in: app)
        return app
    }

    @MainActor
    private func assertStrictIsolation(in app: XCUIApplication) {
        let root = element("serverCheckpoint.strictRoot", in: app)
        XCTAssertTrue(
            root.waitForExistence(timeout: 10),
            "The strict server lifecycle root marker is missing"
        )
        XCTAssertTrue(
            waitUntilHittable(root, timeout: 10),
            "The strict server lifecycle root marker is not visible"
        )

        let counter = element("serverCheckpoint.forbiddenSideEffects", in: app)
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Forbidden production entry events · 0"
            ),
            object: counter
        )
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
        XCTAssertEqual(counter.value as? String, "0")
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func assertStatus(
        _ identifier: String,
        equals expected: String,
        in app: XCUIApplication,
        requireHittable: Bool = true
    ) {
        let deadline = Date().addingTimeInterval(10)
        var observedLabel: String?
        repeat {
            let status = element(identifier, in: app)
            if status.exists {
                observedLabel = status.label
                if observedLabel == expected { break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTAssertEqual(
            observedLabel,
            expected,
            "The \(identifier) marker did not reach \(expected)"
        )
        if requireHittable {
            let status = element(identifier, in: app)
            XCTAssertTrue(
                waitUntilHittable(status, timeout: 10),
                "The \(identifier) marker remained covered by launch UI"
            )
        }
    }

    @MainActor
    private func assertValue(
        _ identifier: String,
        equals expected: String,
        in app: XCUIApplication
    ) {
        let deadline = Date().addingTimeInterval(10)
        var observedValue: String?
        repeat {
            let status = element(identifier, in: app)
            if status.exists {
                observedValue = status.value as? String
                if observedValue == expected { break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTAssertEqual(
            observedValue,
            expected,
            "The \(identifier) marker value did not reach \(expected)"
        )
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
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 8
    ) -> Bool {
        for _ in 0..<attempts {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        field.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: 64)
        )
        field.typeText(text)
    }

    @MainActor
    private func waitForEither(
        _ first: XCUIElement,
        _ second: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if first.exists || second.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return first.exists || second.exists
    }

    @MainActor
    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
