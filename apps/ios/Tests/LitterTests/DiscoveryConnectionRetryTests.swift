import XCTest
import Foundation
@testable import Litter

final class DiscoveryConnectionRetryTests: XCTestCase {
    #if DEBUG
    func testLF16ScenariosUseTheStrictServerLifecycleRouteAndFaultHook() {
        let scenarios: [(
            scenario: ServerLifecycleCheckpointScenario,
            substate: DiscoveryConnectionRetryCheckpointSubstate
        )] = [
            (.lf16FailureAlert, .failureAlert),
            (.lf16PostRetry, .postRetry),
        ]

        for testCase in scenarios {
            XCTAssertEqual(testCase.scenario.route, "--ui-test-server-lifecycle")
            XCTAssertEqual(testCase.scenario.lf16Substate, testCase.substate)
            XCTAssertTrue(testCase.scenario.rawValue.hasPrefix("server-lifecycle-lf16-"))
        }
        XCTAssertEqual(
            DiscoveryConnectionRetryCheckpointAttemptHook.lf16FailOnce.identifier,
            "lf-16-fault-hook"
        )
    }

    func testSimulatorAutoSSHGateRejectsInertOrStrictLaunches() {
        XCTAssertTrue(
            DiscoverySimulatorAutoSSHGate.allowsStart(
                isInertCheckpoint: false,
                strictHarnessActive: false
            )
        )
        XCTAssertFalse(
            DiscoverySimulatorAutoSSHGate.allowsStart(
                isInertCheckpoint: true,
                strictHarnessActive: false
            )
        )
        XCTAssertFalse(
            DiscoverySimulatorAutoSSHGate.allowsStart(
                isInertCheckpoint: false,
                strictHarnessActive: true
            )
        )
        XCTAssertFalse(
            DiscoverySimulatorAutoSSHGate.allowsStart(
                isInertCheckpoint: true,
                strictHarnessActive: true
            )
        )
    }
    #endif

    #if DEBUG
    func testPostRetryEvidenceCallbackIsTypedSynchronousAndSecretSafe() throws {
        let target = ConnectionTarget.sshThenRemote(
            host: "private-jump.example",
            credentials: .password(
                username: "private-user",
                password: "private-password",
                unlockMacosKeychain: false
            )
        )
        let attempt = DiscoveryConnectionAttempt(
            server: makeServer(id: "private-server", host: "private.example"),
            target: target
        )
        var state = DiscoveryConnectionRetryState()
        var events: [String] = []

        XCTAssertTrue(state.begin(attempt))
        XCTAssertTrue(state.fail(attempt, message: "Connection failed"))
        XCTAssertFalse(
            state.transferPostRetryEvidenceReceipt { _ in
                events.append("receipt")
                return true
            }
        )
        let retryAttempt = try XCTUnwrap(state.beginRetry())
        XCTAssertNotEqual(retryAttempt.runID, attempt.runID)
        XCTAssertTrue(state.complete(retryAttempt))

        XCTAssertTrue(
            state.transferPostRetryEvidenceReceipt { receipt in
                events.append("receipt:\(receipt.accessibilityValue):\(receipt.attemptCount)")
                return true
            }
        )
        events.append("selection")

        XCTAssertEqual(events, ["receipt:post-retry:2", "selection"])
        XCTAssertEqual(state.receiptAccessibilityValue, "none")
        XCTAssertNil(state.evidenceReceipt)
        let serialized = [
            state.stateAccessibilityValue,
            state.receiptAccessibilityValue,
            state.evidenceReceipt?.accessibilityValue ?? "",
        ].joined(separator: ";")
        for secret in [
            "private-jump.example",
            "private-user",
            "private-password",
            "private.example",
        ] {
            XCTAssertFalse(serialized.contains(secret))
        }
    }

    @MainActor
    func testAppStateRetainsOnlyTruthfulPostRetryReceiptUntilCleared() throws {
        let appState = AppState()
        let failure = try XCTUnwrap(
            DiscoveryConnectionRetryEvidenceReceipt(
                state: .failureAlert,
                attemptCount: 1
            )
        )
        let postRetry = try XCTUnwrap(
            DiscoveryConnectionRetryEvidenceReceipt(
                state: .postRetry,
                attemptCount: 2
            )
        )

        XCTAssertFalse(
            appState.recordDiscoveryConnectionRetryEvidenceReceipt(failure)
        )
        XCTAssertNil(appState.discoveryConnectionRetryEvidenceReceipt)

        XCTAssertTrue(
            appState.recordDiscoveryConnectionRetryEvidenceReceipt(postRetry)
        )
        XCTAssertEqual(appState.discoveryConnectionRetryEvidenceReceipt, postRetry)
        XCTAssertEqual(
            appState.discoveryConnectionRetryEvidenceReceipt?.accessibilityValue,
            "post-retry"
        )

        appState.clearDiscoveryConnectionRetryEvidenceReceipt()
        XCTAssertNil(appState.discoveryConnectionRetryEvidenceReceipt)
    }

