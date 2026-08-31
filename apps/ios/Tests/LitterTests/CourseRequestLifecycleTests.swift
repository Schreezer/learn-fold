import Foundation
import XCTest
@testable import Litter

final class CourseRequestLifecycleTests: XCTestCase {
    func testAccessibilityRawValuesMatchCheckpointContract() {
        XCTAssertEqual(CourseRequestLifecycle.optimistic.rawValue, "optimistic")
        XCTAssertEqual(CourseRequestLifecycle.thinking.rawValue, "thinking")
        XCTAssertEqual(CourseRequestLifecycle.streaming.rawValue, "streaming")
        XCTAssertEqual(CourseRequestLifecycle.stopping.rawValue, "stopping")
        XCTAssertEqual(CourseRequestLifecycle.reconnecting.rawValue, "reconnecting")
        XCTAssertEqual(CourseFocusedQAState.initialSheet.rawValue, "initial-sheet")
        XCTAssertEqual(CourseFocusedQAState.thinking.rawValue, "thinking")
        XCTAssertEqual(CourseFocusedQAState.answer.rawValue, "answer")
    }

    func testProjectsEveryActiveRequestLifecycleState() {
        XCTAssertEqual(
            CourseRequestLifecycle.project(
                runPhase: .submitting,
                isAgentWorking: true,
                hasAssistantContent: false,
                isReconnecting: false
            ),
            .optimistic
        )
        XCTAssertEqual(
            CourseRequestLifecycle.project(
                runPhase: .running,
                isAgentWorking: true,
                hasAssistantContent: false,
                isReconnecting: false
            ),
            .thinking
        )
        XCTAssertEqual(
            CourseRequestLifecycle.project(
                runPhase: .running,
                isAgentWorking: true,
                hasAssistantContent: true,
                isReconnecting: false
            ),
            .streaming
        )
        XCTAssertEqual(
            CourseRequestLifecycle.project(
                runPhase: .stopping,
                isAgentWorking: true,
                hasAssistantContent: true,
                isReconnecting: false
            ),
            .stopping
        )
        XCTAssertEqual(
            CourseRequestLifecycle.project(
                runPhase: .idle,
                isAgentWorking: false,
                hasAssistantContent: false,
                isReconnecting: true
            ),
            .reconnecting
        )
    }

    func testInactiveRequestHasNoLifecycleProjection() {
        XCTAssertNil(
            CourseRequestLifecycle.project(
                runPhase: .idle,
                isAgentWorking: false,
                hasAssistantContent: false,
                isReconnecting: false
            )
        )
        XCTAssertNil(
            CourseRequestLifecycle.project(
                runPhase: .failed("fixture failure"),
                isAgentWorking: false,
                hasAssistantContent: true,
                isReconnecting: false
            )
        )
    }

    func testReconnectTakesPrecedenceOverAnActiveRun() {
        XCTAssertEqual(
            CourseRequestLifecycle.project(
                runPhase: .running,
                isAgentWorking: true,
                hasAssistantContent: true,
                isReconnecting: true
            ),
            .reconnecting
        )
    }

    func testHydratedActiveTurnProjectsThinkingOrStreamingWhenRegistryIsIdle() {
        XCTAssertEqual(
            CourseRequestLifecycle.project(
                runPhase: .idle,
                isAgentWorking: true,
                hasAssistantContent: false,
                isReconnecting: false
            ),
            .thinking
        )
        XCTAssertEqual(
            CourseRequestLifecycle.project(
                runPhase: .idle,
                isAgentWorking: true,
                hasAssistantContent: true,
                isReconnecting: false
            ),
            .streaming
        )
    }

