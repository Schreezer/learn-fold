import CoreFoundation
import UIKit
import XCTest

final class CourseRecoveryCheckpointUITests: XCTestCase {
    private enum Scenario: String, CaseIterable {
        case lf34Preparing = "--ui-test-lf34-preparing"
        case lf34KnownNotAccepted = "--ui-test-lf34-known-not-accepted"
        case lf34AcceptanceUnknown = "--ui-test-lf34-acceptance-unknown"
        case lf34AcceptedReplyIncomplete = "--ui-test-lf34-accepted-reply-incomplete"
        case lf34DestructiveConfirmation = "--ui-test-lf34-destructive-confirmation"

        case lf35MissingDiscussion = "--ui-test-lf35-missing-discussion"
        case lf35Recovering = "--ui-test-lf35-recovering"
        case lf35RecoveryFailure = "--ui-test-lf35-recovery-failure"
        case lf35UnreadableEvidence = "--ui-test-lf35-unreadable-evidence"
        case lf35Provenance = "--ui-test-lf35-provenance"
        case lf35Confirmation = "--ui-test-lf35-confirmation"
        case lf35FinishDeletion = "--ui-test-lf35-finish-deletion"

        case lf36AuthenticationRecovery = "--ui-test-lf36-authentication-recovery"
        case lf36TransportRecovery = "--ui-test-lf36-transport-recovery"

        case lf53ConflictDialog = "--ui-test-lf53-conflict-dialog"
        case lf53ContinueExisting = "--ui-test-lf53-continue-existing"
        case lf53CloseAndStartNew = "--ui-test-lf53-close-and-start-new"
        case lf53Cancel = "--ui-test-lf53-cancel"
        case lf53ReplacementFailure = "--ui-test-lf53-replacement-failure"

        var stateKey: String {
            String(rawValue.dropFirst("--ui-test-".count))
        }

        var marker: String {
            switch self {
            case .lf34Preparing, .lf35Recovering, .lf35Provenance,
                 .lf53ConflictDialog, .lf53ContinueExisting,
                 .lf53CloseAndStartNew, .lf53Cancel:
                "LOCAL UI FIXTURE"
            default:
                "INJECTED LOCAL FAULT"
            }
        }

        var initialModalAction: String? {
            switch self {
            case .lf34DestructiveConfirmation:
                "Discard Draft"
            case .lf35Confirmation:
                "Keep Workspace"
            case .lf53ConflictDialog, .lf53ContinueExisting,
                 .lf53CloseAndStartNew, .lf53Cancel,
                 .lf53ReplacementFailure:
                "Continue with Hermes"
            default:
                nil
            }
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStrictCheckpointRejectsMissingAndMultipleScenarioConfiguration() {
        let configurations: [[Scenario]] = [
            [],
            [.lf34Preparing, .lf35Recovering],
        ]

        for scenarios in configurations {
            let app = launchConfigurationError(scenarios)
            XCTAssertTrue(
                element("courseRecoveryCheckpoint.configurationError", in: app)
                    .waitForExistence(timeout: 5)
            )
            XCTAssertTrue(
                app.staticTexts["Checkpoint configuration rejected"].exists
            )
            attachScreenshot(
                named: scenarios.isEmpty
                    ? "Recovery checkpoint missing scenario"
                    : "Recovery checkpoint multiple scenarios",
                app: app
            )
            app.terminate()
        }
    }

    @MainActor
    func testLF34FrozenSubmissionStatesExposeSafeProductionActions() {
        let cases: [(
            scenario: Scenario,
            enabledComposer: Bool,
            actionIdentifiers: [String],
            hasDraftProvenance: Bool,
            draftDisposition: String,
            sourceCount: Int
        )] = [
            (
                .lf34Preparing,
                true,
                [
                    "course-agent-error.action.retry-submission",
                    "course-agent-error.action.discard-draft",
                    "course-agent-error.action.dismiss",
                ],
                true,
                "Draft preserved",
                1
            ),
            (
                .lf34KnownNotAccepted,
                true,
                [
                    "course-agent-error.action.retry-submission",
                    "course-agent-error.action.discard-draft",
                    "course-agent-error.action.dismiss",
                ],
                true,
                "Draft preserved",
                1
            ),
            (
                .lf34AcceptanceUnknown,
                false,
                [
                    "course-agent-error.action.check-status",
                    "course-agent-error.action.abandon-local-draft",
                    "course-agent-error.action.dismiss",
                ],
                true,
                "Draft preserved",
                1
            ),
            (
                .lf34AcceptedReplyIncomplete,
                false,
                [
                    "course-agent-error.action.check-status",
                    "course-agent-error.action.dismiss",
                ],
                false,
                "Draft empty",
                0
            ),
        ]

        for testCase in cases {
            let app = launch(testCase.scenario)
            let composer = element("course-chat-composer", in: app)
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            XCTAssertEqual(
                composer.isEnabled,
                testCase.enabledComposer,
                "\(testCase.scenario.rawValue) composer blocking drifted"
            )

            for identifier in testCase.actionIdentifiers {
                XCTAssertTrue(
                    element(identifier, in: app).exists,
                    "Missing production recovery action \(identifier)"
                )
            }
            XCTAssertEqual(
                element("course-recovered-draft-provenance", in: app).exists,
                testCase.hasDraftProvenance
            )
            XCTAssertEqual(
                element("courseRecoveryCheckpoint.draftDisposition", in: app).label,
                testCase.draftDisposition
            )
            XCTAssertEqual(
                element("courseRecoveryCheckpoint.sourceCount", in: app).label,
                "Attached sources: \(testCase.sourceCount)"
            )
            XCTAssertEqual(
                element("courseRecoveryCheckpoint.workspaceDisposition", in: app).label,
                "Workspace preserved"
            )
            attachScreenshot(
                named: "\(testCase.scenario.stateKey) frozen state",
                app: app
            )
            app.terminate()
        }
    }

    @MainActor
    func testLF34RetryDismissAndDestructiveConfirmationsMutateOnlyLocalFixture() {
        var app = launch(.lf34Preparing)
        tapAction("course-agent-error.action.retry-submission", in: app)
        assertAction(
            "retry-submission",
            result: "Retry requested from the preserved local draft.",
            in: app
        )
        attachScreenshot(named: "LF-34 retry from preserved draft", app: app)
        app.terminate()

        app = launch(.lf34KnownNotAccepted)
        tapAction("course-agent-error.action.dismiss", in: app)
        assertAction(
            "dismiss",
            result: "Recovery prompt dismissed; preserved state is unchanged.",
            in: app
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.draftDisposition", in: app).label,
            "Draft preserved"
        )
        app.terminate()

        app = launch(.lf34DestructiveConfirmation)
        assertDialog(
            title: "Discard the restored draft?",
            message: "The restored message and its attached sources will be removed. The course and conversation will stay intact.",
            actions: ["Discard Draft", "Keep Draft"],
            in: app
        )
        attachScreenshot(named: "LF-34 discard draft confirmation", app: app)
        tapDialogAction("Keep Draft", in: app)
        XCTAssertTrue(waitForDisappearance(app.staticTexts["Discard the restored draft?"]))
        XCTAssertEqual(element("courseRecoveryCheckpoint.lastAction", in: app).label, "none")
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.draftDisposition", in: app).label,
            "Draft preserved"
        )

        tapAction("course-agent-error.action.discard-draft", in: app)
        XCTAssertTrue(app.staticTexts["Discard the restored draft?"].waitForExistence(timeout: 3))
        tapDialogAction("Discard Draft", in: app)
        assertAction(
            "discard-draft",
            result: "Restored local draft discarded; course workspace preserved.",
            in: app
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.draftDisposition", in: app).label,
            "Draft empty"
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.sourceCount", in: app).label,
            "Attached sources: 0"
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.workspaceDisposition", in: app).label,
            "Workspace preserved"
        )
        attachScreenshot(named: "LF-34 local draft discarded safely", app: app)
    }