    func testEvidenceReceiptRejectsImpossibleAttemptCounts() {
        XCTAssertNil(
            DiscoveryConnectionRetryEvidenceReceipt(
                state: .failureAlert,
                attemptCount: 0
            )
        )
        XCTAssertNil(
            DiscoveryConnectionRetryEvidenceReceipt(
                state: .retrying,
                attemptCount: 1
            )
        )
        XCTAssertNil(
            DiscoveryConnectionRetryEvidenceReceipt(
                state: .postRetry,
                attemptCount: 1
            )
        )
    }

    @MainActor
    func testDismissAndReopenRejectsTheOldViewsLateResult() {
        let gate = DiscoveryConnectionLifecycleGate()
        var state = DiscoveryConnectionRetryState()
        let dismissedAttempt = DiscoveryConnectionAttempt(
            server: makeServer(id: "dismissed", host: "dismissed.example"),
            target: .remote(host: "dismissed.example", port: 8390)
        )
        let dismissedViewEpoch = gate.activate()
        XCTAssertTrue(gate.isCurrent(dismissedViewEpoch))
        XCTAssertTrue(state.begin(dismissedAttempt))

        gate.invalidate()
        state.abandon()
        XCTAssertFalse(gate.isCurrent(dismissedViewEpoch))
        XCTAssertNil(state.activeAttempt)
        XCTAssertEqual(state.phase, .idle)

        let reopenedViewEpoch = gate.activate()
        XCTAssertNotEqual(reopenedViewEpoch, dismissedViewEpoch)
        let reopenedAttempt = DiscoveryConnectionAttempt(
            server: makeServer(id: "reopened", host: "reopened.example"),
            target: .remote(host: "reopened.example", port: 9443)
        )
        XCTAssertTrue(
            state.begin(reopenedAttempt),
            "The retained DiscoveryView state must accept a new connection after reappearing."
        )
        XCTAssertFalse(state.complete(dismissedAttempt))
        XCTAssertFalse(state.fail(dismissedAttempt, message: "Late failure"))
        XCTAssertEqual(state.activeAttempt, reopenedAttempt)
        var canceledSSHCompletionPersisted = false
        if gate.isCurrent(dismissedViewEpoch) {
            canceledSSHCompletionPersisted = true
        }
        XCTAssertFalse(
            canceledSSHCompletionPersisted,
            "A canceled SSH completion must be rejected before SavedServerStore persistence."
        )
        XCTAssertFalse(
            gate.isCurrent(dismissedViewEpoch),
            "A bridge result from the dismissed view must not publish or navigate into the reopened view."
        )
        XCTAssertTrue(gate.isCurrent(reopenedViewEpoch))
    }

    @MainActor
    func testLF16CheckpointHookFailsOnceThenTransfersReceiptBeforeSelection() async throws {
        let hook = DiscoveryConnectionRetryCheckpointAttemptHook.lf16FailOnce
        let attempt = DiscoveryConnectionAttempt(
            server: makeServer(id: "checkpoint", host: "checkpoint.example"),
            target: .remote(host: "checkpoint.example", port: 8390)
        )
        var state = DiscoveryConnectionRetryState()
        var evidence = DiscoveryConnectionRetryCheckpointEvidence()

        XCTAssertTrue(state.begin(attempt))
        let first = await hook.result(for: attempt, attemptNumber: 1)
        guard case .failure(let message) = first else {
            return XCTFail("The injected hook must deterministically fail its first attempt.")
        }
        XCTAssertTrue(state.fail(attempt, message: message))

        let retry = try XCTUnwrap(state.beginRetry())
        XCTAssertEqual(retry.server, attempt.server)
        XCTAssertEqual(retry.target, attempt.target)
        let second = await hook.result(for: retry, attemptNumber: 2)
        XCTAssertEqual(second, .success)
        XCTAssertTrue(state.complete(retry))
        XCTAssertTrue(
            state.transferPostRetryEvidenceReceipt { receipt in
                evidence.receive(receipt)
            }
        )
        XCTAssertTrue(evidence.recordSelection(serverID: retry.server.id))

        XCTAssertEqual(evidence.receipt?.state, .postRetry)
        XCTAssertEqual(evidence.receipt?.attemptCount, 2)
        XCTAssertEqual(evidence.selectedServerID, retry.server.id)
        XCTAssertEqual(evidence.events, [.receipt, .selection])
        XCTAssertEqual(evidence.eventOrderAccessibilityValue, "receipt>selection")
    }
    #endif

