import XCTest

final class ProviderSettingsSourceCheckpointUITests: XCTestCase {
    private enum Scenario: String, CaseIterable {
        case lf03PickerAvailable = "--ui-test-lf03-picker-available"
        case lf03PickerUnavailable = "--ui-test-lf03-picker-unavailable"
        case lf05Saving = "--ui-test-lf05-saving"
        case lf05SuccessReturn = "--ui-test-lf05-success-return"
        case lf05Error = "--ui-test-lf05-error"
        case lf06Connecting = "--ui-test-lf06-connecting"
        case lf06ConnectedTarget = "--ui-test-lf06-connected-target"
        case lf06Failed = "--ui-test-lf06-failed"
        case lf27ModelLoading = "--ui-test-lf27-model-loading"
        case lf27ModelEmpty = "--ui-test-lf27-model-empty"
        case lf27ModelDefault = "--ui-test-lf27-model-default"
        case lf27ModelPopulated = "--ui-test-lf27-model-populated"
        case lf27Checking = "--ui-test-lf27-checking"
        case lf27Cancel = "--ui-test-lf27-cancel"
        case lf27FailureRollback = "--ui-test-lf27-failure-rollback"
        case lf27AgentError = "--ui-test-lf27-agent-error"
        case lf28Synced = "--ui-test-lf28-synced"
        case lf28OnThisDevice = "--ui-test-lf28-on-this-device"
        case lf28SignInRequired = "--ui-test-lf28-sign-in-required"
        case lf28NeedsAttention = "--ui-test-lf28-needs-attention"
        case lf28Retry = "--ui-test-lf28-retry"
        case lf30SourceMenu = "--ui-test-lf30-source-menu"
        case lf30Preparing = "--ui-test-lf30-preparing"
        case lf30PassageContext = "--ui-test-lf30-passage-context"
        case lf30PermissionError = "--ui-test-lf30-permission-error"
        case lf30ParseError = "--ui-test-lf30-parse-error"
        case lf30PreparationError = "--ui-test-lf30-preparation-error"

        var checkpoint: String {
            switch self {
            case .lf03PickerAvailable, .lf03PickerUnavailable: "LF-03"
            case .lf05Saving, .lf05SuccessReturn, .lf05Error: "LF-05"
            case .lf06Connecting, .lf06ConnectedTarget, .lf06Failed: "LF-06"
            case .lf27ModelLoading, .lf27ModelEmpty, .lf27ModelDefault,
                 .lf27ModelPopulated, .lf27Checking, .lf27Cancel,
                 .lf27FailureRollback, .lf27AgentError: "LF-27"
            case .lf28Synced, .lf28OnThisDevice, .lf28SignInRequired,
                 .lf28NeedsAttention, .lf28Retry: "LF-28"
            case .lf30SourceMenu, .lf30Preparing, .lf30PassageContext,
                 .lf30PermissionError, .lf30ParseError,
                 .lf30PreparationError: "LF-30"
            }
        }

        var substate: String {
            rawValue
                .replacingOccurrences(of: "--ui-test-lf", with: "")
                .split(separator: "-", maxSplits: 1)
                .last
                .map(String.init) ?? ""
        }

        var boundary: String {
            switch checkpoint {
            case "LF-03":
                "NON-LIVE PICKER FIXTURE · LIVE-FROZEN PRODUCT COMPANION STILL REQUIRED"
            case "LF-05", "LF-06":
                "NON-LIVE COMPONENT CHECKPOINT · LIVE-CONTROLLED EVIDENCE STILL REQUIRED"
            case "LF-28":
                "NON-LIVE FIXTURE · USE ONLY WHEN LIVE ACCOUNT STATE IS UNAVAILABLE"
            default:
                "NON-LIVE FAULT CHECKPOINT · LIVE-PRODUCT COMPANION STILL REQUIRED"
            }
        }
    }

