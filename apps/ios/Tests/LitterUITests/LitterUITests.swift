import XCTest

final class LitterUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGuestHostedSetupContinuesWithoutLoginAndOffersChangeAgent() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_RESET_ONBOARDING"] = "1"
        app.launchEnvironment["LEARNFOLD_HOSTED_ACCESS_TOKEN"] = ""
        app.launch()
        continuePastIntroIfNeeded(in: app)
        XCTAssertTrue(app.staticTexts["Ready to start learning"].waitForExistence(timeout: 10))
        let hosted = identifiedElement("course-agent-option-hosted", in: app)
        XCTAssertEqual(hosted.value as? String, "available-selected")
        XCTAssertFalse(identifiedElement("course-agent-option-codex", in: app).exists)
        let changeAgent = app.buttons["course-agent-change"]
        XCTAssertTrue(waitUntilHittable(changeAgent, timeout: 5))
        attachScreenshot(named: "Hosted guest default without login", app: app)
        changeAgent.tap()
        XCTAssertTrue(identifiedElement("course-agent-option-codex", in: app).exists)
        let connect = identifiedElement("course-agent-connect", in: app)
        XCTAssertTrue(scrollUntilHittable(connect, in: app))
        XCTAssertEqual(connect.label, "Continue")
        connect.tap()
        XCTAssertTrue(app.staticTexts["My Courses"].waitForExistence(timeout: 8))
        attachScreenshot(named: "Hosted guest course library", app: app)
    }

    @MainActor
    func testFirstLaunchIntroContinuesToCourseAgentSetup() throws {
        let app = appleCourseSetupApp(onDeviceAvailable: true, privateCloudAvailable: true)
        app.launch()

        XCTAssertTrue(
            app.staticTexts["learnfold-intro-title"].waitForExistence(timeout: 15)
        )
        XCTAssertTrue(app.staticTexts["Start with anything"].exists)

        let continueButton = app.buttons["learnfold-intro-continue"]
        XCTAssertTrue(
            waitUntilHittable(continueButton, timeout: 10),
            "Intro CTA remained covered or outside the tappable viewport"
        )
        attachScreenshot(named: "Learnfold first launch intro", app: app)
        continueButton.tap()

        XCTAssertTrue(app.staticTexts["Choose your course agent"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["learnfold-intro-title"].exists)
        attachScreenshot(named: "Learnfold course agent setup after intro", app: app)
    }

    @MainActor
    func testCourseAgentSetupDefaultsToPrivateCloudAndKeepsAppleThreadInAppleFamily() throws {
        let app = appleCourseSetupApp(onDeviceAvailable: true, privateCloudAvailable: true)
        app.launch()

        continuePastIntroIfNeeded(in: app)
        XCTAssertTrue(
            app.staticTexts["Choose your course agent"].waitForExistence(timeout: 15)
        )
        let privateCloud = identifiedElement(
            "course-agent-option-apple-private-cloud",
            in: app
        )
        XCTAssertTrue(privateCloud.exists)
        XCTAssertTrue(privateCloud.isEnabled)
        XCTAssertEqual(privateCloud.value as? String, "available-selected")

        let connect = identifiedElement("course-agent-connect", in: app)
        XCTAssertTrue(scrollUntilHittable(connect, in: app))
        XCTAssertEqual(connect.label, "Connect Apple Private Cloud")
        connect.tap()

        XCTAssertTrue(app.staticTexts["My Courses"].waitForExistence(timeout: 8))
        let newCourse = identifiedElement("new-course-button", in: app)
        XCTAssertTrue(newCourse.waitForExistence(timeout: 5))
        newCourse.tap()

        XCTAssertTrue(
            app.staticTexts
                .matching(
                    NSPredicate(
                        format: "label CONTAINS %@",
                        "Your Apple course agent can answer questions"
                    )
                )
                .firstMatch
                .waitForExistence(timeout: 8)
        )
        let providerSwitch = identifiedElement("course-chat-apple-provider-switch", in: app)
        XCTAssertTrue(providerSwitch.waitForExistence(timeout: 5))
        // SwiftUI combines the model menu and adjacent status icon into one
        // toolbar accessibility container. Target the menu side of that
        // container, whose own identifier remains stable.
        providerSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        let privateCloudAction = elementLabeled("Private Cloud Compute", in: app)
        let onDeviceAction = elementLabeled("On‑Device", in: app)
        XCTAssertTrue(privateCloudAction.waitForExistence(timeout: 3))
        XCTAssertTrue(onDeviceAction.exists)
        XCTAssertFalse(elementLabeled("Codex", in: app).exists)
        onDeviceAction.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Apple On-Device connected"))
                .firstMatch
                .waitForExistence(timeout: 5)
        )

        let sourceMenu = identifiedElement("course-chat-add-source", in: app)
        XCTAssertTrue(sourceMenu.waitForExistence(timeout: 3))
        sourceMenu.tap()
        XCTAssertTrue(app.buttons["Paste Link"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Photo"].exists)
        XCTAssertFalse(app.buttons["File"].exists)
        attachScreenshot(named: "Apple course switched to on-device with link-only sources", app: app)
    }

    @MainActor
    func testCourseAgentSettingsCanDraftCodexWithoutLaunchingOAuth() throws {
        let app = appleCourseSetupApp(onDeviceAvailable: true, privateCloudAvailable: true)
        app.launch()

        continuePastIntroIfNeeded(in: app)
        XCTAssertTrue(
            app.staticTexts["Choose your course agent"].waitForExistence(timeout: 15)
        )
        let connect = identifiedElement("course-agent-connect", in: app)
        XCTAssertTrue(scrollUntilHittable(connect, in: app))
        XCTAssertEqual(connect.label, "Connect Apple Private Cloud")
        connect.tap()

        XCTAssertTrue(app.staticTexts["My Courses"].waitForExistence(timeout: 8))
        let courseAgentMenu = app.buttons["Course agent menu"]
        XCTAssertTrue(waitUntilHittable(courseAgentMenu, timeout: 5))
        courseAgentMenu.tap()

        XCTAssertTrue(app.navigationBars["Course Settings"].waitForExistence(timeout: 5))
        let codex = identifiedElement("course-settings-agent-codex", in: app)
        XCTAssertTrue(scrollUntilHittable(codex, in: app))
        codex.tap()

        let addCustomProvider = app.buttons["Add custom provider"]
        XCTAssertTrue(
            scrollUntilHittable(addCustomProvider, in: app),
            "Selecting Codex should update the local draft without launching OAuth"
        )
        addCustomProvider.tap()
        XCTAssertTrue(app.navigationBars["Custom Provider"].waitForExistence(timeout: 5))
        let formMarker = identifiedElement("custom-provider-form", in: app)
        XCTAssertTrue(formMarker.waitForExistence(timeout: 5))
        XCTAssertEqual(formMarker.elementType, .staticText)
        XCTAssertEqual(formMarker.label, "Connection")
        XCTAssertEqual(formMarker.value as? String, "ready")
        attachScreenshot(named: "Codex custom provider draft before Save", app: app)
    }

    @MainActor
    func testCourseAgentSetupFallsBackToCodexWhenAppleModelsAreUnavailable() throws {
        let app = appleCourseSetupApp(onDeviceAvailable: false, privateCloudAvailable: false)
        app.launch()

        continuePastIntroIfNeeded(in: app)
        XCTAssertTrue(
            app.staticTexts["Choose your course agent"].waitForExistence(timeout: 15)
        )
        let privateCloud = identifiedElement(
            "course-agent-option-apple-private-cloud",
            in: app
        )
        let onDevice = identifiedElement(
            "course-agent-option-apple-on-device",
            in: app
        )
        let codex = identifiedElement(
            "course-agent-option-codex",
            in: app
        )
        XCTAssertTrue(privateCloud.exists)
        XCTAssertFalse(privateCloud.isEnabled)
        XCTAssertEqual(
            privateCloud.value as? String,
            "unavailable"
        )
        XCTAssertTrue(onDevice.exists)
        XCTAssertFalse(onDevice.isEnabled)
        XCTAssertEqual(
            onDevice.value as? String,
            "unavailable"
        )
        XCTAssertTrue(codex.isEnabled)
        XCTAssertEqual(codex.value as? String, "available-selected")

        let connect = identifiedElement("course-agent-connect", in: app)
        XCTAssertTrue(scrollUntilHittable(connect, in: app))
        XCTAssertEqual(connect.label, "Connect Codex")
        attachScreenshot(named: "Codex fallback with unavailable Apple explanations", app: app)
    }

    @MainActor
    func testCourseChatPartialRemoteSnapshotKeepsCompleteLocalTranscript() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments.append("--ui-test-course-chat-continuity")
        app.launch()

        let harnessTitle = app.staticTexts["courseChatContinuityHarness.title"]
        XCTAssertTrue(
            harnessTitle.waitForExistence(timeout: 10),
            "Course chat continuity harness did not launch"
        )
        let splashDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: harnessTitle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [splashDismissed], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["UITEST_COURSE_FIRST_QUESTION"].exists)
        XCTAssertTrue(app.staticTexts["UITEST_COURSE_FIRST_ANSWER"].exists)
        XCTAssertTrue(app.staticTexts["UITEST_COURSE_LATEST_QUESTION"].exists)
        XCTAssertEqual(
            app.staticTexts.matching(
                NSPredicate(format: "label == %@", "UITEST_COURSE_LATEST_QUESTION")
            ).count,
            1
        )
        attachScreenshot(named: "Course chat partial snapshot continuity", app: app)
    }

    @MainActor
    func testCourseDraftRecoveryShowsFullPlanAndRestoredComposer() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments.append("--ui-test-course-draft-recovery")
        app.launch()

        let status = app.staticTexts["courseDraftRecoveryHarness.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Plan ready for review · Revision 1 · Not approved")
        let initialRetryResult = identifiedElement(
            "courseDraftRecoveryHarness.retryResult",
            in: app
        )
        XCTAssertTrue(initialRetryResult.exists)
        XCTAssertEqual(initialRetryResult.label, "Retry has not been requested.")

        let composer = identifiedElement("course-chat-composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(
            composer.value as? String,
            "Please make the laboratory simulations runnable on my Mac."
        )
        XCTAssertTrue(app.staticTexts["longevity-research-notes.pdf"].exists)
        attachScreenshot(named: "Course draft restored composer and plan", app: app)

        let recursiveExplainer = identifiedElement(
            "course-plan-node-ageing-concept-map",
            in: app
        )
        XCTAssertTrue(scrollUntilHittable(recursiveExplainer, in: app, attempts: 10))
        XCTAssertEqual(
            recursiveExplainer.label,
            "1.1.2, Explainer, Cellular ageing concept map"
        )
        let recursiveModule = identifiedElement(
            "course-plan-node-simulation-project",
            in: app
        )
        XCTAssertTrue(scrollUntilHittable(recursiveModule, in: app, attempts: 10))
        XCTAssertEqual(
            recursiveModule.label,
            "2.1, Module, Runnable simulation project"
        )
        attachScreenshot(named: "Course draft recursive hierarchy and roles", app: app)

        let tryAgain = app.buttons["Try Again"]
        XCTAssertTrue(scrollUntilHittable(tryAgain, in: app, attempts: 10))
        let sourceDismiss = identifiedElement("xmark.circle.fill", in: app)
        XCTAssertTrue(sourceDismiss.exists)
        for _ in 0..<4 where tryAgain.frame.maxY >= sourceDismiss.frame.minY {
            app.swipeUp()
        }
        XCTAssertLessThan(
            tryAgain.frame.maxY,
            sourceDismiss.frame.minY,
            "Try Again remained covered by the restored-source tray"
        )
        XCTAssertTrue(
            identifiedElement("course-recovered-draft-provenance", in: app).exists
        )
        XCTAssertTrue(app.buttons["Discard Draft"].exists)
        XCTAssertTrue(app.staticTexts["Final research protocol with analysis plan"].exists)
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", "Message not sent"))
                .firstMatch
                .exists
        )
        tryAgain.tap()
        let expectedRetryResult = "Retry requested with restored message and 1 source."
        let updatedRetryResult = app.staticTexts[expectedRetryResult]
        XCTAssertTrue(
            updatedRetryResult.waitForExistence(timeout: 2),
            "Try Again did not expose a visible retry result"
        )
        XCTAssertTrue(updatedRetryResult.isHittable)
        attachScreenshot(named: "Course draft full plan and retry recovery", app: app)
    }

    @MainActor
    func testCourseGenerationControlMaintains44PointHitTargetAtDefaultAndAX3XL() {
        let requiredHitTarget = 44.0
        let hitTargetMeasurementEpsilon = 0.000001
        let variants = [
            (name: "Default", argument: "--ui-test-dynamic-type-default"),
            (name: "AX3XL", argument: "--ui-test-dynamic-type-ax3xl"),
        ]

        for variant in variants {
            let app = XCUIApplication()
            app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
            app.launchArguments.append("--ui-test-course-generation-control")
            app.launchArguments.append(variant.argument)
            app.launch()

            let title = app.staticTexts["courseGenerationControlHarness.title"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            let expectedControls = [
                (
                    identifier: "generate-course-node-ui-generation-folder",
                    label: "Generate next in Chapter Cellular ageing: Explainer Cellular ageing concept map"
                ),
                (
                    identifier: "generate-course-node-ui-generation-section",
                    label: "Generate next in Subchapter Cell repair mechanisms: Explainer Cellular ageing concept map"
                ),
                (
                    identifier: "generate-course-node-ui-generation-leaf",
                    label: "Generate Explainer Cellular ageing concept map"
                ),
            ]
            var controls: [XCUIElement] = []
            for expected in expectedControls {
                let generate = identifiedElement(expected.identifier, in: app)
                XCTAssertTrue(
                    waitUntilHittable(generate, timeout: 5),
                    "\(variant.name) \(expected.identifier) must be actionable"
                )
                XCTAssertEqual(generate.label, expected.label)
                XCTAssertGreaterThanOrEqual(
                    generate.frame.width + hitTargetMeasurementEpsilon,
                    requiredHitTarget,
                    "\(variant.name) Generate control must remain at least 44 points wide"
                )
                XCTAssertGreaterThanOrEqual(
                    generate.frame.height + hitTargetMeasurementEpsilon,
                    requiredHitTarget,
                    "\(variant.name) Generate control must remain at least 44 points tall"
                )
                controls.append(generate)
            }
            XCTAssertEqual(Set(controls.map(\.identifier)).count, expectedControls.count)
            XCTAssertEqual(Set(controls.map(\.label)).count, expectedControls.count)

            let expectedLearningRows = [
                (
                    identifier: "course-learning-node-ui-generation-folder",
                    label: "1, Chapter, Cellular ageing, Pending generation"
                ),
                (
                    identifier: "course-learning-node-ui-generation-section",
                    label: "1.1, Subchapter, Cell repair mechanisms, Pending generation"
                ),
                (
                    identifier: "course-learning-node-ui-generation-leaf",
                    label: "1.1.1, Explainer, Cellular ageing concept map, Pending generation"
                ),
            ]
            var learningRows: [XCUIElement] = []
            for expected in expectedLearningRows {
                let row = identifiedElement(expected.identifier, in: app)
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                XCTAssertEqual(row.label, expected.label)
                learningRows.append(row)
            }
            XCTAssertEqual(
                Set(learningRows.map(\.identifier)).count,
                expectedLearningRows.count
            )
            XCTAssertEqual(Set(learningRows.map(\.label)).count, expectedLearningRows.count)

            controls[0].tap()
            let requestedNode = identifiedElement(
                "courseGenerationControlHarness.lastRequestedNodeID",
                in: app
            )
            XCTAssertTrue(
                waitUntil(timeout: 2) {
                    requestedNode.label == "ui-generation-folder"
                },
                "\(variant.name) ancestor Generate next action did not reach its source node"
            )

            let rootPageRow = identifiedElement(
                "course-page-row-ui-generation-folder",
                in: app
            )
            XCTAssertTrue(scrollUntilHittable(rootPageRow, in: app, attempts: 8))
            XCTAssertEqual(
                rootPageRow.label,
                "1, Chapter, Cellular ageing, Pending generation"
            )
            let rootDisclosure = identifiedElement(
                "course-page-expand-ui-generation-folder",
                in: app
            )
            XCTAssertTrue(scrollUntilHittable(rootDisclosure, in: app, attempts: 8))
            XCTAssertEqual(
                rootDisclosure.label,
                "Collapse 1, Chapter, Cellular ageing"
            )
            XCTAssertGreaterThanOrEqual(
                rootDisclosure.frame.width + hitTargetMeasurementEpsilon,
                requiredHitTarget,
                "\(variant.name) root disclosure must remain at least 44 points wide"
            )
            XCTAssertGreaterThanOrEqual(
                rootDisclosure.frame.height + hitTargetMeasurementEpsilon,
                requiredHitTarget,
                "\(variant.name) root disclosure must remain at least 44 points tall"
            )

            let sectionPageRow = identifiedElement(
                "course-page-row-ui-generation-section",
                in: app
            )
            XCTAssertTrue(scrollUntilHittable(sectionPageRow, in: app, attempts: 4))
            XCTAssertEqual(
                sectionPageRow.label,
                "1.1, Subchapter, Cell repair mechanisms, Pending generation"
            )
            let sectionDisclosure = identifiedElement(
                "course-page-expand-ui-generation-section",
                in: app
            )
            XCTAssertTrue(scrollUntilHittable(sectionDisclosure, in: app, attempts: 4))
            XCTAssertEqual(
                sectionDisclosure.label,
                "Expand 1.1, Subchapter, Cell repair mechanisms"
            )
            XCTAssertGreaterThanOrEqual(
                sectionDisclosure.frame.width + hitTargetMeasurementEpsilon,
                requiredHitTarget,
                "\(variant.name) section disclosure must remain at least 44 points wide"
            )
            XCTAssertGreaterThanOrEqual(
                sectionDisclosure.frame.height + hitTargetMeasurementEpsilon,
                requiredHitTarget,
                "\(variant.name) section disclosure must remain at least 44 points tall"
            )

            sectionDisclosure.tap()
            let leafPageRow = identifiedElement(
                "course-page-row-ui-generation-leaf",
                in: app
            )
            XCTAssertTrue(scrollUntilHittable(leafPageRow, in: app, attempts: 4))
            XCTAssertEqual(
                leafPageRow.label,
                "1.1.1, Explainer, Cellular ageing concept map, Pending generation"
            )
            let pageRows = [rootPageRow, sectionPageRow, leafPageRow]
            XCTAssertEqual(Set(pageRows.map(\.identifier)).count, pageRows.count)
            XCTAssertEqual(Set(pageRows.map(\.label)).count, pageRows.count)

            leafPageRow.tap()
            let openedPage = identifiedElement(
                "courseGenerationControlHarness.lastOpenedPageID",
                in: app
            )
            XCTAssertTrue(
                waitUntil(timeout: 2) {
                    openedPage.label == "ui-generation-leaf-page"
                },
                "\(variant.name) page row action did not open its unique page"
            )
            attachScreenshot(
                named: "Course generation control \(variant.name)",
                app: app
            )
            app.terminate()
        }
    }

    @MainActor
    func testCourseGenerationControlDisablesEveryUnresolvedAcceptedRecoveryState() {
        let cases = [
            (
                argument: "--ui-test-generation-recovery-acceptance-unknown",
                state: "acceptanceUnknown"
            ),
            (
                argument: "--ui-test-generation-recovery-accepted-reply-incomplete",
                state: "acceptedReplyIncomplete"
            ),
        ]

        for recoveryCase in cases {
            let app = XCUIApplication()
            app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
            app.launchArguments.append("--ui-test-course-generation-control")
            app.launchArguments.append(recoveryCase.argument)
            app.launch()

            XCTAssertTrue(
                app.staticTexts["courseGenerationControlHarness.title"]
                    .waitForExistence(timeout: 10)
            )
            let state = identifiedElement(
                "courseGenerationControlHarness.submissionRecoveryState",
                in: app
            )
            XCTAssertTrue(state.waitForExistence(timeout: 5))
            XCTAssertEqual(state.label, recoveryCase.state)

            let generate = identifiedElement(
                "generate-course-node-ui-generation-folder",
                in: app
            )
            XCTAssertTrue(generate.waitForExistence(timeout: 5))
            XCTAssertFalse(
                generate.isEnabled,
                "\(recoveryCase.state) must disable the visible Generate control"
            )
            XCTAssertEqual(
                identifiedElement(
                    "courseGenerationControlHarness.lastRequestedNodeID",
                    in: app
                ).label,
                "none"
            )
            attachScreenshot(
                named: "Course generation blocked \(recoveryCase.state)",
                app: app
            )
            app.terminate()
        }
    }

    @MainActor
    func testCourseStructureAndSamePageEditorRetryReloadVisibleContent() {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments.append("--ui-test-course-retry")
        app.launch()

        XCTAssertTrue(
            app.staticTexts["courseRetryHarness.title"].waitForExistence(timeout: 10)
        )

        let structureRetry = identifiedElement("course-structure-retry", in: app)
        XCTAssertTrue(waitUntilHittable(structureRetry, timeout: 5))
        XCTAssertEqual(
            identifiedElement("course-structure-error-message", in: app).label,
            "Source files: Simulated source-file failure\nCourse pages: Simulated course-page failure"
        )
        XCTAssertEqual(
            identifiedElement("courseRetryHarness.workspaceAttempts", in: app).label,
            "1"
        )
        XCTAssertEqual(
            identifiedElement("courseRetryHarness.documentAttempts", in: app).label,
            "1"
        )
        structureRetry.tap()

        let workspaceStatus = identifiedElement("courseRetryHarness.workspaceStatus", in: app)
        let documentStatus = identifiedElement("courseRetryHarness.documentStatus", in: app)
        XCTAssertTrue(workspaceStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(documentStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(workspaceStatus.label, "Source files ready")
        XCTAssertEqual(documentStatus.label, "Course pages ready")
        XCTAssertEqual(
            identifiedElement("courseRetryHarness.workspaceAttempts", in: app).label,
            "2"
        )
        XCTAssertEqual(
            identifiedElement("courseRetryHarness.documentAttempts", in: app).label,
            "2"
        )

        let editorRetry = identifiedElement("course-page-retry-retry-page", in: app)
        XCTAssertTrue(scrollUntilHittable(editorRetry, in: app, attempts: 6))
        XCTAssertEqual(
            identifiedElement("courseRetryHarness.editorAttempts", in: app).label,
            "1"
        )
        editorRetry.tap()

        let freshContent = identifiedElement("courseRetryHarness.editorContent", in: app)
        XCTAssertTrue(freshContent.waitForExistence(timeout: 5))
        XCTAssertEqual(freshContent.label, "Fresh same-page content")
        XCTAssertEqual(
            identifiedElement("courseRetryHarness.editorAttempts", in: app).label,
            "2"
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                identifiedElement(
                    "courseRetryHarness.staleCompletionRejected",
                    in: app
                ).label == "yes"
            },
            "The late completion from the first same-page load was not rejected."
        )
        XCTAssertFalse(app.staticTexts["Stale same-page content"].exists)
    }

    @MainActor
    func testCoursePageSaveFailureRetryKeepsDraftAndReportsSaved() {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments.append("--ui-test-course-save-recovery")
        app.launch()

        let failedStatus = identifiedElement("course-page-save-status", in: app)
        XCTAssertTrue(
            failedStatus.waitForExistence(timeout: 15),
            "The deterministic failed-save state did not appear."
        )
        XCTAssertEqual(failedStatus.label, "Changes not saved")

        let pageTitle = app.staticTexts["Save recovery evidence"]
        XCTAssertTrue(pageTitle.exists)
        XCTAssertFalse(app.staticTexts["Editable course page"].exists)
        let editToggle = app.buttons["course-page-edit-toggle"]
        XCTAssertTrue(waitUntilHittable(editToggle, timeout: 8))
        XCTAssertEqual(editToggle.label, "Edit page")
        XCTAssertFalse(identifiedElement("native-editor-add-block", in: app).exists)
        XCTAssertFalse(identifiedElement("native-editor-document-actions", in: app).exists)
        attachScreenshot(named: "Course page reading mode", app: app)
        editToggle.tap()
        XCTAssertTrue(
            identifiedElement("native-editor-document-actions", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(editToggle.label, "Finish editing")
        XCTAssertTrue(identifiedElement("native-editor-continue-writing", in: app).exists)
        XCTAssertFalse(identifiedElement("native-editor-add-block", in: app).exists)
        editToggle.tap()
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                !identifiedElement("native-editor-document-actions", in: app).exists
            }
        )
        XCTAssertEqual(editToggle.label, "Edit page")
        XCTAssertTrue(
            elementContainingText("First pending recovery edit", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            elementContainingText("Second pending recovery edit", in: app)
                .waitForExistence(timeout: 5)
        )

        let failureMessage = identifiedElement("course-page-save-error", in: app)
        XCTAssertTrue(failureMessage.exists)
        XCTAssertFalse(failureMessage.label.isEmpty)
        let retry = identifiedElement("course-page-save-retry", in: app)
        XCTAssertTrue(waitUntilHittable(retry, timeout: 5))
        XCTAssertEqual(retry.label, "Retry save")
        XCTAssertLessThanOrEqual(
            retry.frame.maxY,
            pageTitle.frame.minY,
            "The failed-save recovery card must participate in layout above the editor title."
        )
        attachScreenshot(named: "LF-50 failed save preserves editable draft", app: app)
        attachHierarchy(named: "LF-50 failed save hierarchy", app: app)

        retry.tap()

        let savingStatus = identifiedElement("course-page-save-status", in: app)
        let observedSaving = waitUntil(timeout: 0.75, poll: 0.02) {
            savingStatus.label == "Saving changes…"
                || savingStatus.value as? String == "Saving changes"
        }
        if observedSaving {
            attachScreenshot(named: "LF-50 retry saving", app: app)
            attachHierarchy(named: "LF-50 retry saving hierarchy", app: app)
        }
        let savingObservation = XCTAttachment(
            string: observedSaving
                ? "The transient Saving changes state was observed."
                : "The retry completed before XCUITest could sample the transient Saving changes state."
        )
        savingObservation.name = "LF-50 Saving observation"
        savingObservation.lifetime = .keepAlways
        add(savingObservation)

        XCTAssertTrue(
            waitUntil(timeout: 8) {
                let status = identifiedElement("course-page-save-status", in: app)
                return status.value as? String == "Changes saved"
            },
            "Retry did not reach the visible saved state."
        )
        XCTAssertFalse(identifiedElement("course-page-save-retry", in: app).exists)
        let savedStatus = identifiedElement("course-page-save-status", in: app)
        XCTAssertTrue(savedStatus.exists)
        XCTAssertLessThanOrEqual(
            savedStatus.frame.maxY,
            pageTitle.frame.minY,
            "The saved-status row must participate in layout above the editor title."
        )
        XCTAssertTrue(elementContainingText("First pending recovery edit", in: app).exists)
        XCTAssertTrue(elementContainingText("Second pending recovery edit", in: app).exists)
        attachScreenshot(named: "LF-50 retry saved exact pending draft", app: app)
        attachHierarchy(named: "LF-50 retry saved hierarchy", app: app)
    }

    @MainActor
    func testConversationDisplaySettingsRowsAreReachable() throws {
        let app = conversationDisplayHarnessApp()
        app.launch()

        XCTAssertTrue(
            app.staticTexts["conversationDisplayHarness.title"].waitForExistence(timeout: 10),
            "Conversation display harness did not launch"
        )

        let settingsButton = app.buttons["conversationDisplayHarness.settingsButton"]
        XCTAssertTrue(
            waitUntilHittable(settingsButton, timeout: 8),
            "Settings button remained covered or outside the tappable viewport"
        )
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let notifications = identifiedElement("settings.notifications.row", in: app)
        XCTAssertTrue(notifications.waitForExistence(timeout: 5))
        XCTAssertTrue(
            ["Checking…", "Not Enabled", "Denied", "Enabled", "Unavailable"]
                .contains(notifications.value as? String ?? "")
        )
        XCTAssertTrue(findStaticText("Conversation", in: app))
        XCTAssertTrue(app.staticTexts["Internal Thinking"].exists)
        XCTAssertTrue(app.staticTexts["Commands"].exists)
        XCTAssertTrue(findStaticText("Tools", in: app))
    }

    @MainActor
    func testCourseHomeOpensAppSettingsWithoutRequestingNotificationPermission() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["My Courses"].waitForExistence(timeout: 10))
        let appSettings = identifiedElement("course-home-app-settings", in: app)
        XCTAssertTrue(waitUntilHittable(appSettings, timeout: 5))
        appSettings.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            identifiedElement("settings.notifications.row", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.navigationBars["Course Settings"].exists)
        XCTAssertEqual(
            app.alerts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "notification")
            ).count,
            0,
            "Opening App Settings must only inspect notification status, never request permission."
        )
        attachScreenshot(named: "Course Home App Settings without notification prompt", app: app)
    }

    @MainActor
    func testCourseDraftSurvivesSwipeBackAndRequiresDiscardConfirmation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_RESET_ONBOARDING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launch()

        let library = app.staticTexts["course-library-root"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        let newCourse = app.buttons["new-course-button"]
        XCTAssertTrue(waitUntilHittable(newCourse, timeout: 5))
        newCourse.tap()

        let draftText = "Build me a course about actor isolation"
        let composer = app.textFields["course-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText(draftText)

        let swipeStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let swipeEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        swipeStart.press(forDuration: 0.05, thenDragTo: swipeEnd)

        XCTAssertTrue(library.waitForExistence(timeout: 10))
        let continueDraft = app.buttons["continue-course-draft-button"]
        XCTAssertTrue(continueDraft.waitForExistence(timeout: 5))
        XCTAssertEqual(continueDraft.value as? String, "saved")
        attachScreenshot(named: "Course draft available after swipe back", app: app)

        XCTAssertTrue(waitUntilHittable(newCourse, timeout: 5))
        newCourse.tap()
        let replacementAlert = app.alerts["Start a new course?"]
        XCTAssertTrue(replacementAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(replacementAlert.buttons["Continue Draft"].exists)
        XCTAssertTrue(replacementAlert.buttons["Discard Draft and Start New"].exists)
        attachScreenshot(named: "Course draft replacement confirmation", app: app)

        replacementAlert.buttons["Continue Draft"].tap()
        let restoredComposer = app.textFields["course-chat-composer"]
        XCTAssertTrue(restoredComposer.waitForExistence(timeout: 10))
        XCTAssertEqual(restoredComposer.value as? String, draftText)

        swipeStart.press(forDuration: 0.05, thenDragTo: swipeEnd)
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilHittable(newCourse, timeout: 5))
        newCourse.tap()
        XCTAssertTrue(replacementAlert.waitForExistence(timeout: 5))
        replacementAlert.buttons["Discard Draft and Start New"].tap()

        let replacementComposer = app.textFields["course-chat-composer"]
        XCTAssertTrue(replacementComposer.waitForExistence(timeout: 10))
        XCTAssertNotEqual(replacementComposer.value as? String, draftText)
    }

    @MainActor
    func testConversationDisplayExpandedModeShowsAllDetails() throws {
        let app = conversationDisplayHarnessApp(reasoning: "expanded", commands: "expanded", tools: "expanded")
        app.launch()

        XCTAssertTrue(app.staticTexts["UITEST_USER_MESSAGE"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["UITEST_ASSISTANT_MESSAGE"].exists)
        XCTAssertTrue(app.staticTexts["UITEST_REASONING_DETAIL"].exists)
        XCTAssertTrue(app.staticTexts["UITEST_COMMAND_OUTPUT"].exists)
        XCTAssertTrue(app.staticTexts["UITEST_TOOL_DETAIL"].exists)
    }

    @MainActor
    func testConversationDisplayCollapsedModeKeepsRowsAndRetainsRecentDetails() throws {
        let app = conversationDisplayHarnessApp(reasoning: "collapsed", commands: "collapsed", tools: "collapsed")
        app.launch()

        XCTAssertTrue(app.staticTexts["UITEST_USER_MESSAGE"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["UITEST_ASSISTANT_MESSAGE"].exists)
        XCTAssertTrue(app.staticTexts["Thinking"].exists)
        XCTAssertTrue(app.staticTexts["Internal reasoning"].exists)
        XCTAssertTrue(app.staticTexts["printf UITEST_COMMAND_HEADER"].exists)
        XCTAssertTrue(app.staticTexts["uiTest.fixtureTool"].exists)
        XCTAssertFalse(app.staticTexts["UITEST_REASONING_DETAIL"].exists)
        XCTAssertFalse(app.staticTexts["UITEST_COMMAND_OUTPUT"].exists)
        XCTAssertTrue(app.staticTexts["UITEST_TOOL_DETAIL"].exists)
        XCTAssertTrue(app.staticTexts["UITEST_LIVE_COMMAND_OUTPUT"].exists)
    }

    @MainActor
    func testConversationDisplayHiddenModeRemovesDetailRows() throws {
        let app = conversationDisplayHarnessApp(reasoning: "hidden", commands: "hidden", tools: "hidden")
        app.launch()

        XCTAssertTrue(app.staticTexts["UITEST_USER_MESSAGE"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["UITEST_ASSISTANT_MESSAGE"].exists)
        XCTAssertFalse(app.staticTexts["Thinking"].exists)
        XCTAssertFalse(app.staticTexts["Internal reasoning"].exists)
        XCTAssertFalse(app.staticTexts["printf UITEST_COMMAND_HEADER"].exists)
        XCTAssertFalse(app.staticTexts["uiTest.fixtureTool"].exists)
        XCTAssertFalse(app.staticTexts["UITEST_REASONING_DETAIL"].exists)
        XCTAssertFalse(app.staticTexts["UITEST_COMMAND_OUTPUT"].exists)
        XCTAssertFalse(app.staticTexts["UITEST_TOOL_DETAIL"].exists)
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        try XCTSkipIf(
            true,
            "Legacy Classic Learnfold screenshot flow is not part of the Learnfold free-alpha release lane."
        )
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launch()

        // Wait for splash to dismiss
        sleep(4)

        // 01 - Home (empty state)
        snapshot("01_Home")

        // 02 - Settings
        let settingsButton = app.buttons["header.settingsButton"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
            sleep(1)
            snapshot("02_Settings")

            // Dismiss settings
            app.swipeDown()
            sleep(1)
        }

        // 03 - Discovery
        let connectButton = app.buttons["Connect Server"]
        if connectButton.waitForExistence(timeout: 3), connectButton.isHittable {
            connectButton.tap()
            sleep(2)
            snapshot("03_Discovery")

            // Dismiss discovery
            app.swipeDown()
            sleep(1)
        }
    }

    @MainActor
    func testCaptureScreenshots() throws {
        try XCTSkipIf(
            true,
            "Legacy Codex/SSH discovery screenshots are intentionally excluded from the Learnfold release lane."
        )
        let app = XCUIApplication()
        app.launchEnvironment["CODEXIOS_UI_TEST_FORCE_DISCOVERY"] = "1"
        setupSnapshot(app)
        app.launch()

        XCTAssertTrue(presentDiscovery(in: app), "Unable to open discovery")
        XCTAssertTrue(waitForDiscoveryServers(in: app, timeout: 20), "No discovery servers found")
        _ = waitForDiscoveryListToPopulate(in: app, timeout: 12, minimumRows: 3)
        snapshot("01DiscoveryLoaded")

        XCTAssertTrue(
            selectPreferredDiscoveryServer(in: app, preferredHostFragment: ".203"),
            "Unable to tap the .203 server"
        )
        _ = waitForDiscoveryDismissed(in: app, timeout: 20)
        XCTAssertTrue(waitForHomeContentReady(in: app, timeout: 12), "Home dashboard did not load")
        sleep(1)
        snapshot("02HomeLoaded")

        XCTAssertTrue(openFirstConnectedServer(in: app), "Unable to open sessions screen")
        XCTAssertTrue(waitForSessionsScreen(in: app, timeout: 8), "Sessions screen did not appear")
        XCTAssertTrue(waitForAnySession(in: app, timeout: 12), "No sessions to select")
        sleep(1)
        snapshot("03SessionsLoaded")

        XCTAssertTrue(selectFirstSession(in: app), "Unable to open a session")
        XCTAssertTrue(waitForConversationLoaded(in: app, timeout: 10), "Conversation view did not load")
        sleep(2)
        snapshot("04ConversationLoaded")

        let backButton = app.buttons["header.homeButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 4), "Conversation header back button missing")
        backButton.tap()
        XCTAssertTrue(waitForSessionsScreen(in: app, timeout: 8), "Back did not return to sessions")
        sleep(1)
        snapshot("05ReturnedToSessions")
    }

    @MainActor
    private func presentDiscovery(in app: XCUIApplication) -> Bool {
        if isDiscoveryVisible(in: app) {
            return true
        }

        let primaryConnectButton = app.buttons["Connect Server"]
        if primaryConnectButton.waitForExistence(timeout: 2), primaryConnectButton.isHittable {
            primaryConnectButton.tap()
            return waitForDiscoveryVisible(in: app, timeout: 8)
        }

        let legacyConnectButton = app.buttons["Connect to Server"]
        if legacyConnectButton.waitForExistence(timeout: 2), legacyConnectButton.isHittable {
            legacyConnectButton.tap()
            return waitForDiscoveryVisible(in: app, timeout: 8)
        }

        return waitForDiscoveryVisible(in: app, timeout: 5)
    }

    @MainActor
    private func waitForDiscoveryServers(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let codexRows = codexDiscoveryRows(in: app)
        let sshRows = sshDiscoveryRows(in: app)
        let preferredHost = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", ".203"))

        return waitUntil(timeout: timeout) {
            preferredHost.firstMatch.exists || codexRows.firstMatch.exists || sshRows.firstMatch.exists
        }
    }

    @MainActor
    private func waitForDiscoveryListToPopulate(
        in app: XCUIApplication,
        timeout: TimeInterval,
        minimumRows: Int
    ) -> Bool {
        let codexRows = codexDiscoveryRows(in: app)
        let sshRows = sshDiscoveryRows(in: app)
        let preferredHost = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", ".203"))
        let scanningLabel = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Scanning")
        )

        return waitUntil(timeout: timeout) {
            let totalRows = codexRows.count + sshRows.count
            if totalRows >= minimumRows {
                return true
            }
            if preferredHost.firstMatch.exists && totalRows > 0 && !scanningLabel.firstMatch.exists {
                return true
            }
            return false
        }
    }

    @MainActor
    private func selectPreferredDiscoveryServer(in app: XCUIApplication, preferredHostFragment: String) -> Bool {
        let discoveryList = identifiedElement("discovery.list", in: app)
        guard discoveryList.waitForExistence(timeout: 8) else { return false }

        for _ in 0..<5 {
            if tapPreferredDiscoveryRow(in: app, hostFragment: preferredHostFragment) ||
                tapPreferredHostText(in: app, hostFragment: preferredHostFragment) {
                return true
            }
            discoveryList.swipeUp()
        }

        for _ in 0..<5 {
            if tapPreferredDiscoveryRow(in: app, hostFragment: preferredHostFragment) ||
                tapPreferredHostText(in: app, hostFragment: preferredHostFragment) {
                return true
            }
            discoveryList.swipeDown()
        }

        let codexRows = codexDiscoveryRows(in: app)
        if codexRows.firstMatch.waitForExistence(timeout: 4), codexRows.firstMatch.isHittable {
            codexRows.firstMatch.tap()
            return true
        }

        return false
    }

    @MainActor
    private func tapPreferredDiscoveryRow(in app: XCUIApplication, hostFragment: String) -> Bool {
        let normalized = hostFragment
            .lowercased()
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        let query = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier CONTAINS[c] %@",
                "discovery.server.codex.",
                normalized
            )
        )
        let row = query.firstMatch
        guard row.waitForExistence(timeout: 1), row.isHittable else { return false }
        row.tap()
        return true
    }

    @MainActor
    private func tapPreferredHostText(in app: XCUIApplication, hostFragment: String) -> Bool {
        let hostTexts = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", hostFragment))
        let first = hostTexts.firstMatch
        guard first.waitForExistence(timeout: 1), first.isHittable else { return false }
        first.tap()
        return true
    }

    @MainActor
    private func waitForDiscoveryVisible(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { isDiscoveryVisible(in: app) }
    }

    @MainActor
    private func waitForDiscoveryDismissed(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let discoveryList = identifiedElement("discovery.list", in: app)
        return waitUntil(timeout: timeout) { !discoveryList.exists || !discoveryList.isHittable }
    }

    @MainActor
    private func isDiscoveryVisible(in app: XCUIApplication) -> Bool {
        let discoveryList = identifiedElement("discovery.list", in: app)
        return discoveryList.exists && discoveryList.isHittable
    }

    @MainActor
    private func waitForHomeContentReady(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let connectedServerRow = app.descendants(matching: .any).matching(identifier: "home.connectedServerRow")
        let connectButton = app.buttons["Connect Server"]
        return waitUntil(timeout: timeout) {
            (connectedServerRow.firstMatch.exists && connectedServerRow.firstMatch.isHittable) ||
                (connectButton.exists && connectButton.isHittable)
        }
    }

    @MainActor
    private func openFirstConnectedServer(in app: XCUIApplication) -> Bool {
        let rows = app.descendants(matching: .any).matching(identifier: "home.connectedServerRow")
        let firstRow = rows.firstMatch
        guard firstRow.waitForExistence(timeout: 8), firstRow.isHittable else { return false }
        firstRow.tap()
        return true
    }

    @MainActor
    private func waitForSessionsScreen(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let sessionsContainer = identifiedElement("sessions.container", in: app)
        return waitUntil(timeout: timeout) {
            sessionsContainer.exists && sessionsContainer.isHittable
        }
    }

    @MainActor
    private func waitForAnySession(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let rows = app.descendants(matching: .any).matching(identifier: "sessions.sessionRow")
        return waitUntil(timeout: timeout) { rows.firstMatch.exists }
    }

    @MainActor
    private func selectFirstSession(in app: XCUIApplication) -> Bool {
        let sessionsContainer = identifiedElement("sessions.container", in: app)
        let rowQuery = app.descendants(matching: .any).matching(identifier: "sessions.sessionRow")

        for _ in 0..<8 {
            let count = min(rowQuery.count, 12)
            if count > 0 {
                for index in 0..<count {
                    let row = rowQuery.element(boundBy: index)
                    if row.exists && row.isHittable {
                        row.tap()
                        return true
                    }
                }
            }
            if sessionsContainer.exists {
                sessionsContainer.swipeUp()
            } else {
                break
            }
        }

        let titles = app.staticTexts.matching(identifier: "sessions.sessionTitle")
        let titleCount = min(titles.count, 12)
        for index in 0..<titleCount {
            let title = titles.element(boundBy: index)
            if title.exists && title.isHittable {
                title.tap()
                return true
            }
        }

        return false
    }

    @MainActor
    private func waitForConversationLoaded(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let backButton = app.buttons["header.homeButton"]
        let sessionsContainer = identifiedElement("sessions.container", in: app)
        return waitUntil(timeout: timeout) {
            backButton.exists && backButton.isHittable && (!sessionsContainer.exists || !sessionsContainer.isHittable)
        }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        poll: TimeInterval = 0.2,
        condition: @MainActor () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(poll))
        }
        return condition()
    }

    @MainActor
    private func identifiedElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func elementLabeled(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 6
    ) -> Bool {
        for _ in 0..<attempts {
            if element.exists && element.isHittable {
                return true
            }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachHierarchy(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func elementContainingText(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    text,
                    text
                )
            )
            .firstMatch
    }

    @MainActor
    private func codexDiscoveryRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.server.codex."))
    }

    @MainActor
    private func sshDiscoveryRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.server.ssh."))
    }

    @MainActor
    private func conversationDisplayHarnessApp(
        reasoning: String = "collapsed",
        commands: String = "collapsed",
        tools: String = "collapsed"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments.append("--ui-test-conversation-display")
        app.launchEnvironment["CODEXIOS_UI_TEST_REASONING_MODE"] = reasoning
        app.launchEnvironment["CODEXIOS_UI_TEST_COMMAND_MODE"] = commands
        app.launchEnvironment["CODEXIOS_UI_TEST_TOOL_MODE"] = tools
        return app
    }

    @MainActor
    private func appleCourseSetupApp(
        onDeviceAvailable: Bool,
        privateCloudAvailable: Bool
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["LEARNFOLD_HOSTED_AGENT_URL"] = ""
        app.launchEnvironment["SNAPPY_RESET_ONBOARDING"] = "1"
        app.launchEnvironment["SNAPPY_APPLE_ON_DEVICE_AVAILABLE"] = onDeviceAvailable ? "1" : "0"
        app.launchEnvironment["SNAPPY_APPLE_PRIVATE_CLOUD_AVAILABLE"] =
            privateCloudAvailable ? "1" : "0"
        return app
    }

    @MainActor
    private func continuePastIntroIfNeeded(in app: XCUIApplication) {
        let continueButton = app.buttons["learnfold-intro-continue"]
        if continueButton.waitForExistence(timeout: 4),
           waitUntilHittable(continueButton, timeout: 10) {
            continueButton.tap()
        }
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
    private func findStaticText(_ label: String, in app: XCUIApplication) -> Bool {
        let text = app.staticTexts[label]
        if text.exists {
            return true
        }

        for _ in 0..<4 {
            app.swipeUp()
            if text.waitForExistence(timeout: 1) {
                return true
            }
        }

        return false
    }
}