    func testHistoricalLiveAssistantPrecedesNewOptimisticLearnerBoundary() {
        let historicalLearner = CourseChatMessage(
            role: .learner,
            text: "Explain feedback loops."
        )
        let optimisticLearner = CourseChatMessage(
            role: .learner,
            text: "Now give me a local example."
        )
        let liveItems = [
            ConversationItem(
                id: "live-historical-learner",
                content: .user(
                    ConversationUserMessageData(
                        text: historicalLearner.text,
                        images: []
                    )
                )
            ),
            ConversationItem(
                id: "live-historical-assistant",
                content: .assistant(
                    ConversationAssistantMessageData(
                        text: "A reinforcing loop amplifies its starting change.",
                        agentNickname: nil,
                        agentRole: nil,
                        phase: nil
                    )
                )
            ),
        ]

        let merged = CourseChatTimelinePolicy.mergedConversationItems(
            localMessages: [historicalLearner, optimisticLearner],
            liveItems: liveItems
        )

        XCTAssertEqual(merged.map(\.id), [
            "course-local-\(historicalLearner.id.uuidString.lowercased())",
            "live-historical-assistant",
            "course-local-\(optimisticLearner.id.uuidString.lowercased())",
        ])
        XCTAssertFalse(
            CourseChatTimelinePolicy.hasAssistantContentAfterLatestLearner(
                in: merged
            )
        )
        XCTAssertEqual(
            CourseRequestLifecycle.project(
                runPhase: .running,
                isAgentWorking: true,
                hasAssistantContent: false,
                isReconnecting: false
            ),
            .thinking
        )
    }

    func testFocusedQAStateTracksTheLiveAnswerBoundary() {
        XCTAssertEqual(
            CourseFocusedQAState.project(
                requestLifecycle: nil,
                hasSubmittedQuestion: false,
                hasAssistantContent: false
            ),
            .initialSheet
        )
        XCTAssertEqual(
            CourseFocusedQAState.project(
                requestLifecycle: .optimistic,
                hasSubmittedQuestion: true,
                hasAssistantContent: false
            ),
            .thinking
        )
        XCTAssertEqual(
            CourseFocusedQAState.project(
                requestLifecycle: nil,
                hasSubmittedQuestion: true,
                hasAssistantContent: false
            ),
            .thinking
        )
        XCTAssertEqual(
            CourseFocusedQAState.project(
                requestLifecycle: .streaming,
                hasSubmittedQuestion: true,
                hasAssistantContent: true
            ),
            .answer
        )
        XCTAssertEqual(
            CourseFocusedQAState.project(
                requestLifecycle: nil,
                hasSubmittedQuestion: true,
                hasAssistantContent: true
            ),
            .answer
        )
    }

    func testHermesRecoveryProgressOnlyReplacesGenericActivityWhileRecoveryIsPending() {
        let activeStates: [(
            CourseHermesRecoveryProvenance.JournalState,
            CourseHermesRecoveryProgressState
        )] = [
            (.submissionIntent, .submissionIntent),
            (.acceptedTurn, .acceptedTurn),
            (.toolLifecyclePending, .toolLifecyclePending),
            (.toolExecuting, .toolExecuting),
            (.toolExecuted, .toolExecuted),
            (.resultSubmitting, .resultSubmitting),
            (.resultSubmitted, .resultSubmitted),
        ]
        for (journalState, expectedProgressState) in activeStates {
            XCTAssertEqual(
                CourseHermesRecoveryProgressPolicy.progressState(
                    for: journalState
                ),
                expectedProgressState
            )
        }

        let progressState = CourseHermesRecoveryProgressPolicy.progressState(
            for: .acceptedTurn
        )
        XCTAssertEqual(progressState, .acceptedTurn)
        XCTAssertTrue(
            CourseHermesRecoveryProgressPolicy.shouldShow(
                progressState: progressState,
                hasDisplayedError: false,
                isStopping: false
            )
        )
        XCTAssertFalse(
            CourseHermesRecoveryProgressPolicy.shouldShow(
                progressState: nil,
                hasDisplayedError: false,
                isStopping: false
            )
        )
        XCTAssertFalse(
            CourseHermesRecoveryProgressPolicy.shouldShow(
                progressState: progressState,
                hasDisplayedError: true,
                isStopping: false
            )
        )
        XCTAssertFalse(
            CourseHermesRecoveryProgressPolicy.shouldShow(
                progressState: progressState,
                hasDisplayedError: false,
                isStopping: true
            )
        )
    }