    func testFailurePreservesTheExactExplicitTargetForRetry() throws {
        let server = makeServer(id: "ssh-server", host: "ssh.example")
        let target = ConnectionTarget.sshThenRemote(
            host: "jump.example",
            credentials: .key(
                username: "learner",
                privateKey: "synthetic-private-key",
                passphrase: "synthetic-passphrase"
            )
        )
        let attempt = DiscoveryConnectionAttempt(server: server, target: target)
        var state = DiscoveryConnectionRetryState()

        XCTAssertTrue(state.begin(attempt))
        XCTAssertEqual(state.phase, .connecting)
        XCTAssertEqual(state.attemptCount, 1)
        XCTAssertEqual(
            state.stateAccessibilityValue,
            "phase=connecting;attempt=1"
        )
        XCTAssertEqual(state.receiptAccessibilityValue, "none")
        XCTAssertTrue(state.fail(attempt, message: "Connection failed"))

        XCTAssertEqual(state.failedAttempt, attempt)
        XCTAssertEqual(state.phase, .failureAlert)
        XCTAssertEqual(state.attemptCount, 1)
        XCTAssertEqual(
            state.stateAccessibilityValue,
            "phase=failure-alert;attempt=1"
        )
        XCTAssertEqual(state.receiptAccessibilityValue, "failure-alert")
        let retryAttempt = try XCTUnwrap(state.beginRetry())
        XCTAssertNotEqual(retryAttempt.runID, attempt.runID)
        XCTAssertEqual(retryAttempt.server, attempt.server)
        XCTAssertEqual(retryAttempt.target, attempt.target)
        XCTAssertEqual(state.activeAttempt, retryAttempt)
        XCTAssertEqual(state.phase, .retrying)
        XCTAssertEqual(state.attemptCount, 2)
        XCTAssertEqual(
            state.stateAccessibilityValue,
            "phase=retrying;attempt=2"
        )
        XCTAssertEqual(state.receiptAccessibilityValue, "retrying")

        for secret in [
            "ssh.example",
            "jump.example",
            "learner",
            "synthetic-private-key",
            "synthetic-passphrase",
        ] {
            XCTAssertFalse(state.stateAccessibilityValue.contains(secret))
            XCTAssertFalse(state.receiptAccessibilityValue.contains(secret))
        }
    }

    func testRetryCanFailThenRetryAgainWithoutLosingItsTarget() throws {
        let attempt = DiscoveryConnectionAttempt(
            server: makeServer(id: "remote", host: "codex.example"),
            target: .remote(host: "codex.example", port: 9443)
        )
        var state = DiscoveryConnectionRetryState()

        XCTAssertTrue(state.begin(attempt))
        XCTAssertTrue(state.fail(attempt, message: "First failure"))
        let firstRetry = try XCTUnwrap(state.beginRetry())
        XCTAssertNotEqual(firstRetry.runID, attempt.runID)
        XCTAssertEqual(firstRetry.server, attempt.server)
        XCTAssertEqual(firstRetry.target, attempt.target)
        XCTAssertNil(state.beginRetry(), "A second Retry tap must not start a concurrent attempt.")
        XCTAssertTrue(state.fail(firstRetry, message: "Second failure"))

        XCTAssertTrue(state.canRetry)
        XCTAssertEqual(state.errorMessage, "Second failure")
        XCTAssertEqual(state.phase, .failureAlert)
        XCTAssertEqual(state.attemptCount, 2)
        XCTAssertEqual(
            state.stateAccessibilityValue,
            "phase=failure-alert;attempt=2"
        )
        XCTAssertEqual(state.receiptAccessibilityValue, "failure-alert")
        let secondRetry = try XCTUnwrap(state.beginRetry())
        XCTAssertNotEqual(secondRetry.runID, firstRetry.runID)
        XCTAssertEqual(secondRetry.server, attempt.server)
        XCTAssertEqual(secondRetry.target, attempt.target)
        XCTAssertEqual(state.phase, .retrying)
        XCTAssertEqual(state.attemptCount, 3)
        XCTAssertEqual(
            state.stateAccessibilityValue,
            "phase=retrying;attempt=3"
        )
    }

