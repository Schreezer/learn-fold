import BackgroundTasks
import XCTest
@testable import Litter

@MainActor
final class ContinuedTurnBackgroundControllerTests: XCTestCase {
    @available(iOS 26.0, *)
    private final class SchedulerSpy: ContinuedProcessingTaskScheduling {
        var registeredIdentifiers: [String] = []
        var submittedRequests: [BGTaskRequest] = []
        var cancelledIdentifiers: [String] = []
        var handlers: [(any ContinuedProcessingTaskHandling) -> Void] = []

        func register(
            identifier: String,
            handler: @escaping (any ContinuedProcessingTaskHandling) -> Void
        ) -> Bool {
            registeredIdentifiers.append(identifier)
            handlers.append(handler)
            return true
        }

        func submit(_ request: BGTaskRequest) throws {
            submittedRequests.append(request)
        }

        func cancel(identifier: String) {
            cancelledIdentifiers.append(identifier)
        }
    }

    @available(iOS 26.0, *)
    private final class TaskSpy: ContinuedProcessingTaskHandling {
        let progress = Progress(totalUnitCount: 0)
        var expirationHandler: (() -> Void)?
        var titles: [(title: String, subtitle: String)] = []
        var completions: [Bool] = []

        func updateTitle(_ title: String, subtitle: String) {
            titles.append((title, subtitle))
        }

        func setTaskCompleted(success: Bool) {
            completions.append(success)
        }
    }