    func testTerminalAndUnreadableHermesEvidenceRemainBlockingErrors() {
        for state in [
            CourseHermesRecoveryProvenance.JournalState.terminalFailure,
            .unreadableEvidence,
        ] {
            XCTAssertNil(
                CourseHermesRecoveryProgressPolicy.progressState(for: state)
            )
            XCTAssertNotNil(
                CourseHermesRecoveryProgressPolicy.blockingErrorMessage(for: state)
            )
        }

        XCTAssertFalse(
            CourseHermesRecoveryProgressPolicy.allowsErrorDismissal(
                hasRecoveryPresentation: true
            )
        )
        XCTAssertTrue(
            CourseHermesRecoveryProgressPolicy.allowsErrorDismissal(
                hasRecoveryPresentation: false
            )
        )

        XCTAssertEqual(
            CourseHermesRecoveryProgressPolicy.availableActions(
                for: .terminalFailure
            ),
            [.abandon]
        )
        XCTAssertEqual(
            CourseHermesRecoveryProgressPolicy.availableActions(
                for: .unreadableEvidence
            ),
            [.retry, .abandon]
        )
        XCTAssertEqual(
            CourseHermesRecoveryProgressPolicy.availableActions(
                for: .resultSubmitting
            ),
            [.abandon],
            "An active recovery offers Stop, never Retry."
        )
        XCTAssertEqual(
            CourseHermesRecoveryProgressPolicy.correlationLabel(
                for: .terminalFailure
            ),
            "Correlation · Retained privately until recovery is abandoned"
        )
        XCTAssertEqual(
            CourseHermesRecoveryProgressPolicy.blockingErrorMessage(
                for: .terminalFailure
            ),
            "Hermes recovery could not finish. Your draft, course workspace, and recovery evidence are preserved. Resolve this recovery to continue with the preserved workspace."
        )
        XCTAssertEqual(
            CourseHermesRecoveryProgressPolicy.blockingErrorMessage(
                for: .unreadableEvidence
            ),
            "Hermes recovery evidence could not be read safely. Your draft and course workspace remain protected. Retry recovery or resolve it without losing the evidence."
        )
    }

    func testBlockingHermesEvidenceNeverProjectsActiveWorkAndUsesResolutionCopy() {
        for journalState in [
            CourseHermesRecoveryProvenance.JournalState.terminalFailure,
            .unreadableEvidence,
        ] {
            let interactionState =
                CourseHermesRecoveryProgressPolicy.interactionState(
                    for: journalState
                )
            XCTAssertEqual(interactionState, .blocking)
            XCTAssertFalse(interactionState.contributesActiveWork)
            XCTAssertTrue(interactionState.blocksNewSubmission)
            XCTAssertTrue(
                CourseHermesRecoveryProgressPolicy.usesResolutionCopy(
                    for: journalState
                )
            )
            XCTAssertFalse(
                CourseChatTimelinePolicy.isAgentWorking(
                    requestPending: true,
                    threadHasActiveTurn: true,
                    usesDurableHermesLifecycle: true,
                    durableHermesRecoveryPending: false,
                    durableHermesRecoveryBlocksActivity: true
                ),
                "Blocking recovery must override stale run or thread activity."
            )
            XCTAssertNil(
                CourseRequestLifecycle.project(
                    runPhase: .idle,
                    isAgentWorking: false,
                    hasAssistantContent: false,
                    isReconnecting: false
                )
            )
        }
    }

    func testActiveHermesEvidenceProjectsWorkBlocksNewSubmissionAndCannotRetry() {
        let interactionState =
            CourseHermesRecoveryProgressPolicy.interactionState(
                for: .resultSubmitting
            )
        XCTAssertEqual(interactionState, .active(.resultSubmitting))
        XCTAssertTrue(interactionState.contributesActiveWork)
        XCTAssertTrue(interactionState.blocksNewSubmission)
        XCTAssertTrue(
            CourseChatTimelinePolicy.isAgentWorking(
                requestPending: false,
                threadHasActiveTurn: false,
                usesDurableHermesLifecycle: true,
                durableHermesRecoveryPending: true,
                durableHermesRecoveryBlocksActivity: false
            )
        )
        XCTAssertEqual(
            CourseHermesRecoveryProgressPolicy.availableActions(
                for: .resultSubmitting
            ),
            [.abandon]
        )
        XCTAssertFalse(
            CourseHermesRecoveryProgressPolicy.usesResolutionCopy(
                for: .resultSubmitting
            )
        )
    }

