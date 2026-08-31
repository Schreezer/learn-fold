import XCTest

/// Debug-only evidence checkpoints. Each fixture is explicitly non-live and
/// carries no usable pairing data, credential, endpoint, or camera session.
final class HermesLinkCheckpointUITests: XCTestCase {
    private enum Scenario: String, CaseIterable {
        case initial, copied, creating, waiting, paused, retrying, expired, renewed
        case review, confirmation, claiming, finishing
        case scanner, cameraDenied = "camera-denied", parseError = "parse-error"
        case validReview = "valid-review"
    }

    @MainActor
    func testHermesLinkCheckpointRoutesExposeNonLiveBoundaryAndStableStates() {
        for scenario in Scenario.allCases {
            let app = launch(scenario: scenario)
            assertScenarioState(scenario, in: app)
            assertStrictIsolation(in: app, context: "\(scenario.rawValue) before action")
            assertNoSensitivePairingMaterial(in: app, scenario: scenario.rawValue)

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Hermes Link checkpoint \(scenario.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)

            exerciseRenderOnlyAction(for: scenario, in: app)
            assertStrictIsolation(in: app, context: "\(scenario.rawValue) after action")
            assertNoSensitivePairingMaterial(in: app, scenario: scenario.rawValue)
            app.terminate()
        }
    }

