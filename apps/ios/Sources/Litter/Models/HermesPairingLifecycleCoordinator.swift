import Combine
import Foundation
import Security

struct HermesPairingRequest: Codable, Equatable, Sendable {
    let requestId: String
    let submitURL: URL
    let claimToken: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case submitURL = "submit_url"
        case claimToken = "claim_token"
        case expiresAt = "expires_at"
    }
}

struct HermesPairingStatus: Decodable, Equatable, Sendable {
    struct Host: Decodable, Equatable, Sendable {
        let name: String?
        let nodeId: String

        enum CodingKeys: String, CodingKey {
            case name
            case nodeId = "node_id"
        }
    }

    let state: String
    let expiresAt: Date
    let host: Host?

    enum CodingKeys: String, CodingKey {
        case state
        case expiresAt = "expires_at"
        case host
    }
}

enum HermesPairingBrokerError: LocalizedError {
    case invalidResponse
    case requestFailed(Int)
    case expired

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The secure pairing service returned an invalid response."
        case let .requestFailed(status):
            return "The secure pairing service could not complete this request (HTTP \(status))."
        case .expired:
            return "This pairing request expired. Copy a new setup prompt and try again."
        }
    }
}

protocol HermesPairingBrokerServing: Sendable {
    func createRequest(installationId: String) async throws -> HermesPairingRequest
    func status(for pairing: HermesPairingRequest) async throws -> HermesPairingStatus
    func claim(_ pairing: HermesPairingRequest) async throws -> String
    func cancel(_ pairing: HermesPairingRequest) async
}

actor HermesPairingBrokerClient: HermesPairingBrokerServing {
    static let shared = HermesPairingBrokerClient(
        baseURL: URL(string: "https://litter-pairing-broker.chiragmgg.workers.dev")!
    )

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: configuration)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func createRequest(installationId: String) async throws -> HermesPairingRequest {
        var request = URLRequest(url: baseURL.appending(path: "v1/pairing-requests"))
        request.httpMethod = "POST"
        request.setValue(installationId, forHTTPHeaderField: "X-Learnfold-Installation")
        let data = try await perform(request, expectedStatus: 201)
        return try decoder.decode(HermesPairingRequest.self, from: data)
    }

    func status(for pairing: HermesPairingRequest) async throws -> HermesPairingStatus {
        var request = URLRequest(
            url: baseURL.appending(path: "v1/pairing-requests/\(pairing.requestId)/status")
        )
        request.setValue("Bearer \(pairing.claimToken)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request)
        return try decoder.decode(HermesPairingStatus.self, from: data)
    }

    func claim(_ pairing: HermesPairingRequest) async throws -> String {
        var request = URLRequest(
            url: baseURL.appending(path: "v1/pairing-requests/\(pairing.requestId)/claim")
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairing.claimToken)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["pairing_payload"],
              JSONSerialization.isValidJSONObject(payload)
        else {
            throw HermesPairingBrokerError.invalidResponse
        }
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw HermesPairingBrokerError.invalidResponse
        }
        return payloadJSON
    }

    func cancel(_ pairing: HermesPairingRequest) async {
        var request = URLRequest(
            url: baseURL.appending(path: "v1/pairing-requests/\(pairing.requestId)/cancel")
        )
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(pairing.claimToken)", forHTTPHeaderField: "Authorization")
        _ = try? await perform(request)
    }

    private func perform(_ request: URLRequest, expectedStatus: Int = 200) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HermesPairingBrokerError.invalidResponse
        }
        guard response.statusCode == expectedStatus else {
            if response.statusCode == 401 || response.statusCode == 410 {
                throw HermesPairingBrokerError.expired
            }
            throw HermesPairingBrokerError.requestFailed(response.statusCode)
        }
        return data
    }
}

protocol HermesPairingPendingStoring {
    func load() throws -> HermesPairingRequest?
    func save(_ request: HermesPairingRequest) throws
    func clear() throws
}

enum HermesPairingPendingStoreError: LocalizedError {
    case invalidData
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "The saved secure pairing request could not be read."
        case let .keychain(status):
            return "Keychain error (\(status))."
        }
    }
}

/// Keychain calls are synchronous and the instance has no mutable state.
final class HermesPairingPendingKeychainStore: HermesPairingPendingStoring, @unchecked Sendable {
    static let shared = HermesPairingPendingKeychainStore()

    private let service: String
    private let account: String