    @MainActor
    func testLF34UnknownAcceptanceCheckAndAbandonGuardAgainstDuplicateSubmission() {
        let app = launch(.lf34AcceptanceUnknown)
        tapAction("course-agent-error.action.check-status", in: app)
        assertAction(
            "check-submission-status",
            result: "Status check requested; no backend was contacted by this fixture.",
            in: app
        )

        tapAction("course-agent-error.action.abandon-local-draft", in: app)
        assertDialog(
            title: "Abandon the unconfirmed local draft?",
            message: "Learnfold cannot prove whether the agent received this message. Abandoning removes the local recovered copy and unlocks the composer. Review the conversation before sending the same request again, because doing so could create a duplicate.",
            actions: ["Abandon Local Draft", "Keep Checking"],
            in: app
        )
        attachScreenshot(named: "LF-34 acceptance unknown warning", app: app)
        tapDialogAction("Keep Checking", in: app)
        XCTAssertTrue(
            waitForDisappearance(app.staticTexts["Abandon the unconfirmed local draft?"])
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.draftDisposition", in: app).label,
            "Draft preserved"
        )

        tapAction("course-agent-error.action.abandon-local-draft", in: app)
        XCTAssertTrue(
            app.staticTexts["Abandon the unconfirmed local draft?"]
                .waitForExistence(timeout: 3)
        )
        tapDialogAction("Abandon Local Draft", in: app)
        XCTAssertTrue(
            waitForDisappearance(
                app.staticTexts["Abandon the unconfirmed local draft?"],
                timeout: 10
            ),
            "The destructive confirmation must dismiss before the local action is observed"
        )
        assertAction(
            "abandon-unknown-draft",
            result: "Unconfirmed local draft abandoned; course workspace preserved.",
            in: app,
            timeout: 10
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.workspaceDisposition", in: app).label,
            "Workspace preserved"
        )
        attachScreenshot(named: "LF-34 unknown draft abandoned locally", app: app)
    }