    func testSubmitsAndCancelsAUserInitiatedContinuedProcessingTask() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { nil },
            onExpiration: { _ in XCTFail("The freshly submitted test task should not expire") }
        )
        let key = ThreadKey(serverId: "background-test", threadId: UUID().uuidString)

        let token = controller.beginUserInitiatedTurn(
            key: key,
            title: "Background test",
            agentName: "Codex",
            keepsAliveAcrossTurns: false
        )

        XCTAssertNotNil(token)
        XCTAssertTrue(controller.hasScheduledOrRunningTasks)
        XCTAssertEqual(scheduler.registeredIdentifiers.count, 1)
        XCTAssertEqual(scheduler.submittedRequests.count, 1)
        XCTAssertTrue(scheduler.registeredIdentifiers[0].hasPrefix("com.example.course.codex-turn."))

        if let token {
            controller.markTurnStartFailed(token)
        }
        XCTAssertFalse(controller.hasScheduledOrRunningTasks)
        XCTAssertEqual(scheduler.cancelledIdentifiers, scheduler.registeredIdentifiers)
    }

    func testHermesMultiTurnSessionReusesLeaseAcrossIdleAndClosesOnce() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "hermes-server", threadId: "hermes-thread")
        var snapshot = makeSnapshot(key: key, hasActiveTurn: false)
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") }
        )

        let firstToken = controller.beginUserInitiatedTurn(
            key: key,
            title: "Build a course",
            agentName: "Hermes",
            keepsAliveAcrossTurns: true
        )
        XCTAssertNotNil(firstToken)
        XCTAssertEqual(scheduler.submittedRequests.count, 1)

        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()
        if let firstToken {
            controller.markTurnAccepted(firstToken)
        }

        snapshot = makeSnapshot(key: key, hasActiveTurn: true)
        controller.handleSnapshot(snapshot)
        snapshot = makeSnapshot(key: key, hasActiveTurn: false)
        controller.handleSnapshot(snapshot)
        XCTAssertTrue(controller.hasScheduledOrRunningTasks)
        XCTAssertEqual(task.completions, [])

        let reusedToken = controller.beginUserInitiatedTurn(
            key: key,
            title: "Return a native tool result",
            agentName: "Hermes",
            keepsAliveAcrossTurns: true
        )
        XCTAssertEqual(reusedToken, firstToken)
        XCTAssertEqual(scheduler.submittedRequests.count, 1)
        if let reusedToken {
            controller.markTurnStartFailed(reusedToken)
        }
        XCTAssertTrue(controller.hasScheduledOrRunningTasks)
        XCTAssertEqual(task.completions, [])

        controller.finishMultiTurnSession(key: key, success: true)
        controller.finishMultiTurnSession(key: key, success: true)
        XCTAssertFalse(controller.hasScheduledOrRunningTasks)
        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(task.titles.last?.title, "Hermes finished")
    }

    func testHermesMultiTurnExpirationClosesAndInterruptsExactlyOnce() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "hermes-server", threadId: "hermes-thread")
        let scheduler = SchedulerSpy()
        var expiredKeys: [ThreadKey] = []
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { self.makeSnapshot(key: key, hasActiveTurn: true) },
            onExpiration: { expiredKeys.append($0) }
        )
        _ = controller.beginUserInitiatedTurn(
            key: key,
            title: "Build a course",
            agentName: "Hermes",
            keepsAliveAcrossTurns: true
        )
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()

        task.expirationHandler?()
        await Task.yield()
        task.expirationHandler?()
        await Task.yield()

        XCTAssertEqual(expiredKeys, [key])
        XCTAssertEqual(task.completions, [false])
        XCTAssertFalse(controller.hasScheduledOrRunningTasks)
    }

    func testAutomaticContinuationOnlyReusesAnExistingLease() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "hermes-server", threadId: "hermes-thread")
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { nil },
            onExpiration: { _ in XCTFail("The task should not expire") }
        )

        XCTAssertNil(
            controller.reuseMultiTurnSessionIfPresent(key: key, agentName: "Hermes")
        )
        XCTAssertTrue(scheduler.registeredIdentifiers.isEmpty)
        XCTAssertTrue(scheduler.submittedRequests.isEmpty)

        let created = controller.beginUserInitiatedTurn(
            key: key,
            title: "Build a course",
            agentName: "Hermes",
            keepsAliveAcrossTurns: true
        )
        let reused = controller.reuseMultiTurnSessionIfPresent(
            key: key,
            agentName: "Hermes"
        )
        XCTAssertEqual(reused, created)
        XCTAssertEqual(scheduler.registeredIdentifiers.count, 1)
        XCTAssertEqual(scheduler.submittedRequests.count, 1)
    }

    private func makeSnapshot(key: ThreadKey, hasActiveTurn: Bool) -> AppSnapshotRecord {
        let thread = AppThreadSnapshot(
            key: key,
            info: ThreadInfo(
                id: key.threadId,
                title: "Hermes course",
                model: nil,
                status: hasActiveTurn ? .active : .idle,
                preview: "",
                cwd: "/__learnfold_device_owned__/workspace",
                path: nil,
                modelProvider: nil,
                agentNickname: nil,
                agentRole: nil,
                parentThreadId: nil,
                forkedFromId: nil,
                agentStatus: nil,
                createdAt: nil,
                updatedAt: nil
            ),
            agentRuntimeKind: "hermes",
            collaborationMode: .default,
            model: nil,
            reasoningEffort: nil,
            effectiveApprovalPolicy: nil,
            effectiveSandboxPolicy: nil,
            hydratedConversationItems: [],
            queuedFollowUps: [],
            activeTurnId: hasActiveTurn ? "turn-active" : nil,
            activePlanProgress: nil,
            pendingPlanImplementationPrompt: nil,
            contextTokensUsed: nil,
            modelContextWindow: nil,
            rateLimits: nil,
            realtimeSessionId: nil,
            goal: nil,
            stats: nil,
            tokenUsage: nil,
            olderTurnsCursor: nil,
            initialTurnsLoaded: true
        )
        return AppSnapshotRecord(
            servers: [],
            threads: [thread],
            sessionSummaries: [],
            agentDirectoryVersion: 0,
            activeThread: nil,
            pendingApprovals: [],
            pendingUserInputs: [],
            voiceSession: AppVoiceSessionSnapshot(
                activeThread: nil,
                sessionId: nil,
                phase: nil,
                lastError: nil,
                transcriptEntries: [],
                handoffThreadKey: nil
            ),
            terminalSessions: [],
            activeTerminalId: nil
        )
    }
}
