import XCTest

/// Development-simulator accessibility-contract regressions. These selectors
/// do not produce acceptance evidence for the untouched acceptance simulator.
/// The picker launches a fresh non-strict setup state without any Apple
/// availability override; the splash uses only its exact debug freeze argument.
final class DevelopmentSimulatorAccessibilityContractUITests: XCTestCase {
    @MainActor
    func testDevelopmentSimulatorSplashFreezeMarksTheBrandedFrame() {
        let app = XCUIApplication()
        app.launchArguments = ["--lf-01-splash-freeze-hook"]
        app.launch()

        let frame = app.descendants(matching: .any)[
            "learnfold-splash-branded-frame"
        ]
        XCTAssertTrue(frame.waitForExistence(timeout: 10))
        XCTAssertEqual(frame.value as? String, "acceptance-freeze-active")
        app.terminate()
    }

    @MainActor
    func testDevelopmentSimulatorSetupPickerReportsStableAvailabilityOnPinnedIOS265() {
        let operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertEqual(operatingSystemVersion.majorVersion, 26)
        XCTAssertEqual(
            operatingSystemVersion.minorVersion,
            5,
            "This development-simulator selector is pinned to iOS 26.5."
        )

        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_RESET_ONBOARDING"] = "1"
        app.launch()

        let intro = app.staticTexts["learnfold-intro-title"]
        XCTAssertTrue(intro.waitForExistence(timeout: 15))
        let continueButton = app.buttons["learnfold-intro-continue"]
        let continuationHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: continueButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [continuationHittable], timeout: 10),
            .completed,
            "The non-strict setup continuation must be visibly tappable."
        )
        continueButton.tap()

        let picker = app.descendants(matching: .any)[
            "course-agent-setup-picker"
        ]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 15),
            "The non-strict development setup picker did not appear."
        )
        let privateCloud = app.descendants(matching: .any)[
            "course-agent-option-apple-private-cloud"
        ]
        let onDevice = app.descendants(matching: .any)[
            "course-agent-option-apple-on-device"
        ]
        let codex = app.descendants(matching: .any)["course-agent-option-codex"]
        for option in [privateCloud, onDevice, codex] {
            XCTAssertTrue(option.waitForExistence(timeout: 5), option.identifier)
        }

        let observedAvailability = [
            picker.value as? String,
            privateCloud.value as? String,
            onDevice.value as? String,
            codex.value as? String,
        ]
        let validAvailabilityMatrices: [[String?]] = [
            [
                "available=1,unavailable=2",
                "unavailable",
                "unavailable",
                "available-selected",
            ],
            [
                "available=2,unavailable=1",
                "unavailable",
                "available-selected",
                "available-not-selected",
            ],
        ]
        XCTAssertTrue(
            validAvailabilityMatrices.contains(observedAvailability),
            "The genuine iOS 26.5 picker must expose one of the two exact "
                + "state-consistent Apple Intelligence readiness matrices; "
                + "observed \(observedAvailability)."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["course-agent-option-hermes"].exists,
            "Hermes must not appear as a local picker row."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["course-agent-add-server"]
                .waitForExistence(timeout: 5),
            "Hermes remains available through the dedicated server connection CTA."
        )
        app.terminate()
    }

    @MainActor
    func testHostedBetaConfigurationSkipsManualAgentSetup() {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_RESET_ONBOARDING"] = "1"
        app.launchEnvironment["LEARNFOLD_HOSTED_AGENT_URL"] =
            "https://hosted.example.test"
        app.launchEnvironment["LEARNFOLD_HOSTED_ACCESS_TOKEN"] =
            "ui-test-beta-token"
        app.launch()

        let continueButton = app.buttons["learnfold-intro-continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 15))
        let continuationHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: continueButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [continuationHittable], timeout: 10),
            .completed
        )
        continueButton.tap()

        XCTAssertTrue(
            app.staticTexts["course-library-root"].waitForExistence(timeout: 15),
            "A configured beta build should enter the course library without requiring an agent choice."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["course-agent-setup-picker"].exists,
            "Hosted should be selected and connected automatically on a fresh beta setup."
        )

        let agentSettings = app.buttons["course-home-agent-settings"]
        XCTAssertTrue(agentSettings.waitForExistence(timeout: 5))
        agentSettings.tap()
        XCTAssertTrue(
            app.buttons["course-settings-agent-hosted"].waitForExistence(timeout: 10),
            "Hosted must remain available as the persisted course agent after automatic setup."
        )
        app.terminate()
    }
}