    @MainActor
    func testLF35FrozenHermesRecoveryStatesExposeEvidenceAndActions() {
        var app = launch(.lf35MissingDiscussion)
        let startNew = element("course-agent-error.action.close-start-new", in: app)
        XCTAssertEqual(startNew.label, "Start New Discussion")
        assertMinimumHitSize(startNew)
        let hideNotice = element("course-agent-error.action.dismiss", in: app)
        XCTAssertEqual(hideNotice.label, "Hide Notice")
        assertMinimumHitSize(hideNotice)
        attachScreenshot(named: "LF-35 missing discussion", app: app)
        app.terminate()

        app = launch(.lf35Recovering)
        XCTAssertTrue(element("course-hermes-recovery-progress", in: app).exists)
        XCTAssertTrue(app.staticTexts["Hermes recovery in progress"].exists)
        XCTAssertTrue(element("course-hermes-recovery.progress", in: app).exists)
        let stopRecovery = element("course-hermes-recovery.action.stop", in: app)
        XCTAssertEqual(stopRecovery.label, "Stop Recovery…")
        assertMinimumHitSize(stopRecovery)
        XCTAssertFalse(element("course-agent-error", in: app).exists)
        XCTAssertFalse(element("course-agent-error.action.retry-recovery", in: app).exists)
        XCTAssertFalse(element("course-agent-error.action.abandon-recovery", in: app).exists)
        XCTAssertFalse(element("course-agent-error.action.dismiss", in: app).exists)
        attachScreenshot(named: "LF-35 dedicated recovery progress", app: app)
        app.terminate()

        app = launch(.lf35RecoveryFailure)
        XCTAssertEqual(
            element("course-agent-error.title", in: app).label,
            "Hermes recovery needs attention"
        )
        XCTAssertEqual(
            element("course-agent-error.message", in: app).label,
            "Hermes recovery could not finish. Your draft, course workspace, and recovery evidence are preserved. Resolve this recovery to continue with the preserved workspace."
        )
        XCTAssertFalse(element("course-agent-error.action.retry-recovery", in: app).exists)
        let resolveFailedRecovery = element(
            "course-agent-error.action.abandon-recovery",
            in: app
        )
        XCTAssertEqual(resolveFailedRecovery.label, "Resolve Recovery…")
        assertMinimumHitSize(resolveFailedRecovery)
        XCTAssertFalse(element("course-agent-error.action.dismiss", in: app).exists)
        attachScreenshot(named: "lf35-recovery-failure terminal actions", app: app)
        app.terminate()

        app = launch(.lf35UnreadableEvidence)
        XCTAssertEqual(
            element("course-agent-error.message", in: app).label,
            "Hermes recovery evidence could not be read safely. Your draft and course workspace remain protected. Retry recovery or resolve it without losing the evidence."
        )
        XCTAssertTrue(element("course-agent-error.action.retry-recovery", in: app).exists)
        let resolveUnreadableEvidence = element(
            "course-agent-error.action.abandon-recovery",
            in: app
        )
        XCTAssertEqual(resolveUnreadableEvidence.label, "Resolve Recovery…")
        assertMinimumHitSize(resolveUnreadableEvidence)
        XCTAssertFalse(app.buttons["Stop Recovery…"].exists)
        tapAction("course-agent-error.action.abandon-recovery", in: app)
        assertDialog(
            title: "Resolve Hermes recovery?",
            message: "Recovery is already stopped and its evidence is kept. Keep the course workspace to clear this recovery block so you can review or continue it later.",
            actions: ["Keep Workspace", "Cancel"],
            in: app
        )
        XCTAssertFalse(app.buttons["Stop & Keep Workspace"].exists)
        attachScreenshot(named: "LF-35 unreadable evidence resolution", app: app)
        tapDialogAction("Cancel", in: app)
        app.terminate()

        app = launch(.lf35Provenance)
        XCTAssertFalse(element("course-recovered-draft-provenance", in: app).exists)
        XCTAssertTrue(element("course-hermes-recovery-progress", in: app).exists)
        XCTAssertFalse(element("course-agent-error", in: app).exists)
        XCTAssertTrue(element("course-hermes-recovery-provenance", in: app).exists)
        let disclosure = element(
            "course-hermes-recovery-provenance.toggle",
            in: app
        )
        XCTAssertTrue(scrollUntilHittable(disclosure, in: app))
        disclosure.tap()
        XCTAssertEqual(
            element("course-hermes-recovery-provenance.workspace", in: app).label,
            "Workspace · Protected local course data"
        )
        XCTAssertEqual(
            element("course-hermes-recovery-provenance.discussion", in: app).label,
            "Discussion · Course conversation"
        )
        XCTAssertEqual(
            element("course-hermes-recovery-provenance.journal", in: app).label,
            "Journal · Native tool result delivery pending"
        )
        XCTAssertEqual(
            element("course-hermes-recovery-provenance.correlation", in: app).label,
            "Correlation · Retained privately for safe retry"
        )
        XCTAssertFalse(app.staticTexts["lf35-fixture-workspace"].exists)
        XCTAssertFalse(app.staticTexts["lf35-fixture-thread"].exists)
        XCTAssertFalse(app.staticTexts["learnfold_generate_lesson"].exists)
        let stopWithDetails = element("course-hermes-recovery.action.stop", in: app)
        XCTAssertTrue(scrollUntilHittable(stopWithDetails, in: app))
        assertMinimumHitSize(stopWithDetails)
        attachScreenshot(named: "LF-35 technical details disclosed", app: app)
    }

