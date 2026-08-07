import XCTest
@testable import Litter

@MainActor
final class HermesPairingLifecycleCoordinatorTests: XCTestCase {
    func testTransientPollFailureRetainsRequestAndRetriesWithBoundedBackoff() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let request = makeRequest(id: "request-1", now: now)
        let host = HermesPairingStatus.Host(name: "Aeon", nodeId: "node-1")
        let broker = HermesPairingBrokerStub(
            created: [request],
            statuses: [
                .failure(.offline),
                .failure(.server),
                .success(HermesPairingStatus(state: "ready", expiresAt: request.expiresAt, host: host))
            ]
        )
        let store = HermesPairingMemoryStore()
        let delays = HermesPairingDelayRecorder()
        let coordinator = HermesPairingLifecycleCoordinator(
            broker: broker,
            store: store,
            retryPolicy: HermesPairingRetryPolicy(delays: [.seconds(1), .seconds(3)]),
            now: { now },
            sleep: { duration in await delays.record(duration) }
        )

        _ = try await coordinator.createRequest(installationId: "installation")
        await waitUntil { coordinator.phase == .ready }

        let recordedDelays = await delays.values()
        XCTAssertEqual(coordinator.request, request)
        XCTAssertEqual(coordinator.readyHost, host)
        XCTAssertEqual(recordedDelays, [.seconds(1), .seconds(3)])
        XCTAssertEqual(store.saved, request)
    }

    func testPauseAndRestoreRetainTheSameUnexpiredKeychainRecord() async {
        let now = Date(timeIntervalSince1970: 2_000)
        let request = makeRequest(id: "restored", now: now)
        let store = HermesPairingMemoryStore(saved: request)
        let broker = HermesPairingBrokerStub(
            statuses: [.success(HermesPairingStatus(state: "waiting", expiresAt: request.expiresAt, host: nil))]
        )
        let coordinator = HermesPairingLifecycleCoordinator(
            broker: broker,
            store: store,
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )

        coordinator.restoreAndResume()
        await waitUntil { coordinator.phase == .polling }
        coordinator.pause()

        XCTAssertEqual(coordinator.phase, .paused)
        XCTAssertEqual(coordinator.request, request)
        XCTAssertEqual(store.saved, request)

        coordinator.resume()
        XCTAssertEqual(coordinator.phase, .polling)
        XCTAssertEqual(coordinator.request?.requestId, "restored")
        coordinator.pause()
    }

    func testExpiredRestoreClearsWithoutPolling() async {
        let now = Date(timeIntervalSince1970: 3_000)
        let expired = HermesPairingRequest(
            requestId: "expired",
            submitURL: URL(string: "https://example.com/expired")!,
            claimToken: "secret",
            expiresAt: now.addingTimeInterval(-1)
        )
        let store = HermesPairingMemoryStore(saved: expired)
        let broker = HermesPairingBrokerStub()
        let coordinator = HermesPairingLifecycleCoordinator(
            broker: broker,
            store: store,
            now: { now }
        )

        coordinator.restoreAndResume()

        let statusCallCount = await broker.statusCallCount()
        XCTAssertNil(coordinator.request)
        XCTAssertNil(store.saved)
        XCTAssertEqual(statusCallCount, 0)
    }

    func testBrokerTerminalExpiryClearsPersistedRequest() async throws {
        let now = Date(timeIntervalSince1970: 3_500)
        let request = makeRequest(id: "broker-expired", now: now)
        let store = HermesPairingMemoryStore()
        let broker = HermesPairingBrokerStub(
            created: [request],
            statuses: [.expired]
        )
        let coordinator = HermesPairingLifecycleCoordinator(
            broker: broker,
            store: store,
            now: { now },
            sleep: { _ in await Task.yield() }
        )

        _ = try await coordinator.createRequest(installationId: "installation")
        await waitUntil { coordinator.request == nil }

        XCTAssertNil(store.saved)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testReplacementRejectsStaleCompletionIdentity() async throws {
        let now = Date(timeIntervalSince1970: 4_000)
        let first = makeRequest(id: "first", now: now)
        let second = makeRequest(id: "second", now: now)
        let ready = HermesPairingStatus(
            state: "ready",
            expiresAt: second.expiresAt,
            host: HermesPairingStatus.Host(name: "New Host", nodeId: "new-node")
        )
        let broker = HermesPairingBrokerStub(
            created: [first, second],
            statuses: [.success(ready), .success(ready)]
        )
        let coordinator = HermesPairingLifecycleCoordinator(
            broker: broker,
            store: HermesPairingMemoryStore(),
            now: { now },
            sleep: { _ in await Task.yield() }
        )

        _ = try await coordinator.createRequest(installationId: "installation")
        _ = try await coordinator.createRequest(installationId: "installation")

        XCTAssertFalse(coordinator.acceptsCompletion(for: first.requestId))
        XCTAssertTrue(coordinator.acceptsCompletion(for: second.requestId))
        XCTAssertEqual(coordinator.request, second)
    }

    func testTransientClaimFailureKeepsRequestUntilCompletedConnection() async throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let request = makeRequest(id: "claim", now: now)
        let host = HermesPairingStatus.Host(name: "Hermes Mac", nodeId: "node")
        let broker = HermesPairingBrokerStub(
            created: [request],
            statuses: [
                .success(HermesPairingStatus(state: "ready", expiresAt: request.expiresAt, host: host))
            ],
            claims: [.failure(.offline), .success(#"{"v":1}"#)]
        )
        let store = HermesPairingMemoryStore()
        let coordinator = HermesPairingLifecycleCoordinator(
            broker: broker,
            store: store,
            now: { now },
            sleep: { _ in await Task.yield() }
        )

        _ = try await coordinator.createRequest(installationId: "installation")
        await waitUntil { coordinator.phase == .ready }

        let firstClaim = await coordinator.claim()
        XCTAssertNil(firstClaim)
        XCTAssertEqual(coordinator.request, request)
        XCTAssertEqual(store.saved, request)
        XCTAssertEqual(coordinator.phase, .ready)

        let secondClaim = await coordinator.claim()
        XCTAssertEqual(secondClaim?.requestID, request.requestId)
        XCTAssertEqual(secondClaim?.payload, #"{"v":1}"#)
        XCTAssertEqual(coordinator.phase, .claimed)
        XCTAssertEqual(coordinator.request, request)
        XCTAssertEqual(store.saved, request)

        XCTAssertTrue(coordinator.completeConnection(requestID: request.requestId))
        await waitUntilAsync { await broker.cancelledRequestIDs() == [request.requestId] }
        let cancelledRequestIDs = await broker.cancelledRequestIDs()
        XCTAssertNil(coordinator.request)
        XCTAssertNil(store.saved)
        XCTAssertEqual(cancelledRequestIDs, [request.requestId])
    }

    func testClaimedAndPausedReadyRequestRemainReviewableForRecovery() async throws {
        let now = Date(timeIntervalSince1970: 5_500)
        let request = makeRequest(id: "recoverable-claim", now: now)
        let host = HermesPairingStatus.Host(name: "Hermes Mac", nodeId: "node")
        let broker = HermesPairingBrokerStub(
            created: [request],
            statuses: [
                .success(HermesPairingStatus(state: "ready", expiresAt: request.expiresAt, host: host))
            ],
            claims: [.success(#"{"v":1}"#)]
        )
        let coordinator = HermesPairingLifecycleCoordinator(
            broker: broker,
            store: HermesPairingMemoryStore(),
            now: { now },
            sleep: { _ in await Task.yield() }
        )

        _ = try await coordinator.createRequest(installationId: "installation")
        await waitUntil { coordinator.phase == .ready }
        XCTAssertTrue(coordinator.canReviewReadyPairing)

        coordinator.pause()
        XCTAssertEqual(coordinator.phase, .paused)
        XCTAssertTrue(coordinator.canReviewReadyPairing)

        coordinator.resume()
        XCTAssertEqual(coordinator.phase, .ready)
        _ = await coordinator.claim()
        XCTAssertEqual(coordinator.phase, .claimed)
        XCTAssertTrue(coordinator.canReviewReadyPairing)
    }

    func testDelayedConnectionAAndQRCompletionCannotClearReplacementB() async throws {
        let now = Date(timeIntervalSince1970: 6_000)
        let first = makeRequest(id: "A", now: now)
        let second = makeRequest(id: "B", now: now)
        let broker = HermesPairingBrokerStub(created: [first, second])
        let store = HermesPairingMemoryStore()
        let coordinator = HermesPairingLifecycleCoordinator(
            broker: broker,
            store: store,
            now: { now }
        )

        coordinator.pause()
        _ = try await coordinator.createRequest(installationId: "installation")
        _ = try await coordinator.createRequest(installationId: "installation")

        XCTAssertFalse(coordinator.completeConnection(requestID: first.requestId))
        XCTAssertEqual(coordinator.request, second)
        XCTAssertEqual(store.saved, second)

        XCTAssertFalse(coordinator.completeConnection(requestID: nil))
        XCTAssertEqual(coordinator.request, second)
        XCTAssertEqual(store.saved, second)
    }

    func testFailedReplacementRetainsExistingRequestAndToken() async throws {
        let now = Date(timeIntervalSince1970: 7_000)
        let first = makeRequest(id: "A", now: now)
        let second = makeRequest(id: "B", now: now)
        let broker = HermesPairingBrokerStub(created: [first, second])
        let store = HermesPairingMemoryStore()
        let coordinator = HermesPairingLifecycleCoordinator(
            broker: broker,
            store: store,
            now: { now }
        )

        coordinator.pause()
        _ = try await coordinator.createRequest(installationId: "installation")
        store.failSaveRequestIDs.insert(second.requestId)

        do {
            _ = try await coordinator.createRequest(installationId: "installation")
            XCTFail("Expected replacement persistence to fail")
        } catch {}

        let cancelled = await broker.cancelledRequestIDs()
        XCTAssertEqual(coordinator.request, first)
        XCTAssertEqual(store.saved, first)
        XCTAssertTrue(coordinator.statusMessage.contains("existing prompt is still valid"))
        XCTAssertEqual(cancelled, [second.requestId])
    }

    func testClearFailureRetainsPendingStateAndDoesNotAcknowledgeBroker() async throws {
        let now = Date(timeIntervalSince1970: 8_000)
        let request = makeRequest(id: "clear-failure", now: now)
        let broker = HermesPairingBrokerStub(created: [request])
        let store = HermesPairingMemoryStore()
        let coordinator = HermesPairingLifecycleCoordinator(
            broker: broker,
            store: store,
            now: { now }
        )

        coordinator.pause()
        _ = try await coordinator.createRequest(installationId: "installation")
        store.failClear = true

        XCTAssertFalse(coordinator.completeConnection(requestID: request.requestId))
        let cancelled = await broker.cancelledRequestIDs()
        XCTAssertEqual(coordinator.request, request)
        XCTAssertEqual(store.saved, request)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(cancelled, [])
    }

    func testPauseDuringCreateInstallsRequestPausedUntilResume() async throws {
        let now = Date(timeIntervalSince1970: 9_000)
        let request = makeRequest(id: "created-in-background", now: now)
        let broker = HermesPairingCreationGateBroker(request: request)
        let coordinator = HermesPairingLifecycleCoordinator(
            broker: broker,
            store: HermesPairingMemoryStore(),
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )

        let creation = Task { try await coordinator.createRequest(installationId: "installation") }
        await waitUntil { coordinator.isCreating }
        coordinator.pause()
        await broker.releaseCreation()
        _ = try await creation.value

        let pausedStatusCalls = await broker.statusCallCount()
        XCTAssertEqual(coordinator.phase, .paused)
        XCTAssertEqual(pausedStatusCalls, 0)

        coordinator.resume()
        await waitUntilAsync { await broker.statusCallCount() == 1 }
        coordinator.pause()
    }

    func testCredentialPersistenceFailurePolicyDoesNotAuthorizeCompletion() {
        var saveWasAttempted = false

        let result = HermesPairingConnectionCommitPolicy.persistCredential(
            token: "secret",
            nodeID: "node"
        ) { _, _ in
            saveWasAttempted = true
            throw HermesPairingTestStoreError.writeFailed
        }

        XCTAssertTrue(saveWasAttempted)
        if case .success = result {
            XCTFail("A failed durable credential save must not authorize completion")
        }
    }

    func testMatchingCompletionClearsLocallyBeforeBestEffortBrokerAck() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let request = makeRequest(id: "complete", now: now)
        let broker = HermesPairingBrokerStub(created: [request])
        let store = HermesPairingMemoryStore()
        let coordinator = HermesPairingLifecycleCoordinator(
            broker: broker,
            store: store,
            now: { now }
        )

        coordinator.pause()
        _ = try await coordinator.createRequest(installationId: "installation")

        XCTAssertTrue(coordinator.completeConnection(requestID: request.requestId))
        XCTAssertNil(coordinator.request)
        XCTAssertNil(store.saved)
        await waitUntilAsync { await broker.cancelledRequestIDs() == [request.requestId] }
    }

    private func makeRequest(id: String, now: Date) -> HermesPairingRequest {
        HermesPairingRequest(
            requestId: id,
            submitURL: URL(string: "https://example.com/\(id)")!,
            claimToken: "token-\(id)",
            expiresAt: now.addingTimeInterval(300)
        )
    }

    private func waitUntil(
        attempts: Int = 100,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached")
    }

    private func waitUntilAsync(
        attempts: Int = 100,
        _ condition: @escaping () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Async condition was not reached")
    }
}

private enum HermesPairingStubError: Error, Sendable {
    case offline
    case server
}

private enum HermesPairingStatusStep: Sendable {
    case success(HermesPairingStatus)
    case failure(HermesPairingStubError)
    case expired
}

private enum HermesPairingClaimStep: Sendable {
    case success(String)
    case failure(HermesPairingStubError)
}

private enum HermesPairingTestStoreError: Error {
    case writeFailed
    case clearFailed
}

private actor HermesPairingBrokerStub: HermesPairingBrokerServing {
    private var created: [HermesPairingRequest]
    private var statuses: [HermesPairingStatusStep]
    private var claims: [HermesPairingClaimStep]
    private var statusCalls = 0
    private var cancelled: [String] = []

    init(
        created: [HermesPairingRequest] = [],
        statuses: [HermesPairingStatusStep] = [],
        claims: [HermesPairingClaimStep] = []
    ) {
        self.created = created
        self.statuses = statuses
        self.claims = claims
    }

    func createRequest(installationId: String) async throws -> HermesPairingRequest {
        guard !created.isEmpty else { throw HermesPairingStubError.server }
        return created.removeFirst()
    }

    func status(for pairing: HermesPairingRequest) async throws -> HermesPairingStatus {
        statusCalls += 1
        guard !statuses.isEmpty else { throw HermesPairingStubError.offline }
        switch statuses.removeFirst() {
        case let .success(status):
            return status
        case let .failure(error):
            throw error
        case .expired:
            throw HermesPairingBrokerError.expired
        }
    }

    func claim(_ pairing: HermesPairingRequest) async throws -> String {
        guard !claims.isEmpty else { throw HermesPairingStubError.server }
        switch claims.removeFirst() {
        case let .success(payload):
            return payload
        case let .failure(error):
            throw error
        }
    }

    func cancel(_ pairing: HermesPairingRequest) async {
        cancelled.append(pairing.requestId)
    }

    func statusCallCount() -> Int {
        statusCalls
    }

    func cancelledRequestIDs() -> [String] {
        cancelled
    }
}

private final class HermesPairingMemoryStore: HermesPairingPendingStoring {
    var saved: HermesPairingRequest?
    var failSaveRequestIDs: Set<String> = []
    var failClear = false

    init(saved: HermesPairingRequest? = nil) {
        self.saved = saved
    }

    func load() throws -> HermesPairingRequest? {
        saved
    }

    func save(_ request: HermesPairingRequest) throws {
        if failSaveRequestIDs.contains(request.requestId) {
            throw HermesPairingTestStoreError.writeFailed
        }
        saved = request
    }

    func clear() throws {
        if failClear {
            throw HermesPairingTestStoreError.clearFailed
        }
        saved = nil
    }
}

private actor HermesPairingCreationGateBroker: HermesPairingBrokerServing {
    private let request: HermesPairingRequest
    private var creationContinuation: CheckedContinuation<HermesPairingRequest, Never>?
    private var releaseRequested = false
    private var statusCalls = 0

    init(request: HermesPairingRequest) {
        self.request = request
    }

    func createRequest(installationId: String) async throws -> HermesPairingRequest {
        if releaseRequested {
            return request
        }
        return await withCheckedContinuation { continuation in
            creationContinuation = continuation
        }
    }

    func releaseCreation() {
        if let creationContinuation {
            creationContinuation.resume(returning: request)
            self.creationContinuation = nil
        } else {
            releaseRequested = true
        }
    }

    func status(for pairing: HermesPairingRequest) async throws -> HermesPairingStatus {
        statusCalls += 1
        return HermesPairingStatus(state: "waiting", expiresAt: pairing.expiresAt, host: nil)
    }

    func claim(_ pairing: HermesPairingRequest) async throws -> String {
        throw HermesPairingStubError.server
    }

    func cancel(_ pairing: HermesPairingRequest) async {}

    func statusCallCount() -> Int {
        statusCalls
    }
}

private actor HermesPairingDelayRecorder {
    private var recorded: [Duration] = []

    func record(_ duration: Duration) {
        recorded.append(duration)
    }

    func values() -> [Duration] {
        recorded
    }
}