    func testConcurrentBeginAndRetryAreSuppressedWhileAttemptIsActive() {
        let first = DiscoveryConnectionAttempt(
            server: makeServer(id: "first", host: "first.example"),
            target: .remote(host: "first.example", port: 8390)
        )
        let second = DiscoveryConnectionAttempt(
            server: makeServer(id: "second", host: "second.example"),
            target: .remote(host: "second.example", port: 9234)
        )
        var state = DiscoveryConnectionRetryState()

        XCTAssertTrue(state.begin(first))
        XCTAssertFalse(state.begin(second))
        XCTAssertNil(state.beginRetry())
        XCTAssertEqual(state.activeAttempt, first)

        XCTAssertFalse(state.fail(second, message: "Stale failure"))
        XCTAssertEqual(state.activeAttempt, first)
        XCTAssertNil(state.errorMessage)
    }

    func testSuccessfulRetryClearsFailureAndErrorState() throws {
        let attempt = DiscoveryConnectionAttempt(
            server: makeServer(id: "recovering", host: "recover.example"),
            target: .remoteURL(URL(string: "wss://recover.example/codex")!)
        )
        var state = DiscoveryConnectionRetryState()

        XCTAssertTrue(state.begin(attempt))
        XCTAssertTrue(state.fail(attempt, message: "Temporary outage"))
        let retryAttempt = try XCTUnwrap(state.beginRetry())
        state.dismissError()
        XCTAssertEqual(
            state.activeAttempt,
            retryAttempt,
            "Automatic alert dismissal must not cancel the retry selected by the user."
        )
        XCTAssertTrue(state.complete(retryAttempt))

        XCTAssertNil(state.activeAttempt)
        XCTAssertNil(state.failedAttempt)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.canRetry)
        XCTAssertEqual(state.phase, .postRetry)
        XCTAssertEqual(state.attemptCount, 2)
        XCTAssertEqual(
            state.stateAccessibilityValue,
            "phase=post-retry;attempt=2"
        )
        XCTAssertEqual(state.receiptAccessibilityValue, "post-retry")
    }

    func testLateSameTargetCallbacksCannotMutateTheActiveRetry() throws {
        let initialAttempt = DiscoveryConnectionAttempt(
            server: makeServer(id: "same-target", host: "same.example"),
            target: .remote(host: "same.example", port: 8390)
        )
        var state = DiscoveryConnectionRetryState()

        XCTAssertTrue(state.begin(initialAttempt))
        XCTAssertTrue(state.fail(initialAttempt, message: "First run failed"))
        let retryAttempt = try XCTUnwrap(state.beginRetry())
        XCTAssertNotEqual(retryAttempt.runID, initialAttempt.runID)
        XCTAssertEqual(retryAttempt.server, initialAttempt.server)
        XCTAssertEqual(retryAttempt.target, initialAttempt.target)

        XCTAssertFalse(state.complete(initialAttempt))
        XCTAssertFalse(state.fail(initialAttempt, message: "Late first-run failure"))
        XCTAssertEqual(state.activeAttempt, retryAttempt)
        XCTAssertEqual(state.phase, .retrying)
        XCTAssertEqual(state.attemptCount, 2)
        XCTAssertEqual(state.receiptAccessibilityValue, "retrying")

        XCTAssertTrue(state.complete(retryAttempt))
        XCTAssertEqual(state.phase, .postRetry)
        XCTAssertEqual(state.receiptAccessibilityValue, "post-retry")
    }

    func testDismissAndNonRetryableErrorsDoNotExposeStaleRetry() {
        let attempt = DiscoveryConnectionAttempt(
            server: makeServer(id: "dismissed", host: "dismiss.example"),
            target: .remote(host: "dismiss.example", port: 8390)
        )
        var state = DiscoveryConnectionRetryState()

        XCTAssertTrue(state.begin(attempt))
        XCTAssertTrue(state.fail(attempt, message: "Retryable"))
        state.dismissError()
        XCTAssertFalse(state.canRetry)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.attemptCount, 1)
        XCTAssertEqual(state.receiptAccessibilityValue, "failure-alert")

        XCTAssertTrue(state.presentNonRetryableError("Enter a valid host"))
        XCTAssertEqual(state.errorMessage, "Enter a valid host")
        XCTAssertNil(state.failedAttempt)
        XCTAssertFalse(state.canRetry)
        XCTAssertEqual(state.phase, .nonRetryableError)
        XCTAssertEqual(state.attemptCount, 0)
        XCTAssertEqual(
            state.stateAccessibilityValue,
            "phase=non-retryable-error;attempt=0"
        )
        XCTAssertEqual(
            state.receiptAccessibilityValue,
            "none",
            "A validation alert must not forge an LF-16 retry receipt."
        )
    }

    func testInitialSuccessDoesNotForgePostRetryEvidence() {
        let attempt = DiscoveryConnectionAttempt(
            server: makeServer(id: "first-success", host: "success.example"),
            target: .remote(host: "success.example", port: 8390)
        )
        var state = DiscoveryConnectionRetryState()

        XCTAssertTrue(state.begin(attempt))
        XCTAssertTrue(state.complete(attempt))

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.attemptCount, 0)
        XCTAssertEqual(state.stateAccessibilityValue, "phase=idle;attempt=0")
        XCTAssertEqual(state.receiptAccessibilityValue, "none")
    }

    func testFailurePresentationClassifiesWithoutEchoingRawSecrets() {
        let samples: [(raw: String, expected: String)] = [
            (
                "Unauthorized wss://private-user:private-token@secret.example/session",
                "Authentication failed. Check the server credentials and try again."
            ),
            (
                "Connection timed out for token=private-token at secret.example",
                "The server did not respond. Check that it is online and try again."
            ),
            (
                "Bridge failed: api_key=private-token host=secret.example",
                "Learnfold couldn't connect to this server. Check the connection and try again."
            ),
        ]

        for sample in samples {
            let message = DiscoveryConnectionFailurePresentation.message(
                for: sample.raw
            )
            XCTAssertEqual(message, sample.expected)
            XCTAssertFalse(message.contains("private-user"))
            XCTAssertFalse(message.contains("private-token"))
            XCTAssertFalse(message.contains("secret.example"))
        }
    }

    func testAlreadyTerminalBootstrapSnapshotResolvesImmediately() {
        XCTAssertEqual(
            DiscoveryPendingConnectionResolution.resolve(
                health: .connected,
                terminalMessage: nil
            ),
            .connected
        )
        XCTAssertEqual(
            DiscoveryPendingConnectionResolution.resolve(
                health: .disconnected,
                terminalMessage: "Bootstrap failed"
            ),
            .failed(message: "Bootstrap failed")
        )
        XCTAssertEqual(
            DiscoveryPendingConnectionResolution.resolve(
                health: .disconnected,
                terminalMessage: nil
            ),
            .pending,
            "A non-terminal disconnected projection must still wait for an authoritative terminal message."
        )
        XCTAssertEqual(
            DiscoveryPendingConnectionResolution.resolve(
                health: nil,
                terminalMessage: nil
            ),
            .pending
        )
    }

    func testLiveLifecyclePresentationExposesEveryReachableProductionState() {
        XCTAssertEqual(
            DiscoveryLiveLifecyclePresentation.resolve(
                wakingServerName: "Wake Target",
                connectingServerName: "Connect Target",
                progressDetail: "Starting app server",
                failedServerName: "Failed Target",
                failureMessage: "Connection failed"
            ),
            DiscoveryLiveLifecyclePresentation(
                status: .waking,
                serverName: "Wake Target",
                detail: "Sending a wake request and checking for a reachable service."
            ),
            "Waking must win while the wake probe is the active production operation."
        )

        XCTAssertEqual(
            DiscoveryLiveLifecyclePresentation.resolve(
                wakingServerName: nil,
                connectingServerName: "Connect Target",
                progressDetail: nil,
                failedServerName: nil,
                failureMessage: nil
            )?.status,
            .connecting
        )
        XCTAssertEqual(
            DiscoveryLiveLifecyclePresentation.resolve(
                wakingServerName: nil,
                connectingServerName: "Connect Target",
                progressDetail: "Starting app server",
                failedServerName: nil,
                failureMessage: nil
            ),
            DiscoveryLiveLifecyclePresentation(
                status: .progress,
                serverName: "Connect Target",
                detail: "Starting app server"
            )
        )
        XCTAssertEqual(
            DiscoveryLiveLifecyclePresentation.resolve(
                wakingServerName: nil,
                connectingServerName: nil,
                progressDetail: nil,
                failedServerName: "Failed Target",
                failureMessage: "The server did not respond."
            ),
            DiscoveryLiveLifecyclePresentation(
                status: .disconnected,
                serverName: "Failed Target",
                detail: "The server did not respond."
            )
        )
        XCTAssertNil(
            DiscoveryLiveLifecyclePresentation.resolve(
                wakingServerName: nil,
                connectingServerName: nil,
                progressDetail: "orphaned progress",
                failedServerName: nil,
                failureMessage: nil
            )
        )
    }

    func testGuidedSSHInProgressStepsExposeFallbackDetailsWithoutCollapsingConnecting() {
        let expected: [(AppConnectionStepKind, String)] = [
            (.findingCodex, "Finding Codex on the remote server."),
            (.installingCodex, "Installing Codex on the remote server."),
            (.startingAppServer, "Starting the Codex app server."),
            (.openingTunnel, "Opening a secure tunnel."),
            (.connected, "Finishing the server connection."),
        ]

        XCTAssertNil(
            AppConnectionStepSnapshot(
                kind: .connectingToSsh,
                state: .inProgress,
                detail: nil
            ).connectionProgressPresentationDetail,
            "The initial transport phase must remain the distinct connecting state."
        )

        for (kind, detail) in expected {
            let step = AppConnectionStepSnapshot(
                kind: kind,
                state: .inProgress,
                detail: nil
            )
            XCTAssertEqual(step.connectionProgressPresentationDetail, detail)
            XCTAssertEqual(
                DiscoveryLiveLifecyclePresentation.resolve(
                    wakingServerName: nil,
                    connectingServerName: "Live SSH Target",
                    progressDetail: step.connectionProgressPresentationDetail,
                    failedServerName: nil,
                    failureMessage: nil
                )?.status,
                .progress,
                "Every post-transport in-progress SSH step must reach the live progress marker."
            )
        }

        XCTAssertEqual(
            AppConnectionStepSnapshot(
                kind: .startingAppServer,
                state: .inProgress,
                detail: "Remote supplied detail"
            ).connectionProgressPresentationDetail,
            "Remote supplied detail",
            "An authoritative step detail must win over the presentation fallback."
        )
        XCTAssertNil(
            AppConnectionStepSnapshot(
                kind: .startingAppServer,
                state: .pending,
                detail: nil
            ).connectionProgressPresentationDetail,
            "Pending steps must not be projected as live progress."
        )
    }

    func testFailureStateExposesOnlyTheFailedServerForLivePresentation() throws {
        let attempt = DiscoveryConnectionAttempt(
            server: makeServer(id: "failed", host: "failed.example"),
            target: .remote(host: "failed.example", port: 8390)
        )
        var state = DiscoveryConnectionRetryState()

        XCTAssertNil(state.failedServer)
        XCTAssertTrue(state.begin(attempt))
        XCTAssertNil(state.failedServer)
        XCTAssertTrue(state.fail(attempt, message: "Connection failed"))
        XCTAssertEqual(state.failedServer, attempt.server)
        _ = try XCTUnwrap(state.beginRetry())
        XCTAssertNil(state.failedServer)
    }

    func testSettingsLifecycleProjectionMakesConnectedAndDisconnectedReachable() {
        XCTAssertEqual(SettingsServerLifecycleProjection.resolve([]), "none")
        XCTAssertEqual(SettingsServerLifecycleProjection.resolve([.connected]), "connected")
        XCTAssertEqual(
            SettingsServerLifecycleProjection.resolve([.connected, .disconnected]),
            "disconnected"
        )
        XCTAssertEqual(
            SettingsServerLifecycleProjection.resolve([.connected, .unknown, .connecting]),
            "connecting",
            "An active connection attempt must take precedence over stale saved-server health."
        )
    }

    private func makeServer(id: String, host: String) -> DiscoveredServer {
        DiscoveredServer(
            id: id,
            name: id,
            hostname: host,
            port: 8390,
            codexPorts: [8390],
            source: .manual,
            hasCodexServer: true,
            preferredConnectionMode: .directCodex,
            preferredCodexPort: 8390
        )
    }
}