    func testMissingBoundThreadRequiresRecoveryAbandonBeforeReplacement() {
        XCTAssertEqual(
            CourseAgentErrorActionPolicy.blockingAction(
                recoveryActions: [.retry, .abandon],
                hasMissingBoundThread: true
            ),
            .recovery(allowsRetry: false),
            "A missing bound thread cannot be retried and must resolve its durable recovery before replacement."
        )
        XCTAssertEqual(
            CourseAgentErrorActionPolicy.blockingAction(
                recoveryActions: [.retry, .abandon],
                hasMissingBoundThread: false
            ),
            .recovery(allowsRetry: true)
        )
        XCTAssertEqual(
            CourseAgentErrorActionPolicy.blockingAction(
                recoveryActions: [],
                hasMissingBoundThread: true
            ),
            .missingThread,
            "Close & Start New must become available after recovery is abandoned."
        )
        XCTAssertEqual(
            CourseAgentErrorActionPolicy.blockingAction(
                recoveryActions: [],
                hasMissingBoundThread: false
            ),
            .none
        )
    }

    func testPartialDraftDeletionOnlyOffersFinishDeletionRecovery() {
        XCTAssertEqual(
            CourseAgentErrorActionPolicy.blockingAction(
                recoveryActions: [.retry, .abandon],
                hasMissingBoundThread: false,
                abandonMode: .finishDraftDeletion
            ),
            .recovery(allowsRetry: false),
            "Marker-backed cleanup must never expose Retry or a workspace-preservation path."
        )
        XCTAssertEqual(
            CourseAgentErrorActionPolicy.blockingAction(
                recoveryActions: [],
                hasMissingBoundThread: false,
                abandonMode: .finishDraftDeletion
            ),
            .recovery(allowsRetry: false),
            "The durable cleanup marker must keep the finish action visible even after live journals are gone."
        )
        XCTAssertEqual(
            CourseHermesRecoveryProgressPolicy.blockingErrorMessage(
                for: .terminalFailure,
                abandonMode: .finishDraftDeletion
            ),
            "Recovery evidence is already archived. Review what will be kept, then permanently delete the remaining draft workspace data before starting new messages."
        )
        XCTAssertFalse(
            CourseHermesRecoveryProgressPolicy.usesResolutionCopy(
                for: .terminalFailure,
                abandonMode: .finishDraftDeletion
            )
        )
    }

    func testSourceAttachmentAccessibilityKindsMatchCheckpointStates() {
        XCTAssertEqual(
            CourseSourceAttachmentErrorKind.permission.rawValue,
            "permission-error"
        )
        XCTAssertEqual(
            CourseSourceAttachmentErrorKind.parse.rawValue,
            "parse-error"
        )
        XCTAssertEqual(
            CourseSourceAttachmentErrorKind.preparation.rawValue,
            "preparation-error"
        )
    }

    func testSourceAttachmentPresentationClassifiesTypedFailures() {
        let permissionError = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadNoPermission.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Permission denied: /private/learner/secret-notes.pdf",
            ]
        )
        let permission = CourseSourceAttachmentErrorPresentation(
            error: permissionError
        )
        XCTAssertEqual(permission.kind, .permission)
        XCTAssertEqual(
            permission.message,
            CourseSourceAttachmentErrorKind.permission.userMessage
        )
        XCTAssertFalse(permission.message.contains("secret-notes.pdf"))
        XCTAssertFalse(permission.message.contains("/private/"))

        let parse = CourseSourceAttachmentErrorPresentation(
            error: CourseSourceIngestionError.unreadableDocument
        )
        XCTAssertEqual(parse.kind, .parse)
        XCTAssertEqual(
            parse.message,
            CourseSourceAttachmentErrorKind.parse.userMessage
        )

        let preparation = CourseSourceAttachmentErrorPresentation(
            error: CourseSourceIngestionError.setupFailed(
                "Could not write /private/learner/secret-receipt.json"
            )
        )
        XCTAssertEqual(preparation.kind, .preparation)
        XCTAssertEqual(
            preparation.message,
            CourseSourceAttachmentErrorKind.preparation.userMessage
        )
        XCTAssertFalse(preparation.message.contains("secret-receipt.json"))
        XCTAssertFalse(preparation.message.contains("/private/"))
    }
}