    @MainActor
    func testLF35MissingDiscussionAndRecoveryActionsPreserveEvidence() {
        var app = launch(.lf35MissingDiscussion)
        tapAction("course-agent-error.action.close-start-new", in: app)
        assertDialog(
            title: "Start a new discussion?",
            message: "Your old annotation and recovery evidence will be kept. The new discussion will use your currently selected agent in the same course workspace.",
            actions: ["Start New Discussion", "Cancel"],
            in: app
        )
        tapDialogAction("Cancel", in: app)
        XCTAssertTrue(
            waitForDisappearance(
                app.staticTexts["Start a new discussion?"]
            )
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.discussionDisposition", in: app).label,
            "Existing discussion preserved"
        )
        tapAction("course-agent-error.action.close-start-new", in: app)
        XCTAssertTrue(
            app.staticTexts["Start a new discussion?"]
                .waitForExistence(timeout: 3)
        )
        tapDialogAction("Start New Discussion", in: app)
        assertAction(
            "start-replacement-discussion",
            result: "Replacement discussion opened; prior recovery evidence preserved.",
            in: app
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.discussionDisposition", in: app).label,
            "New discussion opened; prior evidence preserved"
        )
        attachScreenshot(named: "LF-35 missing discussion replaced safely", app: app)
        app.terminate()

        app = launch(.lf35Recovering)
        tapAction("course-hermes-recovery.action.stop", in: app)
        assertDialog(
            title: "Stop Hermes recovery?",
            message: "Recovery will stop and its evidence will be kept. You can keep the draft workspace or permanently delete it after the evidence is archived. Deleting the workspace cannot be undone.",
            actions: [
                "Stop & Keep Workspace",
                "Archive Evidence & Delete Draft",
                "Cancel",
            ],
            in: app
        )
        attachScreenshot(named: "LF-35 active recovery stop decision", app: app)
        tapDialogAction("Stop & Keep Workspace", in: app)
        assertAction(
            "keep-workspace",
            result: "Hermes recovery abandoned; course workspace retained.",
            in: app
        )
        app.terminate()

        app = launch(.lf35RecoveryFailure)
        XCTAssertFalse(element("course-agent-error.action.retry-recovery", in: app).exists)
        XCTAssertFalse(element("course-agent-error.action.dismiss", in: app).exists)
        tapAction("course-agent-error.action.abandon-recovery", in: app)
        assertDialog(
            title: "Resolve Hermes recovery?",
            message: "Recovery is already stopped and its evidence is kept. Keep the course workspace to clear this recovery block so you can review or continue it later.",
            actions: ["Keep Workspace", "Cancel"],
            in: app
        )
        XCTAssertFalse(app.buttons["Stop & Keep Workspace"].exists)
        tapDialogAction("Cancel", in: app)
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.workspaceDisposition", in: app).label,
            "Workspace preserved"
        )
        tapAction("course-agent-error.action.abandon-recovery", in: app)
        XCTAssertTrue(app.staticTexts["Resolve Hermes recovery?"].waitForExistence(timeout: 3))
        tapDialogAction("Keep Workspace", in: app)
        assertAction(
            "keep-workspace",
            result: "Hermes recovery abandoned; course workspace retained.",
            in: app
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.workspaceDisposition", in: app).label,
            "Workspace preserved; recovery abandoned"
        )
        attachScreenshot(named: "LF-35 recovery abandoned with workspace", app: app)
    }

    @MainActor
    func testLF35ConfirmationOffersBothExplicitWorkspaceOutcomes() {
        let app = launch(.lf35Confirmation)
        assertDialog(
            title: "Resolve Hermes recovery?",
            message: "Recovery is already stopped and its evidence is kept. Choose whether to keep the draft workspace or archive the evidence and permanently delete the draft. Deleting the workspace cannot be undone.",
            actions: [
                "Keep Workspace",
                "Archive Evidence & Delete Draft",
                "Cancel",
            ],
            in: app
        )
        XCTAssertFalse(app.buttons["Stop & Keep Workspace"].exists)
        attachScreenshot(named: "LF-35 explicit workspace decision", app: app)
        tapDialogAction("Keep Workspace", in: app)
        assertAction(
            "keep-workspace",
            result: "Hermes recovery abandoned; course workspace retained.",
            in: app
        )

        tapAction("course-agent-error.action.abandon-recovery", in: app)
        XCTAssertTrue(app.staticTexts["Resolve Hermes recovery?"].waitForExistence(timeout: 3))
        tapDialogAction("Archive Evidence & Delete Draft", in: app)
        assertAction(
            "delete-draft-workspace",
            result: "Recovery evidence archived before the draft workspace was deleted.",
            in: app
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.workspaceDisposition", in: app).label,
            "Recovery archived; draft workspace deleted"
        )
        attachScreenshot(named: "LF-35 archived then deleted fixture", app: app)
    }