    @MainActor
    func testInitialCheckpointCopyUsesFixtureAndExposesWaitingState() {
        let app = launch(scenario: .initial)
        assertStrictIsolation(in: app, context: "initial before copy")
        let copy = app.buttons["alleycat.copyAgentSetupPrompt"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        copy.tap()
        XCTAssertTrue(waitForLabel(status(in: app), "Waiting for Hermes…"))
        assertStrictIsolation(in: app, context: "initial after copy")
    }

    @MainActor
    func testExpiredCheckpointRenewsIntoCopiedWaitingState() {
        let app = launch(scenario: .expired)
        assertStrictIsolation(in: app, context: "expired before renewal")
        let copy = app.buttons["alleycat.copyAgentSetupPrompt"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        XCTAssertEqual(copy.label, "Copy New Setup Prompt")
        copy.tap()
        XCTAssertTrue(waitForLabel(copy, "Prompt Copied — Waiting"))
        XCTAssertTrue(waitForLabel(status(in: app), "Waiting for Hermes…"))
        assertStrictIsolation(in: app, context: "expired after renewal")
    }

    @MainActor
    func testReviewConfirmationAndFinishAreGatedDeterministically() {
        let app = launch(scenario: .review)
        assertStrictIsolation(in: app, context: "review before confirmation")
        let review = app.buttons["hermes-link-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        XCTAssertTrue(
            waitForValue(element("hermes-link-review-activation", in: app), "1"),
            "Review control did not activate exactly once"
        )
        let confirmation = app.alerts["Hermes is ready"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        let connect = confirmation.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        XCTAssertTrue(waitForLabel(status(in: app), "Pairing received. Finishing the connection…"))
        assertStrictIsolation(in: app, context: "review after finish")
    }

    @MainActor
    func testValidReviewIsOnlyAParsedPreviewWithoutHermesReview() {
        let app = launch(scenario: .validReview)
        XCTAssertTrue(app.staticTexts["Scanned Host"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Redacted Test Host"].exists)
        XCTAssertFalse(app.buttons["hermes-link-review"].exists)
        assertStrictIsolation(in: app, context: "valid review projection")
    }

    @MainActor
    func testCentralRouteQuarantinesMalformedAndEnvironmentAbsentLinkSignals() {
        let cases: [(name: String, arguments: [String], includesTestEnvironment: Bool)] = [
            (
                "missing-state",
                ["--ui-test-hermes-link-checkpoint"],
                true
            ),
            (
                "duplicate-route",
                [
                    "--ui-test-hermes-link-checkpoint", "waiting",
                    "--ui-test-hermes-link-checkpoint", "copied",
                ],
                true
            ),
            (
                "unknown-state",
                ["--ui-test-hermes-link-checkpoint", "unknown"],
                true
            ),
            (
                "extra-argument",
                ["--ui-test-hermes-link-checkpoint", "waiting", "bare-extra"],
                true
            ),
            (
                "testing-environment-absent",
                ["--ui-test-hermes-link-checkpoint", "waiting"],
                false
            ),
        ]

        for testCase in cases {
            let app = XCUIApplication()
            if testCase.includesTestEnvironment {
                app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
            }
            app.launchArguments = testCase.arguments
            app.launch()

            XCTAssertTrue(
                element("hermesLinkCheckpoint.configurationError", in: app)
                    .waitForExistence(timeout: 10),
                "\(testCase.name): central Link configuration quarantine did not render"
            )
            XCTAssertFalse(element("hermes-link-checkpoint-waiting", in: app).exists)
            XCTAssertFalse(element("alleycat-add-server-sheet", in: app).exists)
            assertStrictIsolation(in: app, context: testCase.name)
            assertNoSensitivePairingMaterial(in: app, scenario: testCase.name)
            app.terminate()
        }
    }

    @MainActor
    private func launch(scenario: Scenario) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments = ["--ui-test-hermes-link-checkpoint", scenario.rawValue]
        app.launch()
        assertStrictIsolation(in: app, context: "\(scenario.rawValue) launch")
        return app
    }

    @MainActor
    private func assertScenarioState(_ scenario: Scenario, in app: XCUIApplication) {
        let checkpointRoot = element(
            "hermes-link-checkpoint-\(scenario.rawValue)",
            in: app
        )
        XCTAssertTrue(
            checkpointRoot.waitForExistence(timeout: 10),
            "Missing typed \(scenario.rawValue) Link checkpoint root"
        )
        XCTAssertTrue(
            element("hermes-link-checkpoint-boundary", in: app)
                .waitForExistence(timeout: 5),
            "Missing non-live Link boundary for \(scenario.rawValue)"
        )

        switch scenario {
        case .scanner:
            XCTAssertTrue(
                element("hermes-link-scanner-checkpoint-boundary", in: app)
                    .waitForExistence(timeout: 5)
            )
            XCTAssertTrue(app.staticTexts["NON-LIVE CHECKPOINT — camera disabled"].exists)
            XCTAssertTrue(app.buttons["alleycat.scanner.cancelButton"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Pair with Learnfold Link"].waitForExistence(timeout: 5))
        case .cameraDenied:
            XCTAssertTrue(app.alerts["Camera Access Needed"].waitForExistence(timeout: 5))
        case .confirmation:
            XCTAssertTrue(app.alerts["Hermes is ready"].waitForExistence(timeout: 5))
        case .parseError:
            XCTAssertTrue(element("hermes-link-error", in: app).waitForExistence(timeout: 5))
        case .validReview:
            XCTAssertTrue(app.staticTexts["Scanned Host"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Redacted Test Host"].exists)
        default:
            break
        }

        if scenario != .scanner {
            XCTAssertTrue(
                waitForLabel(status(in: app), expectedStatus(for: scenario)),
                "Unexpected Link status for \(scenario.rawValue)"
            )
            let copy = app.buttons["alleycat.copyAgentSetupPrompt"]
            XCTAssertTrue(copy.waitForExistence(timeout: 5))
            XCTAssertTrue(waitForLabel(copy, expectedCopyTitle(for: scenario)))
            XCTAssertEqual(copy.isEnabled, scenario != .creating)

            let spinner = element("hermes-link-action-spinner", in: app)
            if scenario == .creating {
                XCTAssertTrue(spinner.waitForExistence(timeout: 5))
            } else {
                XCTAssertFalse(spinner.exists)
            }

            let review = app.buttons["hermes-link-review"]
            if scenario == .review {
                XCTAssertTrue(review.waitForExistence(timeout: 5))
            } else if scenario == .confirmation {
                XCTAssertTrue(review.exists)
                XCTAssertFalse(
                    review.isHittable,
                    "Confirmation must block the underlying Review action"
                )
            } else {
                XCTAssertFalse(review.exists)
            }
        }
    }

    @MainActor
    private func exerciseRenderOnlyAction(for scenario: Scenario, in app: XCUIApplication) {
        switch scenario {
        case .creating:
            XCTAssertFalse(app.buttons["alleycat.copyAgentSetupPrompt"].isEnabled)
        case .review:
            let review = app.buttons["hermes-link-review"]
            XCTAssertTrue(review.isHittable)
            review.tap()
            XCTAssertTrue(
                waitForValue(element("hermes-link-review-activation", in: app), "1"),
                "Review control did not activate exactly once"
            )
            XCTAssertTrue(app.alerts["Hermes is ready"].waitForExistence(timeout: 5))
        case .confirmation:
            let connect = app.alerts["Hermes is ready"].buttons["Connect"]
            XCTAssertTrue(connect.waitForExistence(timeout: 5))
            connect.tap()
            XCTAssertTrue(
                waitForLabel(status(in: app), "Pairing received. Finishing the connection…")
            )
        case .scanner:
            let copy = app.buttons["alleycat.scanner.copyCommandButton"]
            XCTAssertTrue(copy.waitForExistence(timeout: 5))
            XCTAssertTrue(waitForLabel(copy, "Copy command"))
            copy.tap()
            XCTAssertTrue(waitForLabel(copy, "Copied"))
            assertStrictIsolation(in: app, context: "scanner after render-only copy")

            let cancel = app.buttons["alleycat.scanner.cancelButton"]
            XCTAssertTrue(cancel.isHittable)
            cancel.tap()
            XCTAssertTrue(waitForAbsence(element("hermes-link-scanner-checkpoint-boundary", in: app)))
        case .cameraDenied:
            let cancel = app.alerts["Camera Access Needed"].buttons["Cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.tap()
            XCTAssertTrue(waitForAbsence(app.alerts["Camera Access Needed"]))
        case .validReview:
            let connect = app.buttons["alleycat.connectRemoteHost"]
            XCTAssertTrue(scrollUntilHittable(connect, in: app))
            connect.tap()
            XCTAssertTrue(app.staticTexts["Redacted Test Host"].exists)
        default:
            let copy = app.buttons["alleycat.copyAgentSetupPrompt"]
            XCTAssertTrue(copy.isHittable)
            copy.tap()
            XCTAssertTrue(waitForLabel(status(in: app), "Waiting for Hermes…"))
            XCTAssertTrue(waitForLabel(copy, "Prompt Copied — Waiting"))
        }
    }

    @MainActor
    private func assertStrictIsolation(in app: XCUIApplication, context: String) {
        let root = element("hermesLinkCheckpoint.strictRoot", in: app)
        XCTAssertTrue(
            root.waitForExistence(timeout: 10),
            "\(context): strict Link sentinel root did not render"
        )
        XCTAssertEqual(
            root.label,
            "STRICT LINK NON-LIVE FIXTURE ROOT · LIVE LIFECYCLE SUPPRESSED"
        )
        XCTAssertFalse(root.frame.isEmpty, "\(context): strict Link root has no visible frame")
        XCTAssertTrue(
            root.frame.intersects(app.frame),
            "\(context): strict Link root is outside the visible application frame"
        )

        let counter = element("hermesLinkCheckpoint.forbiddenSideEffects", in: app)
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        let zero = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@ AND value == %@",
                "Forbidden production entry events · 0",
                "0"
            ),
            object: counter
        )
        let details = element("hermesLinkCheckpoint.forbiddenSideEffectDetails", in: app)
        XCTAssertEqual(
            XCTWaiter.wait(for: [zero], timeout: 5),
            .completed,
            "\(context): strict Link root reached forbidden production entries: \(details.exists ? details.label : "none")"
        )
        XCTAssertEqual(counter.value as? String, "0")
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func waitForAbsence(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 8
    ) -> Bool {
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func status(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "hermes-link-status").firstMatch
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", value),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor
    private func assertNoSensitivePairingMaterial(
        in app: XCUIApplication,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hierarchy = app.debugDescription
        let forbiddenFragments = [
            "litter-pairing-broker.chiragmgg.workers.dev",
            "chiragmgg.workers.dev",
            "claim_token",
            "claimToken",
            "pairing_payload",
            "Bearer ",
            "REDACTED-REQUEST",
            "REDACTED-NODE",
            #"\"token\":\"REDACTED\""#,
        ]
        for forbidden in forbiddenFragments {
            XCTAssertFalse(
                hierarchy.contains(forbidden),
                "\(scenario) exposed forbidden pairing material: \(forbidden)",
                file: file,
                line: line
            )
        }

        let keyPattern = try! NSRegularExpression(
            pattern: #"(?:sk-[A-Za-z0-9_-]{12,}|Bearer\s+[A-Za-z0-9._-]{8,})"#
        )
        XCTAssertEqual(
            keyPattern.numberOfMatches(
                in: hierarchy,
                range: NSRange(hierarchy.startIndex..., in: hierarchy)
            ),
            0,
            "\(scenario) exposed a token-shaped value",
            file: file,
            line: line
        )

        let hostPattern = try! NSRegularExpression(pattern: #"https://([A-Za-z0-9.-]+)"#)
        for match in hostPattern.matches(
            in: hierarchy,
            range: NSRange(hierarchy.startIndex..., in: hierarchy)
        ) {
            guard let range = Range(match.range(at: 1), in: hierarchy) else { continue }
            let host = String(hierarchy[range])
            XCTAssertTrue(
                host == "example.invalid" || host == "...",
                "\(scenario) exposed a non-fixture URL host: \(host)",
                file: file,
                line: line
            )
        }
    }

    private func expectedStatus(for scenario: Scenario) -> String {
        switch scenario {
        case .initial: "Create a secure request, then paste the prompt into Hermes."
        case .creating: "Creating a secure request…"
        case .paused: "Pairing paused while Learnfold is in the background."
        case .retrying: "Network interrupted. Retrying this same request…"
        case .expired: "This request expired. Copy a new setup prompt to try again."
        case .renewed: "New secure request created. Waiting for Hermes…"
        case .review, .confirmation: "Hermes sent the pairing securely."
        case .claiming: "Claiming the one-time credential…"
        case .finishing: "Pairing received. Finishing the connection…"
        case .scanner, .cameraDenied, .parseError, .validReview:
            "Redacted QR/paste pairing preview."
        case .copied, .waiting:
            "Waiting for Hermes…"
        }
    }

    private func expectedCopyTitle(for scenario: Scenario) -> String {
        switch scenario {
        case .copied, .renewed: "Prompt Copied — Waiting"
        case .expired: "Copy New Setup Prompt"
        default: "Copy Setup Prompt"
        }
    }
}