    @MainActor
    func testLF03SetupPickerAvailabilityUsesProductionContent() {
        let available = launch(.lf03PickerAvailable)
        assertValue(
            "lf-03-fixture-hook",
            for: "providerSettingsSourceCheckpoint.hook",
            in: available
        )
        assertValue(
            "available=3,unavailable=0",
            for: "course-agent-setup-picker",
            in: available
        )
        for identifier in [
            "course-agent-option-apple-private-cloud",
            "course-agent-option-apple-on-device",
            "course-agent-option-codex",
        ] {
            let option = element(identifier, in: available)
            XCTAssertTrue(option.waitForExistence(timeout: 5), identifier)
            XCTAssertTrue(option.isEnabled, identifier)
        }
        assertValue(
            "available-selected",
            for: "course-agent-option-codex",
            in: available
        )
        XCTAssertTrue(element("course-agent-add-server", in: available).exists)
        assertValue(
            "not-configured",
            for: "course-agent-custom-provider",
            in: available
        )
        attachScreenshot(named: "LF-03 picker available", app: available)

        element("course-agent-option-apple-on-device", in: available).tap()
        assertValue(
            "available-selected",
            for: "course-agent-option-apple-on-device",
            in: available
        )
        assertValue(
            "1",
            for: "providerSettingsSourceCheckpoint.memoryOnlyActions",
            in: available
        )
        XCTAssertFalse(element("course-agent-custom-provider", in: available).exists)
        assertStrictIsolation(in: available)
        assertPersistentMutationsRemainZero(in: available)
        available.terminate()

        let unavailable = launch(.lf03PickerUnavailable)
        assertValue(
            "lf-03-fixture-hook",
            for: "providerSettingsSourceCheckpoint.hook",
            in: unavailable
        )
        assertValue(
            "available=1,unavailable=2",
            for: "course-agent-setup-picker",
            in: unavailable
        )
        let privateCloud = element(
            "course-agent-option-apple-private-cloud",
            in: unavailable
        )
        let onDevice = element(
            "course-agent-option-apple-on-device",
            in: unavailable
        )
        XCTAssertFalse(privateCloud.isEnabled)
        XCTAssertFalse(onDevice.isEnabled)
        assertValue(
            "unavailable",
            for: "course-agent-option-apple-private-cloud",
            in: unavailable
        )
        assertValue(
            "unavailable",
            for: "course-agent-option-apple-on-device",
            in: unavailable
        )
        XCTAssertTrue(
            unavailable.staticTexts[
                "Requires an eligible iPhone and supported region"
            ].exists
        )
        XCTAssertTrue(
            unavailable.staticTexts[
                "Requires Apple Intelligence on this iPhone"
            ].exists
        )
        assertValue(
            "available-selected",
            for: "course-agent-option-codex",
            in: unavailable
        )
        XCTAssertTrue(element("course-agent-add-server", in: unavailable).exists)
        assertValue(
            "not-configured",
            for: "course-agent-custom-provider",
            in: unavailable
        )
        attachScreenshot(named: "LF-03 picker unavailable", app: unavailable)
        assertStrictIsolation(in: unavailable)
        assertPersistentMutationsRemainZero(in: unavailable)
        unavailable.terminate()
    }