    @MainActor
    func testLF35FinishDeletionExposesOnlyIrreversibleCleanupActions() {
        let app = launch(.lf35FinishDeletion)
        XCTAssertEqual(
            element("course-agent-error.title", in: app).label,
            "Draft deletion is incomplete"
        )
        let blockingMessage = element("course-agent-error.message", in: app)
        XCTAssertTrue(blockingMessage.waitForExistence(timeout: 3))
        XCTAssertEqual(
            blockingMessage.label,
            "Recovery evidence is already archived. Review what will be kept, then permanently delete the remaining draft workspace data before starting new messages."
        )
        XCTAssertTrue(
            element("course-agent-error.deletion.will-delete", in: app)
                .label
                .contains("Remaining draft workspace data")
        )
        XCTAssertTrue(
            element("course-agent-error.deletion.will-keep", in: app)
                .label
                .contains("Archived recovery evidence")
        )
        let reviewDeletion = element(
            "course-agent-error.action.finish-delete-draft",
            in: app
        )
        XCTAssertEqual(reviewDeletion.label, "Review Permanent Deletion…")
        assertMinimumHitSize(reviewDeletion)
        for identifier in [
            "course-agent-error.action.retry-recovery",
            "course-agent-error.action.abandon-recovery",
            "course-agent-error.action.close-start-new",
            "course-agent-error.action.dismiss",
        ] {
            XCTAssertFalse(element(identifier, in: app).exists)
        }
        XCTAssertFalse(app.buttons["Stop & Keep Workspace"].exists)
        XCTAssertFalse(app.buttons["Keep Workspace"].exists)

        tapAction("course-agent-error.action.finish-delete-draft", in: app)
        assertDialog(
            title: "Permanently delete the remaining draft?",
            message: "Will delete: remaining draft workspace data.\n\nWill keep: archived recovery evidence.\n\nPermanent deletion cannot be undone. Review these consequences before continuing.",
            actions: ["Permanently Delete Remaining Draft", "Not Now"],
            in: app
        )
        XCTAssertTrue(element(
            "course-agent-error.confirm.finish-delete-draft",
            in: app
        ).exists)
        XCTAssertTrue(element(
            "course-agent-error.confirm.cancel-abandon-recovery",
            in: app
        ).exists)
        XCTAssertFalse(element(
            "course-agent-error.confirm.keep-workspace",
            in: app
        ).exists)
        XCTAssertFalse(element(
            "course-agent-error.confirm.delete-workspace",
            in: app
        ).exists)
        XCTAssertFalse(app.buttons["Stop & Keep Workspace"].exists)
        XCTAssertFalse(app.buttons["Keep Workspace"].exists)
        XCTAssertFalse(app.buttons["Archive Evidence & Delete Draft"].exists)
        attachScreenshot(named: "LF-35 permanent deletion review", app: app)
        tapDialogAction("Not Now", in: app)
        XCTAssertTrue(waitForDisappearance(
            app.staticTexts["Permanently delete the remaining draft?"]
        ))
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.lastAction", in: app).label,
            "none"
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.workspaceDisposition", in: app).label,
            "Draft deletion incomplete; cleanup required"
        )