    init(
        service: String = "com.chirag.learnfold.hermes-pairing",
        account: String = "pending-request"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> HermesPairingRequest? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            baseQuery.merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]) { _, new in new } as CFDictionary,
            &item
        )
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw HermesPairingPendingStoreError.invalidData
            }
            do {
                return try JSONDecoder().decode(HermesPairingRequest.self, from: data)
            } catch {
                throw HermesPairingPendingStoreError.invalidData
            }
        case errSecItemNotFound:
            return nil
        default:
            throw HermesPairingPendingStoreError.keychain(status)
        }
    }

    func save(_ request: HermesPairingRequest) throws {
        let data = try JSONEncoder().encode(request)
        let attributes = baseQuery.merging([
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]) { _, new in new }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                ] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw HermesPairingPendingStoreError.keychain(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw HermesPairingPendingStoreError.keychain(status)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HermesPairingPendingStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct HermesPairingRetryPolicy: Equatable {
    let delays: [Duration]

    static let standard = HermesPairingRetryPolicy(
        delays: [.seconds(2), .seconds(4), .seconds(8), .seconds(15)]
    )

    func delay(afterFailureCount count: Int) -> Duration {
        guard !delays.isEmpty else { return .seconds(2) }
        let index = min(max(count - 1, 0), delays.count - 1)
        return delays[index]
    }
}

struct HermesPairingClaimResult: Equatable, Sendable {
    let requestID: String
    let payload: String
}

/// Debug-only, non-live checkpoints for the Learnfold Link pairing views.
/// These values never name a real host and never carry a usable credential.
enum HermesLinkCheckpointScenario: String, CaseIterable {
    case initial, copied, creating, waiting, paused, retrying, expired, renewed
    case review, confirmation, claiming, finishing
    case scanner, cameraDenied = "camera-denied", parseError = "parse-error", validReview = "valid-review"

    static let argument = "--ui-test-hermes-link-checkpoint"

    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self? {
        if case let .scenario(scenario) = HermesLinkCheckpointConfiguration.parse(arguments: arguments) {
            return scenario
        }
        return nil
    }
}

/// A checkpoint is opt-in twice: XCTest must set the test environment and the
/// process must supply exactly one complete checkpoint argument pair.  Any
/// malformed request stays visibly non-live rather than falling through to the
/// production broker.
enum HermesLinkCheckpointConfiguration: Equatable {
    case disabled
    case scenario(HermesLinkCheckpointScenario)
    case invalid

    static func parse(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        let occurrences = arguments.enumerated().filter { $0.element == HermesLinkCheckpointScenario.argument }
        let hasCheckpointShapedToken = arguments.contains {
            $0.hasPrefix("--ui-test-hermes-link") || HermesLinkCheckpointScenario(rawValue: $0) != nil
        }
        guard hasCheckpointShapedToken else { return .disabled }
        guard environment["LEARNFOLD_UI_TESTING"] == "1", occurrences.count == 1,
              let index = occurrences.first?.offset, index + 1 < arguments.count,
              HermesLinkCheckpointScenario(rawValue: arguments[index + 1]) != nil
        else { return .invalid }
        // A scenario may only be expressed as the single value following the flag.
        guard arguments.count == 3,
              index == 1,
              arguments.filter({ HermesLinkCheckpointScenario(rawValue: $0) != nil }).count == 1,
              arguments[index + 1] != HermesLinkCheckpointScenario.argument
        else { return .invalid }
        return .scenario(HermesLinkCheckpointScenario(rawValue: arguments[index + 1])!)
    }
}

actor HermesLinkCheckpointNoopBroker: HermesPairingBrokerServing {
    func createRequest(installationId: String) async throws -> HermesPairingRequest { throw CancellationError() }
    func status(for pairing: HermesPairingRequest) async throws -> HermesPairingStatus { throw CancellationError() }
    func claim(_ pairing: HermesPairingRequest) async throws -> String { throw CancellationError() }
    func cancel(_ pairing: HermesPairingRequest) async {}
}

final class HermesLinkCheckpointNoopStore: HermesPairingPendingStoring {
    func load() throws -> HermesPairingRequest? { nil }
    func save(_ request: HermesPairingRequest) throws {}
    func clear() throws {}
}

enum HermesPairingConnectionCommitPolicy {
    static let credentialPersistenceFailureMessage =
        "The host connected, but Learnfold could not save its credential securely. Try Connect again."

    static func persistCredential(
        token: String,
        nodeID: String,
        using save: (String, String) throws -> Void
    ) -> Result<Void, Error> {
        Result { try save(token, nodeID) }
    }
}

@MainActor
final class HermesPairingLifecycleCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case polling
        case paused
        case ready
        case claiming
        case claimed
    }

    private enum ClearReason {
        case cancelled
        case completed
        case expired

        var requiresNewSetupPrompt: Bool {
            switch self {
            case .expired:
                true
            case .cancelled, .completed:
                false
            }
        }
    }

    @Published private(set) var request: HermesPairingRequest?
    @Published private(set) var readyHost: HermesPairingStatus.Host?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusMessage = "Create a secure request, then paste the prompt into Hermes."
    @Published private(set) var errorMessage: String?
    @Published private(set) var isCreating = false
    @Published private(set) var requiresNewSetupPrompt = false

    var canReviewReadyPairing: Bool {
        request != nil && readyHost != nil && phase == .ready
    }

    var shouldCopyNewSetupPrompt: Bool {
        requiresNewSetupPrompt
    }

    private let broker: any HermesPairingBrokerServing
    private let store: any HermesPairingPendingStoring
    private let retryPolicy: HermesPairingRetryPolicy
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pollingTask: Task<Void, Never>?
    private var creationID: UUID?
    private var shouldPoll = true

    private let checkpointScenario: HermesLinkCheckpointScenario?

    init(
        broker: any HermesPairingBrokerServing = HermesPairingBrokerClient.shared,
        store: any HermesPairingPendingStoring = HermesPairingPendingKeychainStore.shared,
        retryPolicy: HermesPairingRetryPolicy = .standard,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        checkpointScenario: HermesLinkCheckpointScenario? = nil,
        checkpointIsolated: Bool = false
    ) {
        self.broker = broker
        self.store = store
        self.retryPolicy = retryPolicy
        self.now = now
        self.sleep = sleep
        self.checkpointScenario = checkpointScenario
        self.checkpointIsolated = checkpointIsolated
        #if DEBUG
        installCheckpointIfNeeded()
        #endif
    }

    var debugCheckpointScenario: HermesLinkCheckpointScenario? { checkpointScenario }
    private let checkpointIsolated: Bool

    #if DEBUG
    private func installCheckpointIfNeeded() {
        guard let checkpointScenario else { return }
        let request = HermesPairingRequest(
            requestId: "REDACTED-REQUEST",
            submitURL: URL(string: "https://example.invalid/redacted")!,
            claimToken: "REDACTED",
            expiresAt: now().addingTimeInterval(600)
        )
        let host = HermesPairingStatus.Host(name: "Redacted Test Host", nodeId: "REDACTED-NODE")
        switch checkpointScenario {
        case .initial:
            return
        case .expired:
            requiresNewSetupPrompt = true
            statusMessage = "This request expired. Copy a new setup prompt to try again."
            errorMessage = "Redacted fixture expiration"
        case .creating:
            isCreating = true
            statusMessage = "Creating a secure request…"
        case .waiting, .copied, .renewed:
            self.request = request
            phase = .polling
            statusMessage = checkpointScenario == .renewed ? "New secure request created. Waiting for Hermes…" : "Waiting for Hermes…"
        case .paused:
            self.request = request
            phase = .paused
            statusMessage = "Pairing paused while Learnfold is in the background."
        case .retrying:
            self.request = request
            phase = .polling
            statusMessage = "Network interrupted. Retrying this same request…"
            errorMessage = "Redacted fixture network interruption"
        case .review, .confirmation:
            self.request = request
            readyHost = host
            phase = .ready
            statusMessage = "Hermes sent the pairing securely."
        case .validReview:
            statusMessage = "Redacted QR/paste pairing preview."
        case .scanner, .cameraDenied, .parseError:
            statusMessage = "Redacted QR/paste pairing preview."
        case .claiming:
            self.request = request
            readyHost = host
            phase = .claiming
            statusMessage = "Claiming the one-time credential…"
        case .finishing:
            self.request = request
            readyHost = host
            phase = .claimed
            statusMessage = "Pairing received. Finishing the connection…"
        }
    }
    #endif

    func restoreAndResume() {
        #if DEBUG
        if checkpointIsolated { return }
        #endif
        guard request == nil else {
            resume()
            return
        }
        do {
            guard let saved = try store.load() else { return }
            guard saved.expiresAt > now() else {
                request = saved
                _ = clearIfCurrent(
                    requestID: saved.requestId,
                    reason: .expired,
                    status: "The request expired. Copy a new setup prompt to try again.",
                    failureStatus: "The request expired, but Learnfold could not remove its saved credential. Try again."
                )
                return
            }
            install(saved)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not restore the secure pairing request."
        }
    }

    func createRequest(installationId: String) async throws -> HermesPairingRequest {
        #if DEBUG
        if checkpointScenario != nil {
            isCreating = false
            let fixture = HermesPairingRequest(
                requestId: "REDACTED-REQUEST",
                submitURL: URL(string: "https://example.invalid/redacted")!,
                claimToken: "REDACTED",
                expiresAt: now().addingTimeInterval(600)
            )
            request = fixture
            requiresNewSetupPrompt = false
            phase = .polling
            statusMessage = "Waiting for Hermes…"
            return fixture
        }
        #endif
        let operationID = UUID()
        let previous = request
        creationID = operationID
        isCreating = true
        errorMessage = nil

        do {
            let created = try await broker.createRequest(installationId: installationId)
            guard creationID == operationID, !Task.isCancelled else {
                await broker.cancel(created)
                throw CancellationError()
            }
            guard created.expiresAt > now() else {
                await broker.cancel(created)
                throw HermesPairingBrokerError.expired
            }
            do {
                try store.save(created)
            } catch {
                await broker.cancel(created)
                throw error
            }
            creationID = nil
            isCreating = false
            install(created)
            if let previous, previous.requestId != created.requestId {
                Task { await broker.cancel(previous) }
            }
            return created
        } catch {
            guard creationID == operationID else { throw error }
            creationID = nil
            isCreating = false
            errorMessage = error.localizedDescription
            if request?.requestId == previous?.requestId, previous != nil {
                statusMessage = "Could not replace this request. The existing prompt is still valid."
            } else {
                statusMessage = "Could not create a secure request. Try again."
            }
            throw error
        }
    }

    func pause() {
        #if DEBUG
        if checkpointIsolated { return }
        #endif
        shouldPoll = false
        pollingTask?.cancel()
        pollingTask = nil
        if request != nil, phase != .claimed {
            phase = .paused
            statusMessage = readyHost == nil
                ? "Pairing paused while Learnfold is in the background."
                : "Hermes is ready. Return to Learnfold to connect."
        }
    }

    func resume() {
        #if DEBUG
        if checkpointIsolated { return }
        #endif
        shouldPoll = true
        guard let request else { return }
        guard request.expiresAt > now() else {
            clearIfCurrent(
                requestID: request.requestId,
                reason: .expired,
                status: "The request expired. Copy a new setup prompt to try again.",
                failureStatus: "The request expired, but Learnfold could not remove its saved credential. Try again."
            )
            return
        }
        if phase == .claimed {
            statusMessage = "Pairing received. Finishing the connection…"
            return
        }
        if readyHost != nil {
            phase = .ready
            statusMessage = "Hermes sent the pairing securely."
            return
        }
        startPolling(request)
    }

    func cancel() {
        #if DEBUG
        if checkpointIsolated { return }
        #endif
        let cancelled = request
        creationID = nil
        isCreating = false
        pollingTask?.cancel()
        pollingTask = nil
        _ = clearLocalState(
            reason: .cancelled,
            status: "Create a secure request, then paste the prompt into Hermes.",
            failureStatus: "The request was cancelled, but Learnfold could not remove its saved credential. Try Cancel again."
        )
        if let cancelled {
            Task { await broker.cancel(cancelled) }
        }
    }

    func claim() async -> HermesPairingClaimResult? {
        #if DEBUG
        if checkpointScenario != nil, let request {
            phase = .claimed
            statusMessage = "Pairing received. Finishing the connection…"
            return HermesPairingClaimResult(requestID: request.requestId, payload: "{\"fixture\":\"REDACTED\"}")
        }
        #endif
        guard let pairing = request else { return nil }
        guard pairing.expiresAt > now() else {
            clearIfCurrent(
                requestID: pairing.requestId,
                reason: .expired,
                status: "The request expired. Copy a new setup prompt to try again.",
                failureStatus: "The request expired, but Learnfold could not remove its saved credential. Try again."
            )
            return nil
        }
        pollingTask?.cancel()
        pollingTask = nil
        phase = .claiming
        errorMessage = nil
        statusMessage = "Claiming the one-time credential…"

        do {
            let payload = try await broker.claim(pairing)
            guard isCurrent(pairing.requestId), !Task.isCancelled else { return nil }
            phase = .claimed
            statusMessage = "Pairing received. Finishing the connection…"
            return HermesPairingClaimResult(requestID: pairing.requestId, payload: payload)
        } catch {
            guard isCurrent(pairing.requestId), !Task.isCancelled else { return nil }
            if Self.isTerminal(error) || pairing.expiresAt <= now() {
                clearIfCurrent(
                    requestID: pairing.requestId,
                    reason: .expired,
                    status: "This request expired. Copy a new setup prompt to try again.",
                    failureStatus: "The request expired, but Learnfold could not remove its saved credential. Try again."
                )
            } else {
                phase = readyHost == nil ? .paused : .ready
                errorMessage = error.localizedDescription
                statusMessage = "The network interrupted the claim. Tap Connect to retry this request."
            }
            return nil
        }
    }

    @discardableResult
    func completeConnection(requestID: String?) -> Bool {
        #if DEBUG
        if checkpointIsolated { return requestID == request?.requestId }
        #endif
        guard let requestID, let completed = request, completed.requestId == requestID else {
            return false
        }
        pollingTask?.cancel()
        pollingTask = nil
        guard clearIfCurrent(
            requestID: completed.requestId,
            reason: .completed,
            status: "Connected securely.",
            failureStatus: "Connected, but Learnfold could not clear the saved pairing request. Tap Connect to retry cleanup."
        ) else {
            return false
        }
        Task { await broker.cancel(completed) }
        return true
    }

    func acceptsCompletion(for requestID: String) -> Bool {
        isCurrent(requestID)
    }

    private func install(_ pairing: HermesPairingRequest) {
        request = pairing
        requiresNewSetupPrompt = false
        readyHost = nil
        errorMessage = nil
        statusMessage = "Waiting for Hermes…"
        if shouldPoll {
            startPolling(pairing)
        } else {
            phase = .paused
            statusMessage = "Pairing paused while Learnfold is in the background."
        }
    }

    private func startPolling(_ pairing: HermesPairingRequest) {
        pollingTask?.cancel()
        phase = .polling
        pollingTask = Task { [weak self] in
            guard let self else { return }
            var failureCount = 0
            while !Task.isCancelled {
                guard self.isCurrent(pairing.requestId) else { return }
                guard pairing.expiresAt > self.now() else {
                    self.clearIfCurrent(
                        requestID: pairing.requestId,
                        reason: .expired,
                        status: "The request expired. Copy a new setup prompt to try again.",
                        failureStatus: "The request expired, but Learnfold could not remove its saved credential. Try again."
                    )
                    return
                }
                do {
                    let status = try await self.broker.status(for: pairing)
                    guard !Task.isCancelled, self.isCurrent(pairing.requestId) else { return }
                    failureCount = 0
                    self.errorMessage = nil
                    if (status.state == "ready" || status.state == "claimed"),
                       let host = status.host {
                        self.readyHost = host
                        self.phase = .ready
                        self.statusMessage = "Hermes sent the pairing securely."
                        return
                    }
                    self.statusMessage = "Waiting for Hermes…"
                } catch {
                    guard !Task.isCancelled, self.isCurrent(pairing.requestId) else { return }
                    if Self.isTerminal(error) || pairing.expiresAt <= self.now() {
                        self.clearIfCurrent(
                            requestID: pairing.requestId,
                            reason: .expired,
                            status: "This request expired. Copy a new setup prompt to try again.",
                            failureStatus: "The request expired, but Learnfold could not remove its saved credential. Try again."
                        )
                        return
                    }
                    failureCount += 1
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "Network interrupted. Retrying this same request…"
                }

                let delay = failureCount == 0
                    ? self.retryPolicy.delay(afterFailureCount: 1)
                    : self.retryPolicy.delay(afterFailureCount: failureCount)
                do {
                    try await self.sleep(delay)
                } catch {
                    return
                }
            }
        }
    }

    private func isCurrent(_ requestID: String) -> Bool {
        request?.requestId == requestID
    }

    @discardableResult
    private func clearIfCurrent(
        requestID: String,
        reason: ClearReason,
        status: String,
        failureStatus: String
    ) -> Bool {
        guard isCurrent(requestID) else { return false }
        return clearLocalState(
            reason: reason,
            status: status,
            failureStatus: failureStatus
        )
    }

    @discardableResult
    private func clearLocalState(
        reason: ClearReason,
        status: String,
        failureStatus: String
    ) -> Bool {
        requiresNewSetupPrompt = reason.requiresNewSetupPrompt
        do {
            try store.clear()
        } catch {
            phase = .paused
            errorMessage = error.localizedDescription
            statusMessage = failureStatus
            return false
        }
        request = nil
        readyHost = nil
        phase = .idle
        errorMessage = nil
        statusMessage = status
        return true
    }

    private static func isTerminal(_ error: Error) -> Bool {
        guard let brokerError = error as? HermesPairingBrokerError else { return false }
        if case .expired = brokerError { return true }
        return false
    }
}