    @MainActor
    func testLF05ProviderLifecycleStatesAndCancelInvariant() {
        for scenario in [
            Scenario.lf05Saving,
            .lf05SuccessReturn,
            .lf05Error,
        ] {
            let app = launch(scenario)
            switch scenario {
            case .lf05Saving:
                assertValue("saving", for: "custom-provider-form", in: app)
                guard let savingMarker = scrollFormUntilUniqueHittableMarker(
                    "custom-provider-saving",
                    in: app
                ) else { return }
                XCTAssertTrue(savingMarker.exists)
                let saveButton = app.buttons["custom-provider-save"]
                XCTAssertTrue(saveButton.exists)
                XCTAssertEqual(saveButton.label, "Saving…")
                XCTAssertFalse(saveButton.isEnabled)
                let cancelButton = app.buttons["custom-provider-cancel"]
                XCTAssertTrue(cancelButton.exists)
                XCTAssertEqual(cancelButton.label, "Cancel")
                XCTAssertFalse(cancelButton.isEnabled)
            case .lf05SuccessReturn:
                XCTAssertTrue(element("lf05-provider-activated", in: app).exists)
                assertValue(
                    "connected",
                    for: "course-agent-custom-provider",
                    in: app
                )
            case .lf05Error:
                assertValue("error", for: "custom-provider-form", in: app)
                guard let errorMarker = scrollFormUntilUniqueHittableMarker(
                    "custom-provider-error",
                    in: app
                ) else { return }
                XCTAssertTrue(errorMarker.exists)
                let cancelButton = app.buttons["custom-provider-cancel"]
                XCTAssertTrue(cancelButton.exists)
                XCTAssertEqual(cancelButton.label, "Cancel")
                XCTAssertTrue(cancelButton.isEnabled)
                let saveButton = app.buttons["custom-provider-save"]
                XCTAssertTrue(saveButton.exists)
                XCTAssertEqual(saveButton.label, "Save")
                XCTAssertTrue(saveButton.isEnabled)
                XCTAssertTrue(
                    app.staticTexts[
                        "The provider could not be verified. Check the endpoint and try again."
                    ].exists
                )
            default:
                XCTFail("Unexpected LF-05 scenario")
            }
            attachScreenshot(named: "\(scenario.checkpoint) \(scenario.substate)", app: app)
            assertStrictIsolation(in: app)
            app.terminate()
        }

        let cancelApp = launch(.lf05Error)
        let cancelButton = cancelApp.buttons["custom-provider-cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(cancelButton, timeout: 5))
        cancelButton.tap()
        XCTAssertTrue(
            element("lf05-cancelled", in: cancelApp)
                .waitForExistence(timeout: 5)
        )
        assertStrictIsolation(in: cancelApp)
        assertPersistentMutationsRemainZero(in: cancelApp)
        attachScreenshot(named: "LF-05 cancel leaves settings unchanged", app: cancelApp)
        assertStrictIsolation(in: cancelApp)
        cancelApp.terminate()
    }

    @MainActor
    func testLF06SetupConnectionLifecycleAndRetry() {
        for scenario in [
            Scenario.lf06Connecting,
            .lf06ConnectedTarget,
            .lf06Failed,
        ] {
            let app = launch(scenario)
            switch scenario {
            case .lf06Connecting:
                assertValue(
                    "available-selected",
                    for: "course-agent-option-codex",
                    in: app
                )
                assertValue(
                    "connecting",
                    for: "course-agent-connection-lifecycle",
                    in: app
                )
                XCTAssertFalse(element("course-agent-connect", in: app).isEnabled)
            case .lf06ConnectedTarget:
                XCTAssertTrue(element("course-library-root", in: app).exists)
                XCTAssertTrue(element("course-home-app-settings", in: app).exists)
                XCTAssertTrue(element("course-home-agent-settings", in: app).exists)
                let newCourseButton = app.buttons["new-course-button"]
                XCTAssertTrue(newCourseButton.exists)
                XCTAssertTrue(newCourseButton.isEnabled)
                XCTAssertTrue(app.staticTexts["My Courses"].exists)
                XCTAssertTrue(app.staticTexts["Your library is ready"].exists)
            case .lf06Failed:
                assertValue(
                    "available-selected",
                    for: "course-agent-option-codex",
                    in: app
                )
                assertValue(
                    "failed",
                    for: "course-agent-connection-lifecycle",
                    in: app
                )
                XCTAssertTrue(element("course-agent-connection-error", in: app).exists)
                XCTAssertTrue(element("course-agent-connect", in: app).isEnabled)
            default:
                XCTFail("Unexpected LF-06 scenario")
            }
            attachScreenshot(named: "\(scenario.checkpoint) \(scenario.substate)", app: app)
            assertStrictIsolation(in: app)
            app.terminate()
        }

        let retryApp = launch(.lf06Failed)
        element("course-agent-connect", in: retryApp).tap()
        assertValue(
            "connecting",
            for: "course-agent-connection-lifecycle",
            in: retryApp
        )
        assertValue(
            "available-selected",
            for: "course-agent-option-codex",
            in: retryApp
        )
        assertStrictIsolation(in: retryApp)
        assertPersistentMutationsRemainZero(in: retryApp)
        assertStrictIsolation(in: retryApp)
        retryApp.terminate()
    }

    @MainActor
    func testLF27SettingsModelAndSaveStates() {
        let modelStates: [(Scenario, String)] = [
            (.lf27ModelLoading, "model-loading"),
            (.lf27ModelEmpty, "model-empty"),
            (.lf27ModelDefault, "model-default"),
            (.lf27ModelPopulated, "model-populated"),
        ]
        for (scenario, value) in modelStates {
            let app = launch(scenario)
            assertValue(value, for: "course-settings-model-state", in: app)
            switch scenario {
            case .lf27ModelLoading:
                XCTAssertTrue(
                    element("course-settings-model-loading", in: app).exists
                )
                XCTAssertTrue(app.staticTexts["Loading models…"].exists)
                XCTAssertFalse(
                    element("course-settings-model-checkpoint-default", in: app)
                        .exists
                )
            case .lf27ModelEmpty:
                XCTAssertTrue(
                    element("course-settings-model-empty", in: app).exists
                )
                XCTAssertTrue(
                    app.staticTexts[
                        "This agent will choose its default model."
                    ].exists
                )
                XCTAssertFalse(
                    element("course-settings-model-checkpoint-default", in: app)
                        .exists
                )
            case .lf27ModelDefault:
                assertValue(
                    "selected",
                    for: "course-settings-model-checkpoint-default",
                    in: app
                )
                XCTAssertTrue(app.staticTexts["DEFAULT"].exists)
                XCTAssertTrue(
                    element(
                        "course-settings-model-default-badge-checkpoint-default",
                        in: app
                    ).exists
                )
                XCTAssertFalse(
                    element("course-settings-model-checkpoint-fast", in: app)
                        .exists
                )
            case .lf27ModelPopulated:
                assertValue(
                    "selected",
                    for: "course-settings-model-checkpoint-default",
                    in: app
                )
                assertValue(
                    "not-selected",
                    for: "course-settings-model-checkpoint-fast",
                    in: app
                )
                XCTAssertTrue(
                    element("course-settings-model-checkpoint-fast", in: app)
                        .isEnabled
                )
                element("course-settings-model-checkpoint-fast", in: app).tap()
                assertValue(
                    "not-selected",
                    for: "course-settings-model-checkpoint-default",
                    in: app
                )
                assertValue(
                    "selected",
                    for: "course-settings-model-checkpoint-fast",
                    in: app
                )
                assertValue(
                    "low",
                    for: "course-settings-effort",
                    in: app
                )
                assertStrictIsolation(in: app)
                assertPersistentMutationsRemainZero(in: app)
            default:
                XCTFail("Unexpected LF-27 model scenario")
            }
            attachScreenshot(named: "\(scenario.checkpoint) \(scenario.substate)", app: app)
            assertStrictIsolation(in: app)
            app.terminate()
        }

        let checking = launch(.lf27Checking)
        assertValue("checking", for: "course-settings-checkpoint-form", in: checking)
        let checkingSave = checking.buttons["course-settings-save"]
        XCTAssertTrue(checkingSave.exists)
        XCTAssertFalse(checkingSave.isEnabled)
        attachScreenshot(named: "LF-27 checking", app: checking)
        assertStrictIsolation(in: checking)
        checking.terminate()

        let rollback = launch(.lf27FailureRollback)
        assertValue(
            "agent=codex,model=checkpoint-fast,effort=low",
            for: "lf27-divergent-draft",
            in: rollback
        )
        assertValue(
            "selected",
            for: "course-settings-model-checkpoint-fast",
            in: rollback
        )
        assertValue("low", for: "course-settings-effort", in: rollback)
        let rollbackSave = rollback.buttons["course-settings-save"]
        XCTAssertTrue(waitUntilHittable(rollbackSave, timeout: 5))
        rollbackSave.tap()
        XCTAssertTrue(
            element("lf27-failure-rollback", in: rollback)
                .waitForExistence(timeout: 5)
        )
        assertRestoredSettings(in: rollback)
        assertValue(
            "selected",
            for: "course-settings-model-checkpoint-default",
            in: rollback
        )
        assertValue(
            "not-selected",
            for: "course-settings-model-checkpoint-fast",
            in: rollback
        )
        assertStrictIsolation(in: rollback)
        assertPersistentMutationsRemainZero(in: rollback)
        attachScreenshot(named: "LF-27 failure rollback", app: rollback)
        assertStrictIsolation(in: rollback)
        rollback.terminate()

        let error = launch(.lf27AgentError)
        XCTAssertTrue(element("course-settings-agent-error", in: error).exists)
        attachScreenshot(named: "LF-27 agent error", app: error)
        assertStrictIsolation(in: error)
        error.terminate()

        let cancel = launch(.lf27Cancel)
        assertValue(
            "agent=codex,model=checkpoint-fast,effort=low",
            for: "lf27-divergent-draft",
            in: cancel
        )
        assertValue(
            "selected",
            for: "course-settings-model-checkpoint-fast",
            in: cancel
        )
        assertValue("low", for: "course-settings-effort", in: cancel)
        let cancelButton = cancel.buttons["course-settings-cancel"]
        XCTAssertTrue(waitUntilHittable(cancelButton, timeout: 5))
        cancelButton.tap()
        XCTAssertTrue(
            element("lf27-cancel-result", in: cancel)
                .waitForExistence(timeout: 5)
        )
        assertRestoredSettings(in: cancel)
        assertStrictIsolation(in: cancel)
        assertPersistentMutationsRemainZero(in: cancel)
        attachScreenshot(named: "LF-27 cancel unchanged", app: cancel)
        assertStrictIsolation(in: cancel)
        cancel.terminate()
    }

    @MainActor
    func testLF28CloudStatusStatesAndRetry() {
        let cases: [(Scenario, String, String, String, Bool)] = [
            (
                .lf28Synced,
                "synced",
                "Synced",
                "Generated courses and later edits are synced through your private iCloud database.",
                false
            ),
            (
                .lf28OnThisDevice,
                "on-this-device",
                "On This Device",
                "Courses remain on this device because the Learnfold iCloud container is not enabled in this build.",
                false
            ),
            (
                .lf28SignInRequired,
                "sign-in-required",
                "Sign In Required",
                "Sign in to iCloud in Settings to sync generated courses.",
                true
            ),
            (
                .lf28NeedsAttention,
                "needs-attention",
                "Needs Attention",
                "Course sync paused without changing local data. The iCloud account needs attention. Local courses remain available.",
                true
            ),
            (
                .lf28Retry,
                "retry",
                "Retrying…",
                "Course sync paused without changing local data. The iCloud account needs attention. Local courses remain available.",
                false
            ),
        ]
        for (scenario, value, label, explanation, expectsRetry) in cases {
            let app = launch(scenario)
            assertValue(value, for: "course-cloud-sync-status", in: app)
            XCTAssertTrue(app.staticTexts[label].exists, label)
            XCTAssertTrue(app.staticTexts[explanation].exists, explanation)
            XCTAssertEqual(
                element("course-cloud-sync-retry", in: app).exists,
                expectsRetry
            )
            if scenario == .lf28Retry {
                XCTAssertTrue(element("course-cloud-sync-retrying", in: app).exists)
            }
            attachScreenshot(named: "\(scenario.checkpoint) \(scenario.substate)", app: app)
            assertStrictIsolation(in: app)
            app.terminate()
        }

        let retry = launch(.lf28NeedsAttention)
        element("course-cloud-sync-retry", in: retry).tap()
        assertValue("retry", for: "course-cloud-sync-status", in: retry)
        XCTAssertTrue(element("course-cloud-sync-retrying", in: retry).exists)
        XCTAssertFalse(element("course-cloud-sync-retry", in: retry).exists)
        assertStrictIsolation(in: retry)
        assertPersistentMutationsRemainZero(in: retry)
        assertStrictIsolation(in: retry)
        retry.terminate()
    }

    @MainActor
    func testLF30SourceMenuPreparingPassageAndErrors() {
        let sourceMenu = launch(.lf30SourceMenu)
        element("course-chat-add-source", in: sourceMenu).tap()
        XCTAssertTrue(sourceMenu.buttons["Photo"].waitForExistence(timeout: 5))
        XCTAssertTrue(sourceMenu.buttons["File"].exists)
        XCTAssertTrue(sourceMenu.buttons["Paste Link"].exists)
        assertStrictIsolation(in: sourceMenu)
        attachScreenshot(named: "LF-30 source menu", app: sourceMenu)
        assertStrictIsolation(in: sourceMenu)
        sourceMenu.terminate()

        let preparing = launch(.lf30Preparing)
        XCTAssertTrue(element("course-chat-source-preparing", in: preparing).exists)
        XCTAssertFalse(element("course-chat-add-source", in: preparing).isEnabled)
        XCTAssertFalse(element("course-chat-composer", in: preparing).isEnabled)
        XCTAssertFalse(element("course-chat-send", in: preparing).isEnabled)
        assertValue("sources=0", for: "lf30-source-count", in: preparing)
        attachScreenshot(named: "LF-30 preparing", app: preparing)
        assertStrictIsolation(in: preparing)
        preparing.terminate()

        let passage = launch(.lf30PassageContext)
        XCTAssertTrue(element("lf30-passage-context", in: passage).exists)
        XCTAssertTrue(passage.staticTexts["Selected from Weather Systems"].exists)
        attachScreenshot(named: "LF-30 passage context", app: passage)
        assertStrictIsolation(in: passage)
        passage.terminate()

        let errorCases: [(Scenario, String)] = [
            (
                .lf30PermissionError,
                "Learnfold couldn’t access that source. Choose it again and allow access."
            ),
            (
                .lf30ParseError,
                "That source could not be parsed. Choose a supported file or a valid http or https link."
            ),
            (
                .lf30PreparationError,
                "The selected source could not be prepared. Nothing was added; try again."
            ),
        ]
        for (scenario, message) in errorCases {
            let app = launch(scenario)
            let alert = app.alerts["Couldn’t Add Source"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            XCTAssertTrue(alert.staticTexts[message].exists)
            attachScreenshot(named: "\(scenario.checkpoint) \(scenario.substate)", app: app)
            alert.buttons["OK"].tap()
            XCTAssertTrue(element("lf30-error-recovery-note", in: app).exists)
            XCTAssertTrue(element("course-chat-composer", in: app).isEnabled)
            assertValue("sources=0", for: "lf30-source-count", in: app)
            assertStrictIsolation(in: app)
            assertPersistentMutationsRemainZero(in: app)
            assertStrictIsolation(in: app)
            app.terminate()
        }
    }

    @MainActor
    private func launch(_ scenario: Scenario) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments = [
            "--ui-test-provider-settings-source-checkpoint",
            scenario.rawValue,
        ]
        app.launch()

        let root = element("providerSettingsSourceCheckpoint.root", in: app)
        XCTAssertTrue(
            root.waitForExistence(timeout: 10),
            "Provider/settings/source checkpoint root did not render"
        )
        let route = element(
            "providerSettingsSourceCheckpoint.route",
            in: app
        )
        let state = element(
            "providerSettingsSourceCheckpoint.state",
            in: app
        )
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertEqual(
            route.value as? String,
            "--ui-test-provider-settings-source-checkpoint"
        )
        XCTAssertEqual(
            state.value as? String,
            scenario.rawValue
        )
        XCTAssertEqual(route.label, "Route · \(scenario.checkpoint)")
        XCTAssertEqual(state.label, "State · \(scenario.substate)")
        XCTAssertEqual(
            element(
                "providerSettingsSourceCheckpoint.nonLiveBoundary",
                in: app
            ).label,
            scenario.boundary
        )
        assertStrictIsolation(in: app)
        assertPersistentMutationsRemainZero(in: app)
        return app
    }

    @MainActor
    private func assertStrictIsolation(in app: XCUIApplication) {
        let root = element(
            "providerSettingsSourceCheckpoint.strictRoot",
            in: app
        )
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        let initialCounter = element(
            "providerSettingsSourceCheckpoint.forbiddenSideEffects",
            in: app
        )
        XCTAssertTrue(initialCounter.waitForExistence(timeout: 10))

        // Cross a TimelineView refresh tick, then reacquire the element so this
        // assertion samples the live post-action sentinel rather than launch state.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let liveCounter = element(
            "providerSettingsSourceCheckpoint.forbiddenSideEffects",
            in: app
        )
        let zero = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@ AND value == %@",
                "Forbidden production entry events · 0",
                "0"
            ),
            object: liveCounter
        )
        let details = element(
            "providerSettingsSourceCheckpoint.forbiddenSideEffectDetails",
            in: app
        )
        let failure = "Strict provider root reached forbidden production entries: \(details.exists ? details.label : "none")"
        XCTAssertEqual(
            XCTWaiter.wait(for: [zero], timeout: 5),
            .completed,
            failure
        )
        XCTAssertEqual(
            liveCounter.label,
            "Forbidden production entry events · 0",
            failure
        )
        XCTAssertEqual(
            liveCounter.value as? String,
            "0",
            failure
        )
    }

    @MainActor
    private func assertPersistentMutationsRemainZero(in app: XCUIApplication) {
        let marker = element(
            "providerSettingsSourceCheckpoint.persistentMutations",
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
    private func assertRestoredSettings(in app: XCUIApplication) {
        assertValue("codex", for: "lf27-restored-agent", in: app)
        assertValue(
            "checkpoint-default",
            for: "lf27-restored-model",
            in: app
        )
        assertValue("medium", for: "lf27-restored-effort", in: app)
    }

    @MainActor
    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func scrollFormUntilUniqueHittableMarker(
        _ identifier: String,
        in app: XCUIApplication,
        attempts: Int = 8
    ) -> XCUIElement? {
        let forms = app.collectionViews
        XCTAssertEqual(
            forms.count,
            1,
            "Expected exactly one Form collection view; found \(forms.count)."
        )
        guard forms.count == 1 else { return nil }

        let form = forms.element(boundBy: 0)
        XCTAssertTrue(
            form.exists && !form.frame.isEmpty,
            "The unique Form collection view must exist with a nonempty frame; frame=\(form.frame)."
        )
        guard form.exists, !form.frame.isEmpty else { return nil }

        let anchors = app.textFields.matching(
            identifier: "custom-provider-base-url"
        )
        XCTAssertEqual(
            anchors.count,
            1,
            "Expected exactly one typed custom-provider-base-url text field; found \(anchors.count)."
        )
        guard anchors.count == 1 else { return nil }

        let anchor = anchors.element(boundBy: 0)
        let anchorIsUsable = anchor.exists
            && anchor.isHittable
            && !anchor.frame.isEmpty
            && form.frame.intersects(anchor.frame)
        XCTAssertTrue(
            anchorIsUsable,
            "The base URL anchor must exist, be hittable, have a nonempty frame, and intersect the Form; anchor=\(anchor.frame), form=\(form.frame)."
        )
        guard anchorIsUsable else { return nil }

        for attempt in 0...attempts {
            let matches = app.descendants(matching: .any)
                .matching(identifier: identifier)
            let candidates = (0..<matches.count).map { matches.element(boundBy: $0) }

            if candidates.count > 1 {
                XCTFail(formMarkerDiagnostics(
                    identifier: identifier,
                    candidates: candidates,
                    form: form,
                    anchor: anchor,
                    app: app
                ))
                return nil
            }
            if let candidate = candidates.first,
               candidate.exists,
               candidate.isHittable {
                return candidate
            }
            if attempt < attempts {
                form.swipeUp()
            }
        }

        let finalMatches = app.descendants(matching: .any)
            .matching(identifier: identifier)
        let finalCandidates = (0..<finalMatches.count).map {
            finalMatches.element(boundBy: $0)
        }
        XCTFail(formMarkerDiagnostics(
            identifier: identifier,
            candidates: finalCandidates,
            form: form,
            anchor: anchor,
            app: app
        ))
        return nil
    }

    @MainActor
    private func formMarkerDiagnostics(
        identifier: String,
        candidates: [XCUIElement],
        form: XCUIElement,
        anchor: XCUIElement,
        app: XCUIApplication
    ) -> String {
        let candidateFrames = candidates.enumerated().map { index, candidate in
            "candidate[\(index)]: exists=\(candidate.exists), "
                + "hittable=\(candidate.isHittable), frame=\(candidate.frame)"
        }.joined(separator: "\n")
        return """
        Expected one unique hittable Form marker for \(identifier); \
        found \(candidates.count) matches, \
        \(candidates.filter { $0.exists && $0.isHittable }.count) hittable.
        Form frame: \(form.frame)
        Anchor: exists=\(anchor.exists), hittable=\(anchor.isHittable), frame=\(anchor.frame)
        Candidate frames:
        \(candidateFrames.isEmpty ? "none" : candidateFrames)
        Accessibility tree:
        \(app.debugDescription)
        """
    }

    @MainActor
    private func waitUntilHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func assertValue(
        _ expected: String,
        for identifier: String,
        in app: XCUIApplication
    ) {
        let target = element(identifier, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5), identifier)
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
            "\(identifier) never reached value \(expected); current value: \(String(describing: target.value))"
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