        tapAction("course-agent-error.action.finish-delete-draft", in: app)
        XCTAssertTrue(app.staticTexts["Permanently delete the remaining draft?"]
            .waitForExistence(timeout: 3))
        tapDialogAction("Permanently Delete Remaining Draft", in: app)
        assertAction(
            "finish-draft-deletion",
            result: "Remaining draft data deleted; previously archived recovery evidence retained.",
            in: app
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.workspaceDisposition", in: app).label,
            "Recovery archived; draft workspace deleted"
        )
        assertStrictRoot(in: app)
        attachScreenshot(named: "LF-35 finish partial draft deletion", app: app)
    }

    @MainActor
    func testLF35RecoveryActionsRemainReachableWithLargeTextInLandscape() {
        let device = XCUIDevice.shared
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        device.orientation = .portrait
        let app = launch(
            .lf35Provenance,
            preferredContentSizeCategory:
                "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        )
        let appWindow = app.windows.firstMatch
        addTeardownBlock { @MainActor in
            var restoredPortraitFrame: CGRect?
            for _ in 0..<2 {
                device.orientation = .portrait
                CFNotificationCenterPostNotification(
                    darwinCenter,
                    CFNotificationName(
                        "com.sigkitten.kittyfarm.rotate.portrait" as CFString
                    ),
                    nil,
                    nil,
                    true
                )
                restoredPortraitFrame = self.waitForStableWindowFrame(
                    appWindow,
                    landscape: false,
                    timeout: 5
                )
                if restoredPortraitFrame != nil { break }
            }
            XCTAssertNotNil(
                restoredPortraitFrame,
                "LF-35 cleanup could not restore stable portrait geometry; later UI tests may be contaminated"
            )
        }
        CFNotificationCenterPostNotification(
            darwinCenter,
            CFNotificationName(
                "com.sigkitten.kittyfarm.rotate.portrait" as CFString
            ),
            nil,
            nil,
            true
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                appWindow.exists && appWindow.frame.height > appWindow.frame.width
            },
            "The LF-35 checkpoint must start from a known portrait geometry"
        )

        device.orientation = .landscapeLeft
        CFNotificationCenterPostNotification(
            darwinCenter,
            CFNotificationName(
                "com.sigkitten.kittyfarm.rotate.landscape-left" as CFString
            ),
            nil,
            nil,
            true
        )
        guard let settledLandscapeFrame = waitForStableWindowFrame(
            appWindow,
            landscape: true,
            timeout: 5
        ) else {
            XCTFail(
                "The constrained-height checkpoint did not settle into landscape geometry"
            )
            return
        }
        XCTAssertGreaterThan(
            settledLandscapeFrame.width,
            settledLandscapeFrame.height,
            "The settled checkpoint window must remain physically landscape before interaction"
        )
        let stopRecovery = element("course-hermes-recovery.action.stop", in: app)
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.exists)
        XCTAssertTrue(
            scrollUntilHittable(stopRecovery, in: scrollView, attempts: 12)
        )
        assertMinimumHitSize(stopRecovery)
        guard let preCaptureLandscapeFrame = waitForStableWindowFrame(
            appWindow,
            landscape: true,
            timeout: 5
        ) else {
            XCTFail(
                "The checkpoint window did not remain stably landscape before screenshot capture"
            )
            return
        }
        XCTAssertGreaterThan(
            preCaptureLandscapeFrame.width,
            preCaptureLandscapeFrame.height,
            "The settled pre-capture checkpoint window must be landscape"
        )
        let landscapeScreenshot = XCUIScreen.main.screenshot()
        let landscapeImage = physicallyLandscapeScreenImage(
            from: landscapeScreenshot
        )
        guard let landscapePixels = landscapeImage.cgImage else {
            XCTFail("The retained LF-35 screenshot did not expose a pixel buffer")
            return
        }
        XCTAssertGreaterThan(
            landscapePixels.width,
            landscapePixels.height,
            "The retained LF-35 reflow screenshot must contain landscape pixels"
        )
        let attachment = XCTAttachment(image: landscapeImage)
        attachment.name = "LF-35 large text constrained-height actions"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLF36AuthenticationAndTransportRecoveryRemainDistinct() {
        var app = launch(.lf36AuthenticationRecovery)
        XCTAssertTrue(element("course-agent-error.action.sign-in", in: app).exists)
        XCTAssertFalse(element("course-agent-error.action.reconnect", in: app).exists)
        tapAction("course-agent-error.action.sign-in", in: app)
        assertAction(
            "sign-in",
            result: "Authentication recovery requested; course workspace preserved.",
            in: app
        )
        attachScreenshot(named: "LF-36 authentication recovery", app: app)
        app.terminate()

        app = launch(.lf36TransportRecovery)
        XCTAssertTrue(element("course-agent-error.action.reconnect", in: app).exists)
        XCTAssertFalse(element("course-agent-error.action.sign-in", in: app).exists)
        tapAction("course-agent-error.action.reconnect", in: app)
        assertAction(
            "reconnect-transport",
            result: "Transport reconnect requested; course workspace preserved.",
            in: app
        )
        tapAction("course-agent-error.action.dismiss", in: app)
        assertAction(
            "dismiss",
            result: "Recovery prompt dismissed; preserved state is unchanged.",
            in: app
        )
        attachScreenshot(named: "LF-36 transport recovery", app: app)
    }

    @MainActor
    func testLF53ProductionConflictDialogOffersAllThreeDecisions() {
        let app = launch(.lf53ConflictDialog)
        assertDialog(
            title: "A discussion already exists",
            message: "This exact passage already has an open discussion with Hermes. You selected Codex.",
            actions: ["Continue with Hermes", "Close & Start New with Codex", "Cancel"],
            in: app
        )
        attachScreenshot(named: "LF-53 production discussion conflict", app: app)
        app.buttons["Cancel"].tap()
        assertAction(
            "cancel-conflict",
            result: "Agent conflict cancelled; existing discussion preserved.",
            in: app
        )
        XCTAssertTrue(
            element(
                "courseRecoveryCheckpoint.state.\(Scenario.lf53ConflictDialog.stateKey)",
                in: app
            ).exists
        )
    }

    @MainActor
    func testLF53ContinueReplaceAndCancelMutateOnlyLocalFixture() {
        var app = launch(.lf53ContinueExisting)
        app.buttons["Continue with Hermes"].tap()
        assertAction(
            "continue-existing-discussion",
            result: "Existing discussion opened with its originally bound agent.",
            in: app
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.discussionDisposition", in: app).label,
            "Existing discussion opened"
        )
        attachScreenshot(named: "LF-53 continued existing discussion", app: app)
        app.terminate()

        app = launch(.lf53CloseAndStartNew)
        app.buttons["Close & Start New with Codex"].tap()
        assertAction(
            "start-replacement-discussion",
            result: "Replacement discussion opened; prior recovery evidence preserved.",
            in: app
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.discussionDisposition", in: app).label,
            "New discussion opened; prior evidence preserved"
        )
        attachScreenshot(named: "LF-53 started replacement discussion", app: app)
        app.terminate()

        app = launch(.lf53Cancel)
        app.buttons["Cancel"].tap()
        assertAction(
            "cancel-conflict",
            result: "Agent conflict cancelled; existing discussion preserved.",
            in: app
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.discussionDisposition", in: app).label,
            "Existing discussion preserved"
        )
        tapAction("courseRecoveryCheckpoint.conflict.show", in: app)
        XCTAssertTrue(app.staticTexts["A discussion already exists"].waitForExistence(timeout: 3))
        assertStrictRoot(in: app)
        attachScreenshot(named: "LF-53 conflict cancelled and reopened", app: app)
    }

    @MainActor
    func testLF53ReplacementFailureKeepsExistingDiscussionAndDraft() {
        let app = launch(.lf53ReplacementFailure)
        app.buttons["Close & Start New with Codex"].tap()

        let alert = app.alerts["Can’t start discussion"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(
            alert.staticTexts[
                "The existing discussion is still working or recovering. Stop it before starting a new one."
            ].exists
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.lastAction", in: app).label,
            "replacement-failed"
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.discussionDisposition", in: app).label,
            "Replacement failed; existing discussion preserved"
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.draftDisposition", in: app).label,
            "Draft preserved"
        )
        attachScreenshot(named: "LF-53 deterministic replacement failure", app: app)
        tapDialogAction("OK", in: app)
        XCTAssertTrue(waitForDisappearance(alert))
        assertAction(
            "replacement-failed",
            result: "Injected replacement failure; existing discussion and local draft preserved.",
            in: app
        )
    }

    @MainActor
    private func launch(
        _ scenario: Scenario,
        preferredContentSizeCategory: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments += [
            "--ui-test-course-recovery-checkpoint",
            scenario.rawValue,
        ]
        if let preferredContentSizeCategory {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                preferredContentSizeCategory,
            ]
        }
        app.launch()
        assertStrictRoot(in: app)

        if let initialModalAction = scenario.initialModalAction {
            XCTAssertNotNil(
                hittableDialogAction(
                    initialModalAction,
                    in: app,
                    timeout: 10
                ),
                "Initial checkpoint dialog did not launch for \(scenario.rawValue)"
            )
            return app
        }

        let state = element(
            "courseRecoveryCheckpoint.state.\(scenario.stateKey)",
            in: app
        )
        XCTAssertTrue(
            state.waitForExistence(timeout: 10),
            "Checkpoint did not launch for \(scenario.rawValue)"
        )
        let markerMatches = app.descendants(matching: .any)
            .matching(identifier: "courseRecoveryCheckpoint.fixtureMarker")
        XCTAssertEqual(
            markerMatches.count,
            1,
            "The LF-35 checkpoint marker must appear exactly once in raw accessibility"
        )
        let marker = markerMatches.firstMatch
        XCTAssertTrue(marker.exists)
        XCTAssertTrue(marker.label.contains(scenario.marker))
        XCTAssertTrue(marker.label.contains("NO LIVE BACKEND"))
        XCTAssertEqual(marker.value as? String, scenario.marker)
        XCTAssertTrue(
            waitUntilHittable(marker, timeout: 8),
            "Checkpoint remained covered for \(scenario.rawValue)"
        )
        XCTAssertTrue(
            element("courseRecoveryCheckpoint.evidenceBoundary", in: app)
                .label
                .contains("No server, agent runtime, thread, journal, keychain, network")
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.scenarioArgument", in: app).label,
            "Scenario argument: \(scenario.rawValue)"
        )
        return app
    }

    @MainActor
    private func launchConfigurationError(
        _ scenarios: [Scenario]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments = ["--ui-test-course-recovery-checkpoint"]
            + scenarios.map(\.rawValue)
        app.launch()
        assertStrictRoot(in: app)
        return app
    }

    @MainActor
    private func assertStrictRoot(in app: XCUIApplication) {
        let strictRoot = element("courseRecoveryCheckpoint.strictRoot", in: app)
        XCTAssertTrue(
            strictRoot.waitForExistence(timeout: 10),
            "Recovery checkpoint did not select its strict non-live app root"
        )
        XCTAssertEqual(
            strictRoot.label,
            "STRICT NON-LIVE FIXTURE ROOT · LIVE LIFECYCLE SUPPRESSED"
        )

        let sentinel = element(
            "courseRecoveryCheckpoint.forbiddenSideEffects",
            in: app
        )
        XCTAssertTrue(
            sentinel.waitForExistence(timeout: 5),
            "Strict recovery sentinel did not render"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let settledSentinel = element(
            "courseRecoveryCheckpoint.forbiddenSideEffects",
            in: app
        )
        let details = element(
            "courseRecoveryCheckpoint.forbiddenSideEffectDetails",
            in: app
        )
        XCTAssertEqual(
            settledSentinel.value as? String,
            "0",
            "Strict recovery root reached forbidden production entry points: \(details.exists ? details.label : "none")"
        )
        XCTAssertEqual(
            settledSentinel.label,
            "Forbidden production entry events · 0",
            "The screenshot-visible strict recovery sentinel must prove zero forbidden production entries"
        )
    }

    @MainActor
    private func tapAction(_ identifier: String, in app: XCUIApplication) {
        let attempts = 8

        for attempt in 0...attempts {
            let matches = app.buttons.matching(identifier: identifier)
            let candidates = (0..<matches.count).map { matches.element(boundBy: $0) }
            let visibleCandidates = candidates.filter { $0.exists && $0.isHittable }
            let composer = element("course-chat-composer", in: app)

            if visibleCandidates.count == 1, let action = visibleCandidates.first {
                let composerIsVisible = composer.exists && !composer.frame.isEmpty
                let isClearOfComposer = !composerIsVisible
                    || (!action.frame.intersects(composer.frame)
                        && action.frame.maxY <= composer.frame.minY)
                if isClearOfComposer {
                    action.tap()
                    return
                }
            }

            if visibleCandidates.count > 1 {
                XCTFail(actionCandidateDiagnostics(
                    identifier: identifier,
                    candidates: candidates,
                    visibleCount: visibleCandidates.count,
                    composer: composer,
                    app: app
                ))
                return
            }

            if attempt < attempts {
                let checkpointScroll = element("courseRecoveryCheckpoint.scroll", in: app)
                checkpointScroll.swipeUp()
            }
        }

        let matches = app.buttons.matching(identifier: identifier)
        let candidates = (0..<matches.count).map { matches.element(boundBy: $0) }
        let composer = element("course-chat-composer", in: app)
        XCTFail(actionCandidateDiagnostics(
            identifier: identifier,
            candidates: candidates,
            visibleCount: candidates.filter { $0.exists && $0.isHittable }.count,
            composer: composer,
            app: app
        ))
    }

    @MainActor
    private func actionCandidateDiagnostics(
        identifier: String,
        candidates: [XCUIElement],
        visibleCount: Int,
        composer: XCUIElement,
        app: XCUIApplication
    ) -> String {
        let candidateDetails = candidates.enumerated().map { index, candidate in
            "candidate[\(index)]: exists=\(candidate.exists), "
                + "hittable=\(candidate.isHittable), frame=\(candidate.frame)"
        }.joined(separator: "\n")

        return """
        Expected exactly one visible/hittable button for \(identifier); \
        found \(visibleCount) from \(candidates.count) candidates.
        Candidate frames:
        \(candidateDetails.isEmpty ? "none" : candidateDetails)
        Composer: exists=\(composer.exists), hittable=\(composer.isHittable), frame=\(composer.frame)
        Accessibility tree:
        \(app.debugDescription)
        """
    }

    @MainActor
    private func tapDialogAction(
        _ label: String,
        in app: XCUIApplication
    ) {
        // UIKit can expose SwiftUI dialog actions as nested Button → Button
        // nodes. Select the visible hit target instead of an arbitrary duplicate.
        guard let action = hittableDialogAction(label, in: app) else {
            XCTFail("Dialog action \(label) was not hittable")
            return
        }
        action.tap()
    }

    @MainActor
    private func hittableDialogAction(
        _ label: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 3
    ) -> XCUIElement? {
        let matches = app.buttons.matching(
            NSPredicate(format: "label == %@", label)
        )
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for index in 0..<matches.count {
                let candidate = matches.element(boundBy: index)
                if candidate.exists && candidate.isHittable {
                    return candidate
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    @MainActor
    private func assertAction(
        _ action: String,
        result: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 3
    ) {
        let reachedExpectedAction = waitUntil(timeout: timeout) {
            element("courseRecoveryCheckpoint.lastAction", in: app).label == action
        }
        let finalActionElement = element("courseRecoveryCheckpoint.lastAction", in: app)
        XCTAssertTrue(
            reachedExpectedAction,
            "Expected local action \(action), found \(finalActionElement.label)"
        )
        XCTAssertEqual(
            element("courseRecoveryCheckpoint.actionResult", in: app).label,
            result
        )
        XCTAssertTrue(
            element("courseRecoveryCheckpoint.evidenceBoundary", in: app)
                .label
                .contains("No server, agent runtime, thread, journal, keychain, network")
        )
        assertStrictRoot(in: app)
    }

    @MainActor
    private func assertDialog(
        title: String,
        message: String,
        actions: [String],
        in app: XCUIApplication
    ) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 3))
        let messageElement = app.staticTexts.matching(
            NSPredicate(format: "label == %@", message)
        ).firstMatch
        XCTAssertTrue(
            messageElement.waitForExistence(timeout: 3),
            "Missing dialog message: \(message)"
        )
        for action in actions {
            XCTAssertNotNil(
                hittableDialogAction(action, in: app),
                "Missing or covered dialog action \(action)"
            )
        }
    }

    @MainActor
    private func assertMinimumHitSize(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            element.frame.width,
            44,
            "Action width must be at least 44 points",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            element.frame.height,
            44,
            "Action height must be at least 44 points",
            file: file,
            line: line
        )
    }

    @MainActor
    private func physicallyLandscapeScreenImage(
        from screenshot: XCUIScreenshot
    ) -> UIImage {
        let image = screenshot.image
        guard let sourcePixels = image.cgImage,
              sourcePixels.height > sourcePixels.width else {
            return image
        }

        // iOS 26 returns the correctly rendered landscape screen in a
        // portrait backing buffer with landscape UIImage orientation metadata.
        // Redrawing the complete screen applies that metadata and emits real
        // landscape pixels; unlike app.screenshot(), this source contains the
        // full display without a padded black region.
        let targetSize = CGSize(
            width: CGFloat(sourcePixels.height) / image.scale,
            height: CGFloat(sourcePixels.width) / image.scale
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: targetSize,
            format: format
        ).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    @MainActor
    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    @MainActor
    private func waitUntilHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout, pollInterval: 0.1) {
            element.exists && element.isHittable
        }
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in scrollTarget: XCUIElement,
        attempts: Int = 8
    ) -> Bool {
        for _ in 0..<attempts {
            if waitUntilHittable(element, timeout: 0.5) { return true }
            scrollTarget.swipeUp()
        }
        return waitUntilHittable(element, timeout: 1)
    }

    @MainActor
    private func waitForDisappearance(
        _ element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForStableWindowFrame(
        _ window: XCUIElement,
        landscape: Bool,
        consecutiveSamples: Int = 3,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        geometryTolerance: CGFloat = 1
    ) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        var matchingSamples = 0
        var previousFrame: CGRect?

        while Date() < deadline {
            let frame = window.frame
            let matchesOrientation = landscape
                ? frame.width > frame.height
                : frame.height > frame.width
            if window.exists, !frame.isEmpty, matchesOrientation {
                let matchesPreviousGeometry = previousFrame.map {
                    abs(frame.minX - $0.minX) <= geometryTolerance
                        && abs(frame.minY - $0.minY) <= geometryTolerance
                        && abs(frame.width - $0.width) <= geometryTolerance
                        && abs(frame.height - $0.height) <= geometryTolerance
                } ?? true
                matchingSamples = matchesPreviousGeometry
                    ? matchingSamples + 1
                    : 1
                previousFrame = frame
                if matchingSamples >= consecutiveSamples {
                    return frame
                }
            } else {
                matchingSamples = 0
                previousFrame = nil
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(pollInterval)
            )
        }
        return nil
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    @MainActor
    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
