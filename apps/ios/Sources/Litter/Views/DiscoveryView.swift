import SwiftUI
import Network

#if DEBUG
enum ServerLifecycleCheckpointScenario: String, CaseIterable {
    case lifecycleConnecting = "server-lifecycle-connecting"
    case lifecycleWaking = "server-lifecycle-waking"
    case lifecycleProgress = "server-lifecycle-progress"
    case lifecycleConnected = "server-lifecycle-connected"
    case lifecycleDisconnected = "server-lifecycle-disconnected"
    case sshLoginEmpty = "ssh-login-empty"
    case sshLoginAuthError = "ssh-login-auth-error"
    case sshLoginSubmitted = "ssh-login-submitted"
    case sshAgentPickerLoading = "ssh-agent-picker-loading"
    case sshAgentPickerError = "ssh-agent-picker-error"
    case sshAgentPickerPopulated = "ssh-agent-picker-populated"
    case manualServerInvalid = "manual-server-invalid"
    case manualServerSubmitted = "manual-server-submitted"
    case slingshotBrowserLoading = "slingshot-browser-loading"
    case slingshotBrowserError = "slingshot-browser-error"
    case slingshotBrowserResults = "slingshot-browser-results"
    case lf16FailureAlert = "server-lifecycle-lf16-failure-alert"
    case lf16PostRetry = "server-lifecycle-lf16-post-retry"

    var route: String {
        switch self {
        case .lifecycleConnecting,
             .lifecycleWaking,
             .lifecycleProgress,
             .lifecycleConnected,
             .lifecycleDisconnected,
             .lf16FailureAlert,
             .lf16PostRetry:
            return "--ui-test-server-lifecycle"
        case .sshLoginEmpty, .sshLoginAuthError, .sshLoginSubmitted:
            return "--ui-test-ssh-login"
        case .sshAgentPickerLoading, .sshAgentPickerError, .sshAgentPickerPopulated:
            return "--ui-test-ssh-agent-picker"
        case .manualServerInvalid, .manualServerSubmitted:
            return "--ui-test-manual-server"
        case .slingshotBrowserLoading, .slingshotBrowserError, .slingshotBrowserResults:
            return "--ui-test-slingshot-browser"
        }
    }

    var lifecycleState: String? {
        switch self {
        case .lifecycleConnecting: return "connecting"
        case .lifecycleWaking: return "waking"
        case .lifecycleProgress: return "progress"
        case .lifecycleConnected: return "connected"
        case .lifecycleDisconnected: return "disconnected"
        default: return nil
        }
    }

    var sshLoginState: SSHLoginCheckpointState? {
        switch self {
        case .sshLoginEmpty: return .empty
        case .sshLoginAuthError: return .authError
        case .sshLoginSubmitted: return .submitted
        default: return nil
        }
    }

    var sshAgentPickerState: SSHAgentPickerCheckpointState? {
        switch self {
        case .sshAgentPickerLoading: return .loading
        case .sshAgentPickerError: return .error
        case .sshAgentPickerPopulated: return .populated
        default: return nil
        }
    }

    var manualServerState: String? {
        switch self {
        case .manualServerInvalid: return "invalid"
        case .manualServerSubmitted: return "submitted"
        default: return nil
        }
    }

    var slingshotBrowserState: String? {
        switch self {
        case .slingshotBrowserLoading: return "loading"
        case .slingshotBrowserError: return "error"
        case .slingshotBrowserResults: return "results"
        default: return nil
        }
    }

    var lf16Substate: DiscoveryConnectionRetryCheckpointSubstate? {
        switch self {
        case .lf16FailureAlert: return .failureAlert
        case .lf16PostRetry: return .postRetry
        default: return nil
        }
    }

}

enum DiscoveryConnectionRetryCheckpointSubstate: String, CaseIterable {
    case failureAlert = "failure-alert"
    case postRetry = "post-retry"
}

enum ServerLifecycleCheckpointConfigurationError: String, Error, Equatable {
    case testingEnvironmentRequired = "testing-environment-required"
    case missingRoute = "missing-route"
    case missingState = "missing-state"
    case unknownState = "unknown-state"
    case routeStateMismatch = "route-state-mismatch"
    case duplicateRoute = "duplicate-route"
    case multipleRoutes = "multiple-routes"
    case multipleStates = "multiple-states"
    case unregisteredCheckpoint = "unregistered-checkpoint"
    case mixedLaunchAuthorities = "mixed-launch-authorities"
    case multipleSuites = "multiple-suites"
    case suiteConfiguration = "suite-configuration"
    case harnessUnavailable = "harness-unavailable"

    var message: String {
        switch self {
        case .testingEnvironmentRequired:
            return "Checkpoint routes require LEARNFOLD_UI_TESTING=1."
        case .missingRoute:
            return "A checkpoint state was provided without its exact route."
        case .missingState:
            return "The checkpoint route must be followed immediately by one state token."
        case .unknownState:
            return "The checkpoint route was followed by an unknown state token."
        case .routeStateMismatch:
            return "The checkpoint state does not belong to the selected route."
        case .duplicateRoute:
            return "A checkpoint route may appear exactly once."
        case .multipleRoutes:
            return "Only one checkpoint route may be selected per launch."
        case .multipleStates:
            return "Only the one adjacent checkpoint state token is allowed."
        case .unregisteredCheckpoint:
            return "The checkpoint signal is not registered with the strict launch parser."
        case .mixedLaunchAuthorities:
            return "A strict checkpoint cannot be combined with non-authoritative test controls."
        case .multipleSuites:
            return "Only one strict checkpoint suite may be selected per launch."
        case .suiteConfiguration:
            return "The selected checkpoint suite rejected its typed configuration."
        case .harnessUnavailable:
            return "The selected checkpoint root is quarantined."
        }
    }

    init(_ code: StrictUITestLaunchErrorCode) {
        switch code {
        case .testingEnvironmentRequired: self = .testingEnvironmentRequired
        case .unregisteredCheckpoint: self = .unregisteredCheckpoint
        case .mixedLaunchAuthorities: self = .mixedLaunchAuthorities
        case .multipleSuites: self = .multipleSuites
        case .missingRoute: self = .missingRoute
        case .missingState: self = .missingState
        case .unknownState: self = .unknownState
        case .routeStateMismatch: self = .routeStateMismatch
        case .duplicateRoute: self = .duplicateRoute
        case .multipleRoutes: self = .multipleRoutes
        case .multipleStates: self = .multipleStates
        case .suiteConfiguration: self = .suiteConfiguration
        case .harnessUnavailable: self = .harnessUnavailable
        }
    }
}

enum ServerLifecycleCheckpointLaunchConfiguration: Equatable {
    case disabled
    case scenario(ServerLifecycleCheckpointScenario)
    case invalid(ServerLifecycleCheckpointConfigurationError)
}

struct ServerLifecycleCheckpointParser {
    static let recognizedRoutes =
        LearnfoldStrictHarnessPolicy.serverLifecycleCheckpointRouteArguments

    static func parse(
        arguments: [String],
        environment: [String: String]
    ) -> ServerLifecycleCheckpointLaunchConfiguration {
        switch StrictUITestLaunchConfiguration.parse(
            arguments: arguments,
            environment: environment
        ) {
        case .disabled:
            return .disabled
        case .valid(.serverLifecycle(let scenario)):
            return .scenario(scenario)
        case .valid:
            return .invalid(.multipleSuites)
        case .invalid(let error):
            return .invalid(ServerLifecycleCheckpointConfigurationError(error.code))
        }
    }
}
#endif

struct DiscoveryConnectionAttempt: Equatable {
    let server: DiscoveredServer
    let target: ConnectionTarget
    let runID: UUID

    init(
        server: DiscoveredServer,
        target: ConnectionTarget,
        runID: UUID = UUID()
    ) {
        self.server = server
        self.target = target
        self.runID = runID
    }

    func nextRun() -> DiscoveryConnectionAttempt {
        DiscoveryConnectionAttempt(server: server, target: target)
    }
}

enum DiscoveryConnectionRetryPhase: String, Equatable {
    case idle
    case connecting
    case failureAlert = "failure-alert"
    case retrying
    case postRetry = "post-retry"
    case nonRetryableError = "non-retryable-error"
}

struct DiscoveryConnectionRetryState {
    private(set) var activeAttempt: DiscoveryConnectionAttempt?
    private(set) var failedAttempt: DiscoveryConnectionAttempt?
    private(set) var errorMessage: String?
    private(set) var phase: DiscoveryConnectionRetryPhase = .idle
    private(set) var attemptCount = 0
    private(set) var receipt: DiscoveryConnectionRetryReceipt?

    var canRetry: Bool {
        activeAttempt == nil && failedAttempt != nil && errorMessage != nil
    }

    var failedServer: DiscoveredServer? {
        failedAttempt?.server
    }

    /// Deliberately excludes the server, URL, username, and credentials kept
    /// inside `DiscoveryConnectionAttempt` for the actual Retry action.
    var stateAccessibilityValue: String {
        "phase=\(phase.rawValue);attempt=\(attemptCount)"
    }

    var receiptAccessibilityValue: String {
        receipt?.rawValue ?? "none"
    }

    #if DEBUG
    var evidenceReceipt: DiscoveryConnectionRetryEvidenceReceipt? {
        guard let receipt else { return nil }
        return DiscoveryConnectionRetryEvidenceReceipt(
            state: receipt,
            attemptCount: attemptCount
        )
    }

    @discardableResult
    mutating func transferPostRetryEvidenceReceipt(
        to receive: (DiscoveryConnectionRetryEvidenceReceipt) -> Bool
    ) -> Bool {
        guard let evidenceReceipt, evidenceReceipt.state == .postRetry else {
            return false
        }
        guard receive(evidenceReceipt) else { return false }
        receipt = nil
        return true
    }
    #endif

    mutating func begin(_ attempt: DiscoveryConnectionAttempt) -> Bool {
        guard activeAttempt == nil else { return false }
        activeAttempt = attempt
        failedAttempt = nil
        errorMessage = nil
        phase = .connecting
        attemptCount = 1
        receipt = nil
        return true
    }

    mutating func beginRetry() -> DiscoveryConnectionAttempt? {
        guard activeAttempt == nil, let failedAttempt else { return nil }
        let retryAttempt = failedAttempt.nextRun()
        activeAttempt = retryAttempt
        self.failedAttempt = nil
        errorMessage = nil
        phase = .retrying
        attemptCount += 1
        receipt = .retrying
        return retryAttempt
    }

    @discardableResult
    mutating func fail(_ attempt: DiscoveryConnectionAttempt, message: String) -> Bool {
        guard activeAttempt == attempt else { return false }
        activeAttempt = nil
        failedAttempt = attempt
        errorMessage = message
        phase = .failureAlert
        receipt = .failureAlert
        return true
    }

    @discardableResult
    mutating func complete(_ attempt: DiscoveryConnectionAttempt) -> Bool {
        guard activeAttempt == attempt else { return false }
        let completedRetry = phase == .retrying
        activeAttempt = nil
        failedAttempt = nil
        errorMessage = nil
        if completedRetry {
            phase = .postRetry
            receipt = .postRetry
        } else {
            phase = .idle
            attemptCount = 0
            receipt = nil
        }
        return true
    }

    @discardableResult
    mutating func presentNonRetryableError(_ message: String) -> Bool {
        guard activeAttempt == nil else { return false }
        failedAttempt = nil
        errorMessage = message
        phase = .nonRetryableError
        attemptCount = 0
        receipt = nil
        return true
    }

    mutating func dismissError() {
        guard activeAttempt == nil else { return }
        failedAttempt = nil
        errorMessage = nil
        if phase == .failureAlert || phase == .nonRetryableError {
            phase = .idle
        }
    }

    mutating func abandon() {
        activeAttempt = nil
        failedAttempt = nil
        errorMessage = nil
        phase = .idle
        attemptCount = 0
        receipt = nil
    }
}

enum DiscoveryLiveLifecycleStatus: String, Equatable, Sendable {
    case waking
    case connecting
    case progress
    case connected
    case disconnected

    var title: String {
        switch self {
        case .waking:
            return "Waking server"
        case .connecting:
            return "Connecting to server"
        case .progress:
            return "Preparing server"
        case .connected:
            return "Server connected"
        case .disconnected:
            return "Server disconnected"
        }
    }
}

struct DiscoveryLiveLifecyclePresentation: Equatable, Sendable {
    let status: DiscoveryLiveLifecycleStatus
    let serverName: String
    let detail: String

    static func resolve(
        wakingServerName: String?,
        connectingServerName: String?,
        progressDetail: String?,
        failedServerName: String?,
        failureMessage: String?
    ) -> DiscoveryLiveLifecyclePresentation? {
        if let wakingServerName {
            return DiscoveryLiveLifecyclePresentation(
                status: .waking,
                serverName: wakingServerName,
                detail: "Sending a wake request and checking for a reachable service."
            )
        }
        if let connectingServerName {
            if let progressDetail,
               !progressDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return DiscoveryLiveLifecyclePresentation(
                    status: .progress,
                    serverName: connectingServerName,
                    detail: progressDetail
                )
            }
            return DiscoveryLiveLifecyclePresentation(
                status: .connecting,
                serverName: connectingServerName,
                detail: "Establishing a secure connection."
            )
        }
        if let failedServerName, let failureMessage {
            return DiscoveryLiveLifecyclePresentation(
                status: .disconnected,
                serverName: failedServerName,
                detail: failureMessage
            )
        }
        return nil
    }
}

#if DEBUG
enum DiscoveryConnectionRetryCheckpointAttemptResult: Equatable {
    case failure(message: String)
    case success
}

struct DiscoveryConnectionRetryCheckpointAttemptHook {
    let identifier: String

    static let lf16FailOnce = DiscoveryConnectionRetryCheckpointAttemptHook(
        identifier: "lf-16-fault-hook"
    )

    func result(
        for attempt: DiscoveryConnectionAttempt,
        attemptNumber: Int
    ) async -> DiscoveryConnectionRetryCheckpointAttemptResult {
        _ = attempt
        try? await Task.sleep(for: .milliseconds(250))
        if attemptNumber == 1 {
            return .failure(
                message: "The deterministic LF-16 connection attempt was refused."
            )
        }
        return .success
    }
}

enum DiscoveryConnectionRetryCheckpointEvent: String, Equatable {
    case receipt
    case selection
}

struct DiscoveryConnectionRetryCheckpointEvidence {
    private(set) var receipt: DiscoveryConnectionRetryEvidenceReceipt?
    private(set) var selectedServerID: String?
    private(set) var events: [DiscoveryConnectionRetryCheckpointEvent] = []

    mutating func receive(
        _ receipt: DiscoveryConnectionRetryEvidenceReceipt
    ) -> Bool {
        guard receipt.state == .postRetry else { return false }
        self.receipt = receipt
        events.append(.receipt)
        return true
    }

    @discardableResult
    mutating func recordSelection(serverID: String) -> Bool {
        guard receipt?.state == .postRetry else { return false }
        selectedServerID = serverID
        events.append(.selection)
        return true
    }

    var eventOrderAccessibilityValue: String {
        events.map(\.rawValue).joined(separator: ">")
    }
}

private struct DiscoveryConnectionRetryAccessibilitySurface: View {
    let stateValue: String
    let receiptValue: String?

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Connection retry state")
                .accessibilityIdentifier("lf16-connection-retry-state")
                .accessibilityValue(stateValue)
            if let receiptValue {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Connection retry receipt")
                    .accessibilityIdentifier("lf16-connection-retry-receipt")
                    .accessibilityValue(receiptValue)
            }
        }
        .frame(width: 1, height: 2)
        .allowsHitTesting(false)
    }
}
#endif

enum DiscoveryConnectionFailurePresentation {
    static func message(for rawMessage: String) -> String {
        let normalized = rawMessage.lowercased()
        if normalized.contains("auth")
            || normalized.contains("unauthorized")
            || normalized.contains("forbidden")
            || normalized.contains("permission denied") {
            return "Authentication failed. Check the server credentials and try again."
        }
        if normalized.contains("timed out")
            || normalized.contains("timeout")
            || normalized.contains("unreachable")
            || normalized.contains("refused")
            || normalized.contains("offline") {
            return "The server did not respond. Check that it is online and try again."
        }
        return "Learnfold couldn't connect to this server. Check the connection and try again."
    }
}

enum DiscoveryPendingConnectionResolution: Equatable {
    case pending
    case connected
    case failed(message: String)

    static func resolve(
        health: AppServerHealth?,
        terminalMessage: String?
    ) -> DiscoveryPendingConnectionResolution {
        if health == .connected {
            return .connected
        }
        if health == .disconnected, let terminalMessage {
            return .failed(message: terminalMessage)
        }
        return .pending
    }
}

@MainActor
final class DiscoveryConnectionLifecycleGate {
    private var epoch = UUID()
    private(set) var isActive = false

    @discardableResult
    func activate() -> UUID {
        if !isActive {
            epoch = UUID()
            isActive = true
        }
        return epoch
    }

    var currentEpoch: UUID? {
        isActive ? epoch : nil
    }

    func invalidate() {
        isActive = false
        epoch = UUID()
    }

    func isCurrent(_ candidate: UUID) -> Bool {
        isActive && epoch == candidate
    }
}

@MainActor
enum DiscoveryViewRuntimeDependencies {
    case live(appModel: AppModel, appState: AppState)
    case inertCheckpoint

    var appModel: AppModel? {
        guard case .live(let appModel, _) = self else { return nil }
        return appModel
    }

    var appState: AppState? {
        guard case .live(_, let appState) = self else { return nil }
        return appState
    }

    var isInertCheckpoint: Bool {
        if case .inertCheckpoint = self { return true }
        return false
    }

    var sshLoginRuntimeMode: SSHLoginRuntimeMode {
        isInertCheckpoint ? .inertCheckpoint : .live
    }
}

#if DEBUG
struct DiscoverySimulatorAutoSSHGate {
    static func allowsStart(
        isInertCheckpoint: Bool,
        strictHarnessActive: Bool
    ) -> Bool {
        !isInertCheckpoint && !strictHarnessActive
    }
}
#endif

struct DiscoveryView: View {
    var onServerSelected: ((DiscoveredServer) -> Void)?
    private let runtimeDependencies: DiscoveryViewRuntimeDependencies
    @State private var discovery: NetworkDiscovery
    @State private var sshServer: DiscoveredServer?
    @State private var connectionChoiceServer: DiscoveredServer?
    @State private var pendingSSHServer: DiscoveredServer?
    @State private var sshAgentContext: SSHBridgeAgentContext?
    @State private var pendingSSHAgentContext: SSHBridgeAgentContext?
    @State private var showManualEntry = false
    @State private var showAlleycatSheet = false
    @State private var showSlingshotHosts = false
    @State private var slingshotEnvironments: [AppSlingshotEnvironment] = []
    @State private var slingshotIsLoading = false
    @State private var slingshotError: String?
    @State private var manualConnectionMode: ManualConnectionMode = .ssh
    @State private var manualCodexURL = ""
    @State private var manualHost = ""
    @State private var manualSSHPort = "22"
    @State private var manualWakeMAC = ""
    @State private var autoSSHStarted = false
    @State private var connectingServer: DiscoveredServer?
    @State private var wakingServer: DiscoveredServer?
    @State private var pendingAutoNavigateServerId: String?
    @State private var pendingAutoNavigateServer: DiscoveredServer?
    @State private var pendingAutoNavigateAttempt: DiscoveryConnectionAttempt?
    @State private var pendingAutoNavigateLifecycleEpoch: UUID?
    @State private var connectionRetryState = DiscoveryConnectionRetryState()
    @State private var connectionLifecycleGate = DiscoveryConnectionLifecycleGate()
    @State private var connectionTask: Task<Void, Never>?
    @State private var connectionTaskRunID: UUID?
    @State private var manualWakeTask: Task<Void, Never>?
    @State private var renameTarget: DiscoveredServer?
    @State private var renameText = ""
    #if DEBUG
    @State private var debugLF16ConnectionAttemptCount = 0
    @State private var debugLF16CheckpointEvidence =
        DiscoveryConnectionRetryCheckpointEvidence()
    @State private var debugCheckpointConfigured = false
    @State private var debugLifecycleRecoveryRequested = false
    @State private var debugManualInvalidSubmissionStarted = false
    private var debugConnectionAttemptHook:
        DiscoveryConnectionRetryCheckpointAttemptHook?
    #endif

    private func liveAppModel(for event: String) -> AppModel? {
        guard case .live(let appModel, _) = runtimeDependencies else {
            LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                "DiscoveryView.inertCheckpoint.\(event)"
            )
            return nil
        }
        return appModel
    }

    private func liveAppState(for event: String) -> AppState? {
        guard case .live(_, let appState) = runtimeDependencies else {
            LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                "DiscoveryView.inertCheckpoint.\(event)"
            )
            return nil
        }
        return appState
    }

    private let autoStartDiscovery: Bool
    private let initialServers: [DiscoveredServer]
    private let slingshotBaseURL = "https://chatgpt.com/backend-api"
    #if DEBUG
    private var checkpointConfiguration: ServerLifecycleCheckpointLaunchConfiguration = .disabled
    #endif

    init(
        runtimeDependencies: DiscoveryViewRuntimeDependencies,
        onServerSelected: ((DiscoveredServer) -> Void)? = nil,
        discovery: NetworkDiscovery? = nil,
        autoStartDiscovery: Bool = true,
        initialServers: [DiscoveredServer] = []
    ) {
        self.runtimeDependencies = runtimeDependencies
        self.onServerSelected = onServerSelected
        _discovery = State(
            initialValue: discovery ?? NetworkDiscovery(
                runtimeMode: runtimeDependencies.isInertCheckpoint
                    ? .inertCheckpoint
                    : .live
            )
        )
        self.autoStartDiscovery = autoStartDiscovery
        self.initialServers = initialServers
    }

    #if DEBUG
    init(
        runtimeDependencies: DiscoveryViewRuntimeDependencies,
        onServerSelected: ((DiscoveredServer) -> Void)? = nil,
        discovery: NetworkDiscovery? = nil,
        autoStartDiscovery: Bool = true,
        initialServers: [DiscoveredServer] = [],
        checkpointConfiguration: ServerLifecycleCheckpointLaunchConfiguration,
        connectionAttemptHook: DiscoveryConnectionRetryCheckpointAttemptHook? = nil
    ) {
        self.init(
            runtimeDependencies: runtimeDependencies,
            onServerSelected: onServerSelected,
            discovery: discovery,
            autoStartDiscovery: autoStartDiscovery,
            initialServers: initialServers
        )
        self.checkpointConfiguration = checkpointConfiguration
        self.debugConnectionAttemptHook = connectionAttemptHook
    }
    #endif

    private var localServers: [DiscoveredServer] {
        discovery.servers.filter { $0.source == .local }
    }

    private var networkServers: [DiscoveredServer] {
        discovery.servers.filter { $0.source != .local }
    }

    private var isPrimaryStrictHarnessSurfaceVisible: Bool {
        sshServer == nil
            && sshAgentContext == nil
            && !showManualEntry
            && !showSlingshotHosts
            && !showAlleycatSheet
    }

    private func applyInitialServersIfNeeded() {
        guard !initialServers.isEmpty, discovery.servers.isEmpty else { return }
        discovery.servers = initialServers
        discovery.isScanning = false
    }

    private func refreshDiscovery() {
        guard autoStartDiscovery else {
            applyInitialServersIfNeeded()
            return
        }
        discovery.startScanning()
    }

    private func handleAppear() {
        connectionLifecycleGate.activate()
        #if DEBUG
        runtimeDependencies.appState?
            .clearDiscoveryConnectionRetryEvidenceReceipt()
        if configureDebugCheckpointIfNeeded() {
            return
        }
        #endif
        guard autoStartDiscovery else { return }
        maybeStartSimulatorAutoSSH()
    }

    private func handleDisappear() {
        connectionLifecycleGate.invalidate()
        manualWakeTask?.cancel()
        manualWakeTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        connectionTaskRunID = nil
        connectingServer = nil
        connectionRetryState.abandon()
        pendingAutoNavigateServerId = nil
        pendingAutoNavigateServer = nil
        pendingAutoNavigateAttempt = nil
        pendingAutoNavigateLifecycleEpoch = nil
    }

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            primaryContent
            #if DEBUG
            if !runtimeDependencies.isInertCheckpoint {
                DiscoveryConnectionRetryAccessibilitySurface(
                    stateValue: connectionRetryState.stateAccessibilityValue,
                    receiptValue: connectionRetryState.receipt?.rawValue
                )
            }
            #endif
        }
        .navigationTitle("Add Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandLogo(size: 44)
            }
        }
        .onAppear { handleAppear() }
        .onDisappear { handleDisappear() }
        .sheet(item: $sshServer, onDismiss: handleSSHLoginSheetDismissed) { server in
            sshLoginSheet(server: server, onAccepted: handleAcceptedSSHLogin)
        }
        .sheet(item: $sshAgentContext) { context in
            #if DEBUG
            if let checkpointState = debugCheckpointScenario?.sshAgentPickerState {
                SSHAgentPickerSheet(
                    context: context,
                    checkpointState: checkpointState,
                    onConnected: { _ in },
                    onUseCodex: { sshAgentContext = nil },
                    onCancel: { sshAgentContext = nil }
                )
            } else {
                sshAgentPickerSheet(context: context)
            }
            #else
            sshAgentPickerSheet(context: context)
            #endif
        }
        .confirmationDialog(
            connectionChoiceServer.map { "Connect to \($0.name)" } ?? "Choose Connection",
            isPresented: connectionChoicePresented,
            titleVisibility: .visible
        ) {
            if let server = connectionChoiceServer {
                ForEach(server.availableDirectCodexPorts, id: \.self) { port in
                    Button("Use Codex (\(port))") {
                        let preferredServer = server.withConnectionPreference(.directCodex, codexPort: port)
                        connectionChoiceServer = nil
                        Task { await connectToServer(preferredServer) }
                    }
                }
                if server.canConnectViaSSH {
                    Button("Connect via SSH") {
                        let preferredServer = server.withConnectionPreference(.ssh)
                        connectionChoiceServer = nil
                        sshServer = preferredServer
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                connectionChoiceServer = nil
            }
        } message: {
            if let server = connectionChoiceServer {
                Text(connectionChoiceMessage(for: server))
            }
        }
        .sheet(
            isPresented: $showManualEntry,
            onDismiss: handleManualEntrySheetDismissed
        ) {
            manualEntrySheet
        }
        .sheet(isPresented: $showSlingshotHosts) {
            slingshotHostsSheet
        }
        .sheet(isPresented: $showAlleycatSheet) {
            alleycatAddServerSheet
        }
        .onChange(of: runtimeDependencies.appModel?.snapshot) { _, nextSnapshot in
            reconcilePendingAutoNavigation(with: nextSnapshot)
        }
        .alert("Connection Failed", isPresented: showConnectError, actions: {
            if connectionRetryState.canRetry {
                Button("Retry") {
                    retryLastConnection()
                }
                .accessibilityHint("Tries the same server and connection target again.")
            }
            Button("OK", role: .cancel) { connectionRetryState.dismissError() }
        }, message: {
            connectionFailureAlertMessage
        })
        .alert("Rename Server", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let server = renameTarget {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let newName = trimmed.isEmpty ? server.hostname : trimmed
                    SavedServerStore.upsert(DiscoveredServer(
                        id: server.id,
                        name: newName,
                        hostname: server.hostname,
                        port: server.port,
                        codexPorts: server.codexPorts,
                        sshPort: server.sshPort,
                        source: server.source,
                        hasCodexServer: server.hasCodexServer,
                        wakeMAC: server.wakeMAC,
                        preferredConnectionMode: server.preferredConnectionMode,
                        preferredCodexPort: server.preferredCodexPort,
                        os: server.os,
                        sshBanner: server.sshBanner
                    ))
                    if let idx = discovery.servers.firstIndex(where: { $0.id == server.id }) {
                        discovery.servers[idx] = DiscoveredServer(
                            id: server.id,
                            name: newName,
                            hostname: server.hostname,
                            port: server.port,
                            codexPorts: server.codexPorts,
                            sshPort: server.sshPort,
                            source: server.source,
                            hasCodexServer: server.hasCodexServer,
                            wakeMAC: server.wakeMAC,
                            preferredConnectionMode: server.preferredConnectionMode,
                            preferredCodexPort: server.preferredCodexPort,
                            os: server.os,
                            sshBanner: server.sshBanner
                        )
                    }
                }
                renameTarget = nil
            }
        } message: {
            Text("Enter a new name for this server.")
        }
        .serverLifecycleStrictHarnessBoundaryIfActive(
            visible: isPrimaryStrictHarnessSurfaceVisible
        )
    }

    @ViewBuilder
    private var alleycatAddServerSheet: some View {
        if let appModel = liveAppModel(for: "presentAlleycatSheet") {
            AlleycatAddServerSheet(appModel: appModel) { result in
                showAlleycatSheet = false
                Task { await connectAlleycatTarget(result) }
            }
        } else {
            EmptyView()
        }
    }

    private func handleSSHLoginSubmission(
        _ target: ConnectionTarget,
        server: DiscoveredServer
    ) async -> SSHLoginSubmissionOutcome {
        if case .sshThenRemote(let host, let credentials) = target {
            return await startSSHAgentProbe(
                server: server,
                host: host,
                credentials: credentials
            )
        }
        await connectToServer(server, targetOverride: target)
        return .accepted
    }

    private func handleAcceptedSSHLogin() {
        sshServer = nil
    }

    private func handleSSHLoginSheetDismissed() {
        guard let context = pendingSSHAgentContext else { return }
        pendingSSHAgentContext = nil
        sshAgentContext = context
    }

    private func handleManualEntrySheetDismissed() {
        manualWakeTask?.cancel()
        manualWakeTask = nil
        pendingSSHServer = nil
        guard let context = pendingSSHAgentContext else { return }
        pendingSSHAgentContext = nil
        if let appModel = runtimeDependencies.appModel {
            Task { try? await appModel.ssh.sshClose(sessionId: context.sessionId) }
        }
    }

    private func handleAcceptedManualSSHLogin() {
        pendingSSHServer = nil
        if pendingSSHAgentContext == nil {
            showManualEntry = false
        }
    }

    private var liveLifecyclePresentation: DiscoveryLiveLifecyclePresentation? {
        let connectingSnapshot = connectingServer.flatMap { server in
            runtimeDependencies.appModel?.snapshot?.servers.first(where: {
                $0.serverId == server.id
            })
        }
        let progressDetail: String?
        if connectingSnapshot?.currentConnectionStep?.state == .inProgress {
            progressDetail = connectingSnapshot?.connectionProgressDetail
        } else {
            progressDetail = nil
        }
        return DiscoveryLiveLifecyclePresentation.resolve(
            wakingServerName: wakingServer?.name,
            connectingServerName: connectingServer?.name,
            progressDetail: progressDetail,
            failedServerName: connectionRetryState.failedServer?.name,
            failureMessage: connectionRetryState.errorMessage
        )
    }

    private func liveLifecycleCard(
        _ presentation: DiscoveryLiveLifecyclePresentation
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if presentation.status == .disconnected {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if presentation.status == .connected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ProgressView()
                    .tint(LitterTheme.accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.status.title)
                    .litterFont(.subheadline, weight: .semibold)
                    .foregroundStyle(LitterTheme.textPrimary)
                Text(presentation.serverName)
                    .litterFont(.caption, weight: .semibold)
                    .foregroundStyle(LitterTheme.textSecondary)
                Text(presentation.detail)
                    .litterFont(.caption)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LitterTheme.surface.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LitterTheme.accent.opacity(0.28), lineWidth: 0.8)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Server connection lifecycle")
        .accessibilityIdentifier("server-lifecycle-live-root")
        .accessibilityValue(presentation.status.rawValue)
    }

    @ViewBuilder
    private func sshLoginSheet(
        server: DiscoveredServer,
        onAccepted: @escaping () -> Void
    ) -> some View {
        #if DEBUG
        if let checkpointState = debugCheckpointScenario?.sshLoginState {
            SSHLoginSheet(
                server: server,
                checkpointState: checkpointState,
                onSubmit: { target in
                    await handleSSHLoginSubmission(target, server: server)
                },
                onAccepted: onAccepted
            )
        } else {
            SSHLoginSheet(
                server: server,
                runtimeMode: runtimeDependencies.sshLoginRuntimeMode,
                onSubmit: { target in
                    await handleSSHLoginSubmission(target, server: server)
                },
                onAccepted: onAccepted
            )
        }
        #else
        SSHLoginSheet(
            server: server,
            runtimeMode: runtimeDependencies.sshLoginRuntimeMode,
            onSubmit: { target in
                await handleSSHLoginSubmission(target, server: server)
            },
            onAccepted: onAccepted
        )
        #endif
    }

    @ViewBuilder
    private func sshAgentPickerSheet(context: SSHBridgeAgentContext) -> some View {
        if let appModel = liveAppModel(for: "presentSSHAgentPicker") {
            SSHAgentPickerSheet(
                context: context,
                appModel: appModel,
                onConnected: { result in
                    sshAgentContext = nil
                    Task { await connectSSHBridgeTarget(result, baseServer: context.server) }
                },
                onUseCodex: {
                    sshAgentContext = nil
                    Task {
                        try? await appModel.ssh.sshClose(sessionId: context.sessionId)
                        await connectToServer(
                            context.server,
                            targetOverride: .sshThenRemote(host: context.host, credentials: context.credentials)
                        )
                    }
                },
                onCancel: {
                    sshAgentContext = nil
                    Task { try? await appModel.ssh.sshClose(sessionId: context.sessionId) }
                }
            )
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func manualSSHAgentPickerSheet(context: SSHBridgeAgentContext) -> some View {
        if let appModel = liveAppModel(for: "presentManualSSHAgentPicker") {
            SSHAgentPickerSheet(
                context: context,
                appModel: appModel,
                onConnected: { result in
                    pendingSSHAgentContext = nil
                    showManualEntry = false
                    Task { await connectSSHBridgeTarget(result, baseServer: context.server) }
                },
                onUseCodex: {
                    pendingSSHAgentContext = nil
                    showManualEntry = false
                    Task {
                        try? await appModel.ssh.sshClose(sessionId: context.sessionId)
                        await connectToServer(
                            context.server,
                            targetOverride: .sshThenRemote(
                                host: context.host,
                                credentials: context.credentials
                            )
                        )
                    }
                },
                onCancel: {
                    pendingSSHAgentContext = nil
                    showManualEntry = false
                    Task { try? await appModel.ssh.sshClose(sessionId: context.sessionId) }
                }
            )
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var primaryContent: some View {
        #if DEBUG
        if let configurationError = debugCheckpointConfigurationError {
            debugCheckpointConfigurationErrorContent(configurationError)
        } else if let scenario = debugCheckpointScenario,
           scenario.lifecycleState != nil {
            debugServerLifecycleContent
        } else if debugCheckpointScenario?.lf16Substate != nil {
            debugLF16ConnectionRetryContent
        } else if debugCheckpointScenario == .manualServerSubmitted {
            debugManualServerSubmittedContent
        } else {
            chooserContent
        }
        #else
        chooserContent
        #endif
    }

    #if DEBUG
    private var debugCheckpointScenario: ServerLifecycleCheckpointScenario? {
        guard case .scenario(let scenario) = checkpointConfiguration else { return nil }
        return scenario
    }

    private var debugCheckpointConfigurationError: ServerLifecycleCheckpointConfigurationError? {
        guard case .invalid(let error) = checkpointConfiguration else { return nil }
        return error
    }

    private static let debugCheckpointServer = DiscoveredServer(
        id: "ui-test-redacted-server",
        name: "Redacted Test Host",
        hostname: "redacted.invalid",
        port: 8390,
        codexPorts: [8390],
        sshPort: 22,
        source: .manual,
        hasCodexServer: true,
        preferredConnectionMode: .directCodex,
        preferredCodexPort: 8390,
        os: "macOS"
    )

    private static let debugSSHCheckpointServer = DiscoveredServer(
        id: "ui-test-redacted-ssh-server",
        name: "Redacted Test Host",
        hostname: "redacted.invalid",
        port: nil,
        codexPorts: [],
        sshPort: 22,
        source: .ssh,
        hasCodexServer: false,
        preferredConnectionMode: .ssh,
        os: "macOS"
    )

    private static let debugSSHAgentContext = SSHBridgeAgentContext(
        server: debugSSHCheckpointServer,
        sessionId: "ui-test-session",
        host: "redacted.invalid",
        availability: [
            RemoteAgentAvailability(kind: "claude", status: .available),
            RemoteAgentAvailability(kind: "pi", status: .available),
            RemoteAgentAvailability(kind: "opencode", status: .agentCliMissing),
        ],
        credentials: .password(
            username: "checkpoint-user",
            password: "",
            unlockMacosKeychain: false
        ),
        checkpointRuntimeMetadata: [
            debugStableAgentMetadata(name: "claude", displayName: "Claude", sortOrder: 0),
            debugStableAgentMetadata(name: "pi", displayName: "Pi", sortOrder: 1),
        ]
    )

    private static func debugStableAgentMetadata(
        name: String,
        displayName: String,
        sortOrder: Int32
    ) -> AppAgentMetadata {
        AppAgentMetadata(
            name: name,
            displayName: displayName,
            presentation: AppAgentPresentation(
                title: displayName,
                isBeta: false,
                sortOrder: sortOrder,
                description: nil,
                aliases: []
            ),
            capabilities: nil
        )
    }

    private static let debugSlingshotResults = [
        AppSlingshotEnvironment(
            id: "redacted-test-mac",
            connectionUrl: "slingshot://redacted-test-mac",
            displayName: "Redacted Test Mac",
            rawDisplayName: nil,
            name: "Redacted Test Mac",
            hostName: "redacted-mac.invalid",
            online: true,
            busy: false,
            operatingSystem: "macos",
            architecture: "arm64",
            appServerVersion: "0.0-test",
            lastSeenAt: nil
        ),
        AppSlingshotEnvironment(
            id: "redacted-test-linux",
            connectionUrl: "slingshot://redacted-test-linux",
            displayName: "Redacted Test Linux",
            rawDisplayName: nil,
            name: "Redacted Test Linux",
            hostName: "redacted-linux.invalid",
            online: false,
            busy: false,
            operatingSystem: "linux",
            architecture: "x86_64",
            appServerVersion: nil,
            lastSeenAt: nil
        ),
    ]

    @discardableResult
    private func configureDebugCheckpointIfNeeded() -> Bool {
        let configuration = checkpointConfiguration
        if case .disabled = configuration { return false }
        guard !debugCheckpointConfigured else { return true }
        debugCheckpointConfigured = true

        guard case .scenario(let scenario) = configuration else {
            return true
        }

        if scenario.sshLoginState != nil {
            sshServer = Self.debugSSHCheckpointServer
        } else if scenario.sshAgentPickerState != nil {
            sshAgentContext = Self.debugSSHAgentContext
        } else if let state = scenario.manualServerState {
            manualConnectionMode = .codex
            manualCodexURL = state == "invalid"
                ? "https://redacted.invalid"
                : "wss://redacted.invalid/ws"
            if state == "invalid" {
                showManualEntry = true
            } else {
                // Exercise the existing valid submission callback. The Debug
                // connection guard below freezes progress before I/O.
                submitManualCodexEntry()
            }
        } else if let state = scenario.slingshotBrowserState {
            switch state {
            case "loading":
                slingshotIsLoading = true
                slingshotError = nil
                slingshotEnvironments = []
            case "error":
                slingshotIsLoading = false
                slingshotError = "Connected computers could not be loaded. Try again."
                slingshotEnvironments = []
            default:
                slingshotIsLoading = false
                slingshotError = nil
                slingshotEnvironments = Self.debugSlingshotResults
            }
            showSlingshotHosts = true
        } else if let substate = scenario.lf16Substate {
            configureDebugLF16ConnectionRetry(substate)
        }
        return true
    }

    private func configureDebugLF16ConnectionRetry(
        _ substate: DiscoveryConnectionRetryCheckpointSubstate
    ) {
        guard debugConnectionAttemptHook != nil else {
            LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                "DiscoveryView.lf16.missingAttemptHook"
            )
            return
        }
        Task {
            await connectToServer(
                Self.debugLF16ConnectionRetryServer,
                targetOverride: Self.debugLF16ConnectionRetryTarget
            )
            guard substate == .postRetry,
                  connectionRetryState.canRetry else { return }
            retryLastConnection()
        }
    }

    private func debugCheckpointConfigurationErrorContent(
        _ error: ServerLifecycleCheckpointConfigurationError
    ) -> some View {
        Form {
            Section {
                debugCheckpointBanner(issue: "CONFIG", state: "rejected")
                Text(error.rawValue)
                    .litterFont(.caption, weight: .semibold)
                    .foregroundColor(LitterTheme.danger)
                    .accessibilityIdentifier("server-checkpoint-config-error-code")
                Text(error.message)
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textSecondary)
                    .accessibilityIdentifier("server-checkpoint-config-error-message")
            } footer: {
                Text("No fixture or live connection behavior was started.")
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.textMuted)
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("server-checkpoint-config-error-root")
        .accessibilityValue(error.rawValue)
    }

    private var debugDisplayedLifecycleState: String {
        if debugLifecycleRecoveryRequested {
            return "progress"
        }
        return debugCheckpointScenario?.lifecycleState ?? "progress"
    }

    private var debugServerLifecycleContent: some View {
        let lifecyclePresentation = DiscoveryLiveLifecyclePresentation(
            status: DiscoveryLiveLifecycleStatus(rawValue: debugDisplayedLifecycleState)
                ?? .progress,
            serverName: Self.debugCheckpointServer.name,
            detail: Self.debugLifecycleSnapshot(for: debugDisplayedLifecycleState)?
                .connectionProgressDetail
                ?? "Static lifecycle checkpoint"
        )
        return Form {
            Section {
                debugCheckpointBanner(issue: "LF-09", state: debugDisplayedLifecycleState)
                liveLifecycleCard(lifecyclePresentation)
                serverRow(
                    Self.debugCheckpointServer,
                    snapshotOverride: Self.debugLifecycleSnapshot(for: debugDisplayedLifecycleState),
                    isWakingOverride: debugDisplayedLifecycleState == "waking"
                )
                Text(debugDisplayedLifecycleState)
                    .litterFont(.caption, weight: .semibold)
                    .foregroundColor(LitterTheme.textSecondary)
                    .accessibilityIdentifier("server-lifecycle-status")
            } footer: {
                Text("Static Debug fixture. No discovery, wake request, or server connection is performed.")
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.textMuted)
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("server-lifecycle-checkpoint-root")
    }

    private var debugManualServerSubmittedContent: some View {
        Form {
            Section {
                debugCheckpointBanner(issue: "LF-13", state: "submitted")
                serverRow(
                    Self.debugCheckpointServer,
                    snapshotOverride: Self.debugLifecycleSnapshot(for: "progress")
                )
                Text("submitted")
                    .litterFont(.caption, weight: .semibold)
                    .foregroundColor(LitterTheme.textSecondary)
                    .accessibilityIdentifier("manual-server-status")
            } footer: {
                Text("Static Debug fixture. The valid URL is never contacted.")
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.textMuted)
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("manual-server-submitted-root")
    }

    private var debugDisplayedLF16Substate: String {
        if debugLF16CheckpointEvidence.selectedServerID != nil {
            return DiscoveryConnectionRetryCheckpointSubstate.postRetry.rawValue
        }
        if connectingServer?.id == Self.debugLF16ConnectionRetryServer.id {
            return "retrying"
        }
        if connectionRetryState.errorMessage != nil {
            return DiscoveryConnectionRetryCheckpointSubstate.failureAlert.rawValue
        }
        return "failure-dismissed"
    }

    private var debugLF16HookIdentifier: String {
        debugConnectionAttemptHook?.identifier
            ?? "missing-lf-16-fault-hook"
    }

    private var debugLF16ConnectionRetryContent: some View {
        let snapshotState = if debugLF16CheckpointEvidence.selectedServerID != nil {
            "connected"
        } else if connectingServer?.id == Self.debugLF16ConnectionRetryServer.id {
            "progress"
        } else {
            "disconnected"
        }

        return Form {
            Section {
                debugCheckpointBanner(issue: "LF-16", state: debugDisplayedLF16Substate)
                serverRow(
                    Self.debugLF16ConnectionRetryServer,
                    snapshotOverride: Self.debugLifecycleSnapshot(for: snapshotState)
                )
                Text(debugDisplayedLF16Substate)
                    .litterFont(.caption, weight: .semibold)
                    .foregroundColor(LitterTheme.textSecondary)
                    .accessibilityIdentifier("lf16-connection-retry-state")
                    .accessibilityValue(debugDisplayedLF16Substate)
                Text("Connection attempts · \(debugLF16ConnectionAttemptCount)")
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textSecondary)
                    .accessibilityIdentifier("lf16-connection-retry-attempts")
                    .accessibilityValue(String(debugLF16ConnectionAttemptCount))
                Text("Deterministic hook · \(debugLF16HookIdentifier)")
                    .litterFont(.caption2, weight: .semibold)
                    .foregroundColor(.orange)
                    .accessibilityIdentifier("lf16-connection-retry-hook")
                    .accessibilityValue(debugLF16HookIdentifier)
                if let receipt = debugLF16CheckpointEvidence.receipt {
                    Text("Retry completed for the same server target.")
                        .litterFont(.footnote, weight: .semibold)
                        .foregroundColor(LitterTheme.accentStrong)
                        .accessibilityIdentifier("lf16-connection-retry-receipt")
                        .accessibilityValue(receipt.accessibilityValue)
                    Text("Receipt transferred before selection")
                        .litterFont(.caption2)
                        .foregroundColor(LitterTheme.textSecondary)
                        .accessibilityIdentifier("lf16-connection-retry-order")
                        .accessibilityValue(
                            debugLF16CheckpointEvidence.eventOrderAccessibilityValue
                        )
                }
            } footer: {
                Text("Deterministic non-live fault. Retry uses the production retry state machine; live connection, persistence, and navigation remain suppressed.")
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.textMuted)
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("lf16-connection-retry-checkpoint-root")
    }

    private func debugCheckpointBanner(issue: String, state: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DEBUG CHECKPOINT · NON-LIVE")
                .litterFont(.caption2, weight: .semibold)
                .foregroundColor(.orange)
            Text("\(issue) · \(state)")
                .litterFont(.footnote, weight: .semibold)
                .foregroundColor(LitterTheme.textPrimary)
        }
    }

    private static func debugLifecycleSnapshot(for state: String) -> AppServerSnapshot? {
        let health: AppServerHealth
        let transportState: AppServerTransportState
        let progress: AppConnectionProgressSnapshot?

        switch state {
        case "connecting":
            health = .connecting
            transportState = .connecting
            progress = nil
        case "progress":
            health = .connecting
            transportState = .connecting
            progress = AppConnectionProgressSnapshot(
                steps: [
                    AppConnectionStepSnapshot(
                        kind: .connectingToSsh,
                        state: .completed,
                        detail: "Secure transport ready"
                    ),
                    AppConnectionStepSnapshot(
                        kind: .startingAppServer,
                        state: .inProgress,
                        detail: "Starting the redacted test server"
                    ),
                ],
                pendingInstall: false,
                terminalMessage: nil
            )
        case "connected":
            health = .connected
            transportState = .connected
            progress = AppConnectionProgressSnapshot(
                steps: [
                    AppConnectionStepSnapshot(
                        kind: .connected,
                        state: .completed,
                        detail: "Connected to the redacted test server"
                    ),
                ],
                pendingInstall: false,
                terminalMessage: nil
            )
        case "disconnected":
            health = .disconnected
            transportState = .disconnected
            progress = AppConnectionProgressSnapshot(
                steps: [
                    AppConnectionStepSnapshot(
                        kind: .startingAppServer,
                        state: .failed,
                        detail: "The previous redacted connection attempt failed"
                    ),
                ],
                pendingInstall: false,
                terminalMessage: "The previous redacted connection attempt failed"
            )
        default:
            return nil
        }

        return AppServerSnapshot(
            serverId: debugCheckpointServer.id,
            displayName: debugCheckpointServer.name,
            host: debugCheckpointServer.hostname,
            port: debugCheckpointServer.port ?? 0,
            wakeMac: nil,
            isLocal: false,
            health: health,
            transportState: transportState,
            capabilities: AppServerCapabilities(
                canUseTransportActions: true,
                canBrowseDirectories: true,
                canStartThreads: true,
                canResumeThreads: true,
                supportsTurnPagination: true
            ),
            account: nil,
            requiresOpenaiAuth: false,
            rateLimits: nil,
            rateLimitsByRuntime: [],
            availableModels: nil,
            agentRuntimes: [],
            connectionProgress: progress,
            usageStats: nil,
            codexVersion: nil
        )
    }
    #endif

    // MARK: - Chooser

    @ViewBuilder
    private var chooserContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pick how you want to connect.")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textSecondary)
                    .padding(.top, 8)

                if let liveLifecyclePresentation {
                    liveLifecycleCard(liveLifecyclePresentation)
                }

                chooserCard(
                    title: "Connect with Hermes",
                    subtitle: "Copy a setup prompt into Hermes. Learnfold receives the pairing securely and asks before connecting.",
                    badge: "RECOMMENDED",
                    icon: "sparkles",
                    supportedAgents: Self.kittylitterAgents,
                    isRecommended: true,
                    accessibilityID: "discovery.chooser.kittylitter"
                ) {
                    showAlleycatSheet = true
                }

                chooserCard(
                    title: "Connected Computer",
                    subtitle: "Connect to a computer already signed in and running Codex for this ChatGPT account.",
                    badge: nil,
                    icon: "desktopcomputer",
                    supportedAgents: [AgentRuntimeKind.codex],
                    isRecommended: false,
                    accessibilityID: "discovery.chooser.slingshot"
                ) {
                    showSlingshotHosts = true
                }

                chooserCard(
                    title: "SSH or Codex URL",
                    subtitle: "Connect over SSH or paste a ws:// codex URL.",
                    badge: nil,
                    icon: "terminal",
                    supportedAgents: [AgentRuntimeKind.codex],
                    isRecommended: false,
                    accessibilityID: "discovery.chooser.manual"
                ) {
                    showManualEntry = true
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    /// Canonical agent list shown on the kittylitter chooser card.
    /// Mirrors the splash carousel order so cold-start branding stays
    /// consistent. New agents added in the alleycat manifest still
    /// surface on connected hosts via the real metadata store; this list
    /// only seeds the pre-pair preview.
    private static let kittylitterAgents: [AgentRuntimeKind] = [
        "codex",
        "pi",
        "amp",
        "opencode",
        "claude",
        "droid",
        "hermes",
        "devin",
        "grok",
    ]

    private func chooserCard(
        title: String,
        subtitle: String,
        badge: String?,
        icon: String,
        supportedAgents: [AgentRuntimeKind],
        isRecommended: Bool,
        accessibilityID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(LitterTheme.accent)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(LitterTheme.accent.opacity(isRecommended ? 0.16 : 0.10))
                        )
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(title)
                                .litterFont(.subheadline, weight: .semibold)
                                .foregroundColor(LitterTheme.textPrimary)
                            if let badge {
                                Text(badge)
                                    .litterFont(.caption2, weight: .semibold)
                                    .foregroundColor(LitterTheme.accentStrong)
                                    .tracking(0.5)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(LitterTheme.accent.opacity(0.14))
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(LitterTheme.accent.opacity(0.45), lineWidth: 0.6)
                                    )
                            }
                        }
                        Text(subtitle)
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(LitterTheme.textMuted)
                        .padding(.top, 10)
                }

                if !supportedAgents.isEmpty {
                    supportedAgentsStrip(supportedAgents)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LitterTheme.surface.opacity(isRecommended ? 0.85 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        LitterTheme.accent.opacity(isRecommended ? 0.45 : 0.18),
                        lineWidth: isRecommended ? 1.0 : 0.8
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
    }

    @ViewBuilder
    private func supportedAgentsStrip(_ agents: [AgentRuntimeKind]) -> some View {
        HStack(spacing: 8) {
            Text("Works with")
                .litterFont(.caption2)
                .foregroundColor(LitterTheme.textMuted)
                .tracking(0.4)
                .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 5) {
                ForEach(agents, id: \.self) { agent in
                    AgentIconView(kind: agent, size: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Sections (legacy discovery list, retained for sheet plumbing)

    private var allServers: [DiscoveredServer] {
        localServers + networkServers
    }

    private var serversSection: some View {
        Section {
            if allServers.isEmpty {
                if discovery.isInitialLoad {
                    HStack {
                        ProgressView().tint(LitterTheme.textMuted).scaleEffect(0.7)
                        Text("Scanning...")
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textMuted)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No servers found")
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textMuted)
                        if discovery.isScanning {
                            Text("Still searching network...")
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
            } else {
                ForEach(allServers) { server in
                    serverRow(server)
                }
            }

            if let notice = discovery.tailscaleDiscoveryNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "network.slash")
                        .foregroundColor(LitterTheme.textSecondary)
                        .frame(width: 18, alignment: .top)
                    Text(notice)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }
        } header: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Servers")
                        .foregroundColor(LitterTheme.textSecondary)
                    Spacer()
                    if discovery.isScanning, let label = discovery.scanProgressLabel {
                        Text(label)
                            .litterFont(.caption2)
                            .foregroundColor(LitterTheme.textMuted)
                    }
                }
                if discovery.isScanning {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(LitterTheme.surface)
                                .frame(height: 3)
                            Capsule()
                                .fill(LitterTheme.accent)
                                .frame(
                                    width: geo.size.width * CGFloat(discovery.scanProgress),
                                    height: 3
                                )
                                .animation(.easeInOut(duration: 0.25), value: discovery.scanProgress)
                        }
                    }
                    .frame(height: 3)
                }
            }
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    // MARK: - Row

    private func serverRow(
        _ server: DiscoveredServer,
        snapshotOverride: AppServerSnapshot? = nil,
        isConnectingOverride: Bool = false,
        isWakingOverride: Bool = false
    ) -> some View {
        let rowIdentifier = serverRowAccessibilityIdentifier(for: server)
        let serverSnapshot = snapshotOverride
            ?? runtimeDependencies.appModel?.snapshot?.servers.first(where: { $0.serverId == server.id })
        let rowStatus = serverRowStatusLabel(
            server: server,
            snapshot: serverSnapshot,
            isConnectingOverride: isConnectingOverride,
            isWakingOverride: isWakingOverride
        )
        let isRowWaking = isWakingOverride || wakingServer?.id == server.id
        let isRowConnecting = isConnectingOverride || connectingServer?.id == server.id
        let snapshotIsDisconnected = serverSnapshot?.health == .disconnected
        let snapshotProgress = snapshotIsDisconnected ? nil : progressTag(for: serverSnapshot)
        let hasActiveSnapshotProgress = !snapshotIsDisconnected
            && serverSnapshot?.currentConnectionStep?.state == .inProgress
        return Button {
            handleTap(server)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: serverIconName(for: server))
                    .foregroundColor(server.hasCodexServer ? LitterTheme.accent : LitterTheme.textSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                    Text(serverSubtitle(server, snapshotOverride: serverSnapshot))
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                }
                Spacer()
                if isRowWaking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(LitterTheme.accent)
                        statusTag(label: "waking", color: .orange)
                    }
                    .accessibilityIdentifier("\(rowIdentifier).status")
                } else if let progressTag = snapshotProgress {
                    HStack(spacing: 6) {
                        if hasActiveSnapshotProgress {
                            ProgressView().controlSize(.small).tint(LitterTheme.accent)
                        }
                        statusTag(label: progressTag.label, color: progressTag.color)
                    }
                    .accessibilityIdentifier("\(rowIdentifier).status")
                } else if isRowConnecting || serverSnapshot?.health == .connecting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(LitterTheme.accent)
                        statusTag(label: "connecting", color: LitterTheme.accent)
                    }
                    .accessibilityIdentifier("\(rowIdentifier).status")
                } else if let health = serverSnapshot?.health,
                          health != .disconnected {
                    statusTag(label: health.displayLabel.lowercased(), color: health.accentColor)
                        .accessibilityIdentifier("\(rowIdentifier).status")
                } else {
                    HStack(spacing: 6) {
                        statusTag(label: "disconnected", color: LitterTheme.textMuted)
                        Image(systemName: "chevron.right")
                            .foregroundColor(LitterTheme.textMuted)
                            .font(.caption)
                    }
                    .accessibilityIdentifier("\(rowIdentifier).status")
                }
            }
        }
        .accessibilityIdentifier(rowIdentifier)
        .accessibilityValue(rowStatus)
        .accessibilityHint(serverRowAccessibilityHint(status: rowStatus))
        .disabled(
            isConnectingOverride
                || isWakingOverride
                || connectingServer != nil
                || wakingServer != nil
                || serverSnapshot?.health == .connecting
                || hasActiveSnapshotProgress
        )
        .contextMenu {
            if !runtimeDependencies.isInertCheckpoint, server.source != .local {
                Button {
                    renameText = server.name
                    renameTarget = server
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
        }
    }

    private func serverRowStatusLabel(
        server: DiscoveredServer,
        snapshot: AppServerSnapshot?,
        isConnectingOverride: Bool,
        isWakingOverride: Bool
    ) -> String {
        if isWakingOverride || wakingServer?.id == server.id {
            return "waking"
        }
        if snapshot?.health != .disconnected,
           let progressTag = progressTag(for: snapshot) {
            return progressTag.label
        }
        if isConnectingOverride
            || connectingServer?.id == server.id
            || snapshot?.health == .connecting {
            return "connecting"
        }
        if let health = snapshot?.health, health != .disconnected {
            return health.displayLabel.lowercased()
        }
        return "disconnected"
    }

    private func serverRowAccessibilityHint(status: String) -> String {
        switch status {
        case "connecting":
            return "Connection is in progress."
        case "waking":
            return "A wake request is in progress."
        case "disconnected":
            return "Double tap to reconnect or wake this server."
        case "connected":
            return "Double tap to open this server."
        default:
            return "Connection progress: \(status)."
        }
    }

    private func serverRowAccessibilityIdentifier(for server: DiscoveredServer) -> String {
        let kind = server.hasCodexServer ? "codex" : "ssh"
        let host = server.hostname
            .lowercased()
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "discovery.server.\(kind).\(host)"
    }

    private func serverSubtitle(
        _ server: DiscoveredServer,
        snapshotOverride: AppServerSnapshot? = nil
    ) -> String {
        if server.source == .local { return "In-process server" }
        let snapshot = snapshotOverride ?? connectedSnapshot(for: server)
        if let progressDetail = snapshot?.connectionProgressDetail,
           !progressDetail.isEmpty {
            return progressDetail
        }
        let displayHost = snapshot?.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? snapshot!.host
            : server.hostname
        var parts = [displayHost]
        if let os = server.os {
            parts.append(" - \(os)")
        }
        let directPorts = server.availableDirectCodexPorts.map(String.init)
        if !directPorts.isEmpty {
            parts.append(" - codex \(directPorts.joined(separator: ", "))")
        }
        if server.canConnectViaSSH {
            parts.append(" - ssh \(server.resolvedSSHPort)")
        }
        return parts.joined()
    }

    @ViewBuilder
    private func statusTag(label: String, color: Color) -> some View {
        Text(label)
            .litterFont(.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    private func connectedSnapshot(for server: DiscoveredServer) -> AppServerSnapshot? {
        runtimeDependencies.appModel?.snapshot?.servers.first {
            $0.serverId == server.id && !$0.isLocal
        }
    }

    // MARK: - Actions

    private func handleTap(_ server: DiscoveredServer) {
        Task { await handleTapAsync(server) }
    }

    private func navigateAfterConnect(
        _ server: DiscoveredServer,
        lifecycleEpoch: UUID? = nil
    ) {
        if let lifecycleEpoch {
            guard connectionLifecycleGate.isCurrent(lifecycleEpoch) else { return }
        } else {
            guard connectionLifecycleGate.isActive else { return }
        }
        #if DEBUG
        publishConnectionRetryEvidenceReceipt()
        #endif
        guard let appModel = liveAppModel(for: "navigateAfterConnect") else { return }
        guard let snapshot = appModel.snapshot?.servers.first(where: { $0.serverId == server.id }) else {
            onServerSelected?(server)
            return
        }
        if snapshot.isLocal, snapshot.account == nil {
            guard let appState = liveAppState(for: "navigateAfterConnect.settings") else { return }
            appState.showSettings = true
            return
        }
        onServerSelected?(server)
    }

    #if DEBUG
    private func publishConnectionRetryEvidenceReceipt() {
        guard let appState = runtimeDependencies.appState else { return }
        connectionRetryState.transferPostRetryEvidenceReceipt { evidenceReceipt in
            appState.recordDiscoveryConnectionRetryEvidenceReceipt(evidenceReceipt)
        }
    }
    #endif

    @MainActor
    private func handleTapAsync(_ server: DiscoveredServer) async {
        #if DEBUG
        if let lifecycleState = debugCheckpointScenario?.lifecycleState,
           server.id == Self.debugCheckpointServer.id {
            if lifecycleState == "disconnected" {
                debugLifecycleRecoveryRequested = true
                connectingServer = server
            }
            return
        }
        #endif
        guard let appModel = liveAppModel(for: "handleServerTap") else { return }
        if appModel.snapshot?.servers.first(where: { $0.serverId == server.id })?.health == .connected {
            navigateAfterConnect(server)
            return
        }

        let prepared = await prepareServerForSelection(server)
        if prepared.server.requiresConnectionChoice {
            connectionChoiceServer = prepared.server
        } else if prepared.server.hasCodexServer, prepared.server.connectionTarget != nil {
            await connectToServer(prepared.server)
        } else if prepared.canAttemptSSH {
            sshServer = prepared.server.withConnectionPreference(.ssh)
        } else {
            connectionRetryState.presentNonRetryableError(
                "Server did not respond after wake attempt. Enable Wake for network access on the Mac."
            )
        }
    }

    private func prepareServerForSelection(_ server: DiscoveredServer) async -> (server: DiscoveredServer, canAttemptSSH: Bool) {
        guard server.source != .local else {
            return (server, true)
        }

        wakingServer = server
        defer { wakingServer = nil }

        let wakeResult = await waitForWakeSignal(
            host: server.hostname,
            preferredCodexPort: server.hasCodexServer ? server.port : nil,
            preferredSSHPort: server.sshPort,
            timeout: server.hasCodexServer ? 12.0 : 18.0,
            wakeMAC: server.wakeMAC
        )

        switch wakeResult {
        case .codex(let port):
            return (
                DiscoveredServer(
                    id: server.id,
                    name: server.name,
                    hostname: server.hostname,
                    port: port,
                    codexPorts: [port] + server.codexPorts.filter { $0 != port },
                    sshPort: server.sshPort,
                    source: server.source,
                    hasCodexServer: true,
                    wakeMAC: server.wakeMAC,
                    sshPortForwardingEnabled: server.sshPortForwardingEnabled,
                    preferredConnectionMode: server.preferredConnectionMode,
                    preferredCodexPort: port
                ),
                true
            )
        case .ssh(let sshPort):
            return (
                DiscoveredServer(
                    id: server.id,
                    name: server.name,
                    hostname: server.hostname,
                    port: nil,
                    codexPorts: server.codexPorts,
                    sshPort: sshPort,
                    source: server.source,
                    hasCodexServer: false,
                    wakeMAC: server.wakeMAC,
                    sshPortForwardingEnabled: server.sshPortForwardingEnabled,
                    preferredConnectionMode: .ssh
                ),
                true
            )
        case .none:
            // Don't hard-block when wake probing is inconclusive; continue with
            // normal connect/SSH flow so users can still attempt recovery.
            return (server, true)
        }
    }

    private enum WakeSignalResult {
        case codex(UInt16)
        case ssh(UInt16)
        case none
    }

    private func waitForWakeSignal(
        host: String,
        preferredCodexPort: UInt16?,
        preferredSSHPort: UInt16?,
        timeout: TimeInterval,
        wakeMAC: String?
    ) async -> WakeSignalResult {
        let codexPorts = orderedCodexPorts(preferred: preferredCodexPort)
        let sshPorts = orderedSSHPorts(preferred: preferredSSHPort)
        let deadline = Date().addingTimeInterval(max(timeout, 0.5))
        var lastWakePacketAt = Date.distantPast

        while Date() < deadline, !Task.isCancelled {
            if let wakeMAC, Date().timeIntervalSince(lastWakePacketAt) >= 2.0 {
                sendWakeMagicPacket(to: wakeMAC, hostHint: host)
                lastWakePacketAt = Date()
            }

            for port in codexPorts {
                if await isPortOpen(host: host, port: port, timeout: 0.7) {
                    return .codex(port)
                }
            }

            for port in sshPorts {
                if await isPortOpen(host: host, port: port, timeout: 0.7) {
                    return .ssh(port)
                }
            }

            try? await Task.sleep(for: .milliseconds(350))
        }

        return .none
    }

    private func orderedCodexPorts(preferred: UInt16?) -> [UInt16] {
        var ports = [UInt16]()
        if let preferred {
            ports.append(preferred)
        }
        ports.append(contentsOf: [8390, 9234, 4222])

        var seen = Set<UInt16>()
        return ports.filter { seen.insert($0).inserted }
    }

    private func orderedSSHPorts(preferred: UInt16?) -> [UInt16] {
        var ports = [UInt16]()
        if let preferred {
            ports.append(preferred)
        }
        ports.append(22)

        var seen = Set<UInt16>()
        return ports.filter { seen.insert($0).inserted }
    }

    private func sendWakeMagicPacket(to wakeMAC: String, hostHint: String) {
        guard let macBytes = macBytes(from: wakeMAC) else { return }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }

        let targets = wakeBroadcastTargets(for: hostHint)
        for target in targets {
            sendBroadcastUDP(packet: packet, host: target, port: 9)
            sendBroadcastUDP(packet: packet, host: target, port: 7)
        }
    }

    private func macBytes(from normalizedMAC: String) -> [UInt8]? {
        let compact = normalizedMAC.replacingOccurrences(of: ":", with: "")
        guard compact.count == 12 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(6)
        var index = compact.startIndex
        for _ in 0..<6 {
            let next = compact.index(index, offsetBy: 2)
            let chunk = compact[index..<next]
            guard let byte = UInt8(chunk, radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private func wakeBroadcastTargets(for host: String) -> [String] {
        var targets = ["255.255.255.255"]
        let parts = host.split(separator: ".")
        if parts.count == 4,
           let _ = Int(parts[0]),
           let _ = Int(parts[1]),
           let _ = Int(parts[2]),
           let _ = Int(parts[3]) {
            targets.append("\(parts[0]).\(parts[1]).\(parts[2]).255")
        }
        return Array(Set(targets))
    }

    private func sendBroadcastUDP(packet: Data, host: String, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var enabled: Int32 = 1
        withUnsafePointer(to: &enabled) { enabledPtr in
            _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, enabledPtr, socklen_t(MemoryLayout<Int32>.size))
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        host.withCString { cString in
            _ = inet_pton(AF_INET, cString, &addr.sin_addr)
        }

        packet.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var destination = addr
            withUnsafePointer(to: &destination) { destinationPtr in
                destinationPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    _ = sendto(fd, base, packet.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func isPortOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }

            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let gate = WakeProbeResumeGate()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.markResumed() {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if gate.markResumed() {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if gate.markResumed() {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func connectToServer(_ server: DiscoveredServer, targetOverride: ConnectionTarget? = nil) async {
        guard connectingServer == nil,
              let lifecycleEpoch = connectionLifecycleGate.currentEpoch else { return }

        guard let target = targetOverride ?? server.connectionTarget else {
            connectionRetryState.presentNonRetryableError("Server requires SSH login")
            return
        }

        let attempt = DiscoveryConnectionAttempt(server: server, target: target)
        guard connectionRetryState.begin(attempt) else { return }
        connectingServer = server
        guard let task = startConnectionTask(
            attempt,
            lifecycleEpoch: lifecycleEpoch
        ) else { return }
        await task.value
        clearConnectionTaskIfCurrent(runID: attempt.runID)
    }

    private func retryLastConnection() {
        guard connectingServer == nil,
              let lifecycleEpoch = connectionLifecycleGate.currentEpoch,
              let attempt = connectionRetryState.beginRetry() else { return }
        connectingServer = attempt.server
        startConnectionTask(attempt, lifecycleEpoch: lifecycleEpoch)
    }

    @discardableResult
    private func startConnectionTask(
        _ attempt: DiscoveryConnectionAttempt,
        lifecycleEpoch: UUID
    ) -> Task<Void, Never>? {
        guard connectionLifecycleGate.isCurrent(lifecycleEpoch) else { return nil }
        connectionTask?.cancel()
        let task = Task {
            await performConnectionAttempt(
                attempt,
                lifecycleEpoch: lifecycleEpoch
            )
        }
        connectionTask = task
        connectionTaskRunID = attempt.runID
        return task
    }

    private func clearConnectionTaskIfCurrent(runID: UUID) {
        guard connectionTaskRunID == runID else { return }
        connectionTask = nil
        connectionTaskRunID = nil
    }

    private func isCurrentConnectionLifecycle(_ lifecycleEpoch: UUID) -> Bool {
        connectionLifecycleGate.isCurrent(lifecycleEpoch) && !Task.isCancelled
    }

    private func performConnectionAttempt(
        _ attempt: DiscoveryConnectionAttempt,
        lifecycleEpoch: UUID
    ) async {
        defer { clearConnectionTaskIfCurrent(runID: attempt.runID) }
        guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
        let server = attempt.server
        let target = attempt.target

        #if DEBUG
        if debugCheckpointScenario == .manualServerSubmitted {
            // The sheet exercised the production submission path. Hold the
            // resulting progress projection without contacting the URL.
            return
        }
        if debugCheckpointScenario?.lf16Substate != nil,
           server.id == Self.debugLF16ConnectionRetryServer.id,
           let debugConnectionAttemptHook {
            await performDebugLF16ConnectionRetryAttempt(
                attempt,
                lifecycleEpoch: lifecycleEpoch,
                hook: debugConnectionAttemptHook
            )
            return
        }
        #endif

        guard let appModel = liveAppModel(for: "performConnectionAttempt") else {
            guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
            failConnectionAttempt(
                attempt,
                message: "Live connections are disabled for this checkpoint."
            )
            return
        }

        let connectedServerId: String
        let startedAsyncBootstrap: Bool
        do {
            switch target {
            case .local:
                startedAsyncBootstrap = false
                connectedServerId = try await appModel.serverBridge.connectLocalServer(
                    serverId: server.id,
                    displayName: server.name,
                    host: "127.0.0.1",
                    port: 0
                )
                guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
                await appModel.restoreStoredLocalAuthState(serverId: server.id)
                guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
                SavedServerStore.remember(server)
            case .remote(let host, let port):
                startedAsyncBootstrap = false
                connectedServerId = try await appModel.serverBridge.connectRemoteServer(
                    serverId: server.id,
                    displayName: server.name,
                    host: host,
                    port: port
                )
                guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
                SavedServerStore.remember(server.withConnectionPreference(.directCodex, codexPort: port))
            case .remoteURL(let url):
                startedAsyncBootstrap = false
                if url.scheme?.lowercased() == "slingshot" {
                    let tokens = try await ChatGPTOAuth.loadStoredOrRefreshedTokens()
                    guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
                    do {
                        connectedServerId = try await appModel.serverBridge.connectRemoteSlingshotUrlServer(
                            serverId: server.id,
                            displayName: server.name,
                            connectionUrl: url.absoluteString,
                            accessToken: tokens.accessToken,
                            accountId: tokens.accountID,
                            stepUpToken: ""
                        )
                        guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
                    } catch {
                        guard ChatGPTOAuth.isRemoteControlAuthorizationRequired(error) else {
                            throw error
                        }
                        let stepUpToken = try await ChatGPTOAuth.remoteControlEnrollmentStepUpToken()
                        guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
                        connectedServerId = try await appModel.serverBridge.connectRemoteSlingshotUrlServer(
                            serverId: server.id,
                            displayName: server.name,
                            connectionUrl: url.absoluteString,
                            accessToken: tokens.accessToken,
                            accountId: tokens.accountID,
                            stepUpToken: stepUpToken
                        )
                        guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
                    }
                } else {
                    connectedServerId = try await appModel.serverBridge.connectRemoteUrlServer(
                        serverId: server.id,
                        displayName: server.name,
                        websocketUrl: url.absoluteString
                    )
                    guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
                }
                SavedServerStore.remember(server)
            case .sshThenRemote(let host, let credentials):
                startedAsyncBootstrap = true
                connectedServerId = try await connectViaSSH(server: server, host: host, credentials: credentials)
                guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
                SavedServerStore.remember(
                    server.withConnectionPreference(.ssh)
                )
            }
        } catch {
            guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
            failConnectionAttempt(attempt, message: error.localizedDescription)
            return
        }
        guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
        if startedAsyncBootstrap {
            pendingAutoNavigateServerId = connectedServerId
            pendingAutoNavigateServer = server
            pendingAutoNavigateAttempt = attempt
            pendingAutoNavigateLifecycleEpoch = lifecycleEpoch
        }

        await appModel.refreshSnapshot()
        guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }

        if startedAsyncBootstrap {
            // `refreshSnapshot()` may publish while this task is suspended. The
            // pending attempt is installed first so onChange can consume that
            // update; this immediate reconciliation also covers a refresh that
            // completes without another observable snapshot transition.
            reconcilePendingAutoNavigation(with: appModel.snapshot)
            return
        }
        if appModel.snapshot?.servers.first(where: { $0.serverId == connectedServerId })?.health == .connected {
            if finishConnectionAttempt(attempt) {
                navigateAfterConnect(server, lifecycleEpoch: lifecycleEpoch)
            }
        } else {
            failConnectionAttempt(attempt, message: "Failed to connect")
        }
    }

    private func reconcilePendingAutoNavigation(with snapshot: AppSnapshotRecord?) {
        guard let pendingAutoNavigateServerId,
              let pendingAutoNavigateAttempt,
              let pendingAutoNavigateLifecycleEpoch,
              connectionLifecycleGate.isCurrent(pendingAutoNavigateLifecycleEpoch) else {
            return
        }
        let serverSnapshot = snapshot?.serverSnapshot(for: pendingAutoNavigateServerId)
        let resolution = DiscoveryPendingConnectionResolution.resolve(
            health: serverSnapshot?.health,
            terminalMessage: serverSnapshot?.connectionProgress?.terminalMessage
        )

        switch resolution {
        case .pending:
            return
        case .connected:
            let server = pendingAutoNavigateServer ?? pendingAutoNavigateAttempt.server
            self.pendingAutoNavigateServerId = nil
            self.pendingAutoNavigateServer = nil
            self.pendingAutoNavigateAttempt = nil
            self.pendingAutoNavigateLifecycleEpoch = nil
            if finishConnectionAttempt(pendingAutoNavigateAttempt) {
                navigateAfterConnect(
                    server,
                    lifecycleEpoch: pendingAutoNavigateLifecycleEpoch
                )
            }
        case .failed(let message):
            self.pendingAutoNavigateServerId = nil
            self.pendingAutoNavigateServer = nil
            self.pendingAutoNavigateAttempt = nil
            self.pendingAutoNavigateLifecycleEpoch = nil
            failConnectionAttempt(pendingAutoNavigateAttempt, message: message)
        }
    }

    private func failConnectionAttempt(_ attempt: DiscoveryConnectionAttempt, message: String) {
        let safeMessage = DiscoveryConnectionFailurePresentation.message(for: message)
        guard connectionRetryState.fail(attempt, message: safeMessage) else { return }
        connectingServer = nil
    }

    @discardableResult
    private func finishConnectionAttempt(_ attempt: DiscoveryConnectionAttempt) -> Bool {
        guard connectionRetryState.complete(attempt) else { return false }
        connectingServer = nil
        return true
    }

    #if DEBUG
    private static let debugLF16ConnectionRetryServer = DiscoveredServer(
        id: "ui-test-connection-retry",
        name: "Retry Test Server",
        hostname: "retry-target.example",
        port: 9443,
        codexPorts: [9443],
        source: .manual,
        hasCodexServer: true,
        preferredConnectionMode: .directCodex,
        preferredCodexPort: 9443
    )

    private static let debugLF16ConnectionRetryTarget = ConnectionTarget.remote(
        host: "retry-target.example",
        port: 9443
    )

    private func performDebugLF16ConnectionRetryAttempt(
        _ attempt: DiscoveryConnectionAttempt,
        lifecycleEpoch: UUID,
        hook: DiscoveryConnectionRetryCheckpointAttemptHook
    ) async {
        debugLF16ConnectionAttemptCount += 1
        let result = await hook.result(
            for: attempt,
            attemptNumber: debugLF16ConnectionAttemptCount
        )
        guard isCurrentConnectionLifecycle(lifecycleEpoch) else { return }
        switch result {
        case .failure(let message):
            failConnectionAttempt(attempt, message: message)
        case .success:
            guard finishConnectionAttempt(attempt) else { return }
            guard connectionRetryState.transferPostRetryEvidenceReceipt(
                to: { receipt in
                    debugLF16CheckpointEvidence.receive(receipt)
                }
            ) else { return }
            _ = debugLF16CheckpointEvidence.recordSelection(
                serverID: attempt.server.id
            )
        }
    }
    #endif

    /// Called by `AlleycatAddServerSheet` after the sheet has already opened a
    /// fully connected ServerSession. Persist the stable node/agent metadata
    /// and navigate; the token stays in Keychain.
    private func connectAlleycatTarget(_ result: AlleycatConnectedTarget) async {
        guard let appModel = liveAppModel(for: "connectAlleycatTarget") else { return }
        let synthesized = DiscoveredServer(
            id: result.serverId,
            name: result.displayName,
            hostname: result.nodeId,
            port: nil,
            codexPorts: [],
            sshPort: nil,
            source: .manual,
            hasCodexServer: true,
            wakeMAC: nil,
            sshPortForwardingEnabled: false,
            websocketURL: nil,
            preferredConnectionMode: nil,
            preferredCodexPort: nil,
            os: nil,
            sshBanner: nil
        )
        SavedServerStore.rememberAlleycat(
            synthesized,
            nodeId: result.nodeId,
            relay: result.params.relay,
            agentName: result.agentName,
            agentWire: alleycatWireStorageValue(result.agentWire)
        )
        await appModel.refreshSnapshot()
        if appModel.snapshot?.servers.first(where: { $0.serverId == result.serverId })?.health == .connected {
            navigateAfterConnect(synthesized)
        }
    }

    private func alleycatWireStorageValue(_ wire: AppAlleycatAgentWire) -> String {
        switch wire {
        case .websocket:
            return "websocket"
        case .jsonl:
            return "jsonl"
        }
    }

    private func connectViaSSH(
        server: DiscoveredServer,
        host: String,
        credentials: SSHCredentials
    ) async throws -> String {
        try await sshConnectAndConnectServer(
            serverId: server.id,
            displayName: server.name,
            host: host,
            credentials: credentials,
            port: server.resolvedSSHPort
        )
    }

    private func startSSHAgentProbe(
        server: DiscoveredServer,
        host: String,
        credentials: SSHCredentials
    ) async -> SSHLoginSubmissionOutcome {
        guard connectingServer == nil else { return .inProgress }
        connectingServer = server
        connectionRetryState.dismissError()

        #if DEBUG
        if debugCheckpointScenario == .sshLoginAuthError {
            await Task.yield()
            return .inProgress
        }
        if debugCheckpointScenario == .sshLoginEmpty {
            connectingServer = nil
            return .rejected(message: "Enter valid SSH credentials.")
        }
        #endif

        guard let appModel = liveAppModel(for: "startSSHAgentProbe") else {
            connectingServer = nil
            return .rejected(message: "Live SSH is disabled for this checkpoint.")
        }

        var openedSessionID: String?
        do {
            let session = try await openSSHSession(
                host: host,
                port: server.resolvedSSHPort,
                credentials: credentials
            )
            openedSessionID = session.sessionId
            let availability = try await appModel.ssh.sshProbeRemoteAgents(sessionId: session.sessionId)
            let bridgeAgents = availability.filter {
                // SSH bridge bootstrap can launch claude / pi / opencode
                // on the remote; everything else (codex, amp, droid,
                // hermes, anything new) only reaches the host via the
                // alleycat pairing path.
                guard $0.status == .available else { return false }
                if let supports = $0.kind.metadata?.capabilities?.supportsSshBridge {
                    return supports && $0.kind != "codex"
                }
                switch $0.kind {
                case "claude", "pi", "opencode": return true
                default: return false
                }
            }
            connectingServer = nil
            guard !bridgeAgents.isEmpty else {
                try? await appModel.ssh.sshClose(sessionId: session.sessionId)
                await connectToServer(server, targetOverride: .sshThenRemote(host: host, credentials: credentials))
                return .accepted
            }
            pendingSSHAgentContext = SSHBridgeAgentContext(
                server: server,
                sessionId: session.sessionId,
                host: session.normalizedHost,
                availability: availability,
                credentials: credentials
            )
            return .accepted
        } catch {
            connectingServer = nil
            if let openedSessionID {
                try? await appModel.ssh.sshClose(sessionId: openedSessionID)
            }
            return .rejected(message: error.localizedDescription)
        }
    }

    private func openSSHSession(
        host: String,
        port: UInt16,
        credentials: SSHCredentials
    ) async throws -> AppSshSessionResult {
        guard let appModel = liveAppModel(for: "openSSHSession") else {
            throw CancellationError()
        }
        switch credentials {
        case .password(let username, let password, let unlockMacosKeychain):
            return try await appModel.ssh.sshOpenSession(
                host: host,
                port: port,
                username: username,
                password: password,
                privateKeyPem: nil,
                passphrase: nil,
                unlockMacosKeychain: unlockMacosKeychain,
                acceptUnknownHost: true
            )
        case .key(let username, let privateKey, let passphrase):
            return try await appModel.ssh.sshOpenSession(
                host: host,
                port: port,
                username: username,
                password: nil,
                privateKeyPem: privateKey,
                passphrase: passphrase,
                unlockMacosKeychain: false,
                acceptUnknownHost: true
            )
        }
    }

    private func connectSSHBridgeTarget(
        _ result: SSHBridgeAgentResult,
        baseServer: DiscoveredServer
    ) async {
        guard let appModel = liveAppModel(for: "connectSSHBridgeTarget") else { return }
        let synthesized = DiscoveredServer(
            id: result.serverId,
            name: result.displayName,
            hostname: result.host,
            port: nil,
            codexPorts: [],
            sshPort: result.port,
            source: .ssh,
            hasCodexServer: true,
            wakeMAC: baseServer.wakeMAC,
            sshPortForwardingEnabled: false,
            websocketURL: nil,
            preferredConnectionMode: .ssh,
            preferredCodexPort: nil,
            os: baseServer.os,
            sshBanner: baseServer.sshBanner
        )
        SavedServerStore.rememberSSHBridge(synthesized, runtimeKinds: result.runtimeKinds)
        await SshSessionStore.shared.record(sessionId: result.sessionId, for: result.serverId)
        await appModel.refreshSnapshot()
        if appModel.snapshot?.servers.first(where: { $0.serverId == result.serverId })?.health == .connected {
            navigateAfterConnect(synthesized)
        }
    }

    private func sshConnectAndConnectServer(
        serverId: String,
        displayName: String,
        host: String,
        credentials: SSHCredentials,
        port: UInt16
    ) async throws -> String {
        guard let appModel = liveAppModel(for: "sshConnectAndConnectServer") else {
            throw CancellationError()
        }
        let authMethod: String = switch credentials {
        case .password:
            "password"
        case .key:
            "private_key"
        }
        LLog.trace(
            "discovery",
            "starting guided SSH connect",
            fields: [
                "serverId": serverId,
                "host": host,
                "sshPort": Int(port),
                "authMethod": authMethod
            ]
        )
        switch credentials {
        case .password(let username, let password, let unlockMacosKeychain):
            return try await appModel.serverBridge.startRemoteOverSshConnect(
                serverId: serverId,
                displayName: displayName,
                host: host,
                port: port,
                username: username,
                password: password,
                privateKeyPem: nil,
                passphrase: nil,
                unlockMacosKeychain: unlockMacosKeychain,
                acceptUnknownHost: true,
                workingDir: nil
            )
        case .key(let username, let privateKey, let passphrase):
            return try await appModel.serverBridge.startRemoteOverSshConnect(
                serverId: serverId,
                displayName: displayName,
                host: host,
                port: port,
                username: username,
                password: nil,
                privateKeyPem: privateKey,
                passphrase: passphrase,
                unlockMacosKeychain: false,
                acceptUnknownHost: true,
                workingDir: nil
            )
        }
    }

    // MARK: - Connected Computers

    private var slingshotHostsSheet: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                List {
                    #if DEBUG
                    if let state = debugSlingshotCheckpointState {
                        Section {
                            debugCheckpointBanner(issue: "LF-14", state: state)
                            Text(state)
                                .litterFont(.caption, weight: .semibold)
                                .foregroundColor(LitterTheme.textSecondary)
                                .accessibilityIdentifier("slingshot-browser-status")
                        } footer: {
                            Text("Static Debug fixture. No account tokens or network requests are used.")
                                .litterFont(.caption2)
                                .foregroundColor(LitterTheme.textMuted)
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                    #endif
                    Section {
                        if slingshotIsLoading && slingshotEnvironments.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .tint(LitterTheme.accent)
                                Text("Loading connected computers...")
                                    .litterFont(.footnote)
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                        } else if let slingshotError {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(slingshotError)
                                    .litterFont(.footnote)
                                    .foregroundColor(LitterTheme.textSecondary)
                                    .accessibilityIdentifier("slingshot-browser-error")
                                Button("Retry") {
                                    Task { await loadSlingshotEnvironments() }
                                }
                                .foregroundColor(LitterTheme.accent)
                                .litterFont(.footnote, weight: .semibold)
                                .accessibilityIdentifier("slingshot-browser-retry")
                            }
                        } else if slingshotEnvironments.isEmpty {
                            Text("No connected computers were found for this account.")
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textSecondary)
                        } else {
                            ForEach(slingshotEnvironments, id: \.id) { environment in
                                Button {
                                    showSlingshotHosts = false
                                    Task { await connectSlingshotEnvironment(environment) }
                                } label: {
                                    slingshotEnvironmentRow(environment)
                                }
                                .buttonStyle(.plain)
                                .disabled(!environment.online)
                                .accessibilityIdentifier("slingshot-browser-row-\(environment.id)")
                            }
                        }
                    } header: {
                        Text("Connected Computers")
                            .foregroundColor(LitterTheme.textSecondary)
                    } footer: {
                        Text("These computers come from ChatGPT using your signed-in account. Start Codex on the computer first so it appears here.")
                            .litterFont(.caption2)
                            .foregroundColor(LitterTheme.textMuted)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Connected Computers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh") {
                        Task { await loadSlingshotEnvironments() }
                    }
                    .disabled(slingshotIsLoading)
                    .foregroundColor(LitterTheme.accent)
                    .accessibilityIdentifier("slingshot-browser-refresh")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showSlingshotHosts = false }
                        .foregroundColor(LitterTheme.accent)
                        .accessibilityIdentifier("slingshot-browser-cancel")
                }
            }
            .task {
                #if DEBUG
                if debugCheckpointScenario?.slingshotBrowserState != nil {
                    return
                }
                #endif
                if slingshotEnvironments.isEmpty && !slingshotIsLoading {
                    await loadSlingshotEnvironments()
                }
            }
        }
        .accessibilityIdentifier("slingshot-browser-checkpoint-root")
        .serverLifecycleStrictHarnessBoundaryIfActive()
    }

    private func slingshotEnvironmentRow(_ environment: AppSlingshotEnvironment) -> some View {
        HStack(spacing: 12) {
            Image(systemName: slingshotIconName(for: environment))
                .foregroundColor(environment.online ? LitterTheme.accent : LitterTheme.textMuted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(environment.displayName)
                    .litterFont(.subheadline)
                    .foregroundColor(environment.online ? LitterTheme.textPrimary : LitterTheme.textSecondary)
                Text(slingshotSubtitle(for: environment))
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textSecondary)
            }
            Spacer()
            statusTag(
                label: environment.online ? (environment.busy ? "busy" : "online") : "offline",
                color: environment.online ? (environment.busy ? .orange : LitterTheme.accent) : LitterTheme.textMuted
            )
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func loadSlingshotEnvironments() async {
        #if DEBUG
        if debugCheckpointScenario?.slingshotBrowserState != nil {
            await reloadDebugSlingshotEnvironments()
            return
        }
        #endif
        guard let appModel = liveAppModel(for: "loadSlingshotEnvironments") else {
            return
        }
        guard !slingshotIsLoading else { return }
        slingshotIsLoading = true
        slingshotError = nil
        defer { slingshotIsLoading = false }

        do {
            let tokens = try await ChatGPTOAuth.loadStoredOrRefreshedTokens()
            let environments = try await appModel.serverBridge.listSlingshotEnvironments(
                baseUrl: slingshotBaseURL,
                accessToken: tokens.accessToken,
                accountId: tokens.accountID
            )
            slingshotEnvironments = environments.sorted { lhs, rhs in
                if lhs.online != rhs.online { return lhs.online && !rhs.online }
                if lhs.busy != rhs.busy { return !lhs.busy && rhs.busy }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        } catch {
            slingshotError = error.localizedDescription
        }
    }

    #if DEBUG
    private var debugSlingshotCheckpointState: String? {
        guard debugCheckpointScenario?.slingshotBrowserState != nil else { return nil }
        if slingshotIsLoading { return "loading" }
        if slingshotError != nil { return "error" }
        if !slingshotEnvironments.isEmpty { return "results" }
        return debugCheckpointScenario?.slingshotBrowserState
    }

    @MainActor
    private func reloadDebugSlingshotEnvironments() async {
        guard !slingshotIsLoading else { return }
        slingshotIsLoading = true
        slingshotError = nil
        slingshotEnvironments = []
        try? await Task.sleep(for: .milliseconds(200))
        slingshotEnvironments = Self.debugSlingshotResults
        slingshotIsLoading = false
    }
    #endif

    @MainActor
    private func connectSlingshotEnvironment(_ environment: AppSlingshotEnvironment) async {
        #if DEBUG
        if debugCheckpointScenario?.slingshotBrowserState != nil {
            return
        }
        #endif
        guard environment.online else {
            connectionRetryState.presentNonRetryableError("\(environment.displayName) is offline.")
            return
        }
        guard let server = slingshotServer(for: environment) else {
            connectionRetryState.presentNonRetryableError("Could not prepare this connected computer.")
            return
        }
        await connectToServer(server)
    }

    private func slingshotServer(for environment: AppSlingshotEnvironment) -> DiscoveredServer? {
        guard URL(string: environment.connectionUrl) != nil else {
            return nil
        }
        return DiscoveredServer(
            id: "slingshot-\(environment.id)",
            name: environment.displayName,
            hostname: environment.id,
            port: nil,
            codexPorts: [],
            sshPort: nil,
            source: .manual,
            hasCodexServer: true,
            websocketURL: environment.connectionUrl,
            preferredConnectionMode: .directCodex,
            os: environment.operatingSystem,
            sshBanner: nil
        )
    }

    private func slingshotSubtitle(for environment: AppSlingshotEnvironment) -> String {
        var parts: [String] = []
        if let hostName = environment.hostName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostName.isEmpty {
            parts.append(hostName)
        }
        let platform = [environment.operatingSystem, environment.architecture]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .joined(separator: " ")
        if !platform.isEmpty {
            parts.append(platform)
        }
        if let version = environment.appServerVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty {
            parts.append("Codex \(version)")
        }
        if parts.isEmpty {
            parts.append(environment.id)
        }
        return parts.joined(separator: " - ")
    }

    private func slingshotIconName(for environment: AppSlingshotEnvironment) -> String {
        switch environment.operatingSystem.lowercased() {
        case "linux":
            return "server.rack"
        case "windows":
            return "desktopcomputer"
        case "macos", "darwin":
            return "desktopcomputer"
        default:
            return "laptopcomputer"
        }
    }

    // MARK: - Manual Entry

    @ViewBuilder
    private var manualEntrySheet: some View {
        if let pendingSSHAgentContext {
            manualSSHAgentPickerSheet(context: pendingSSHAgentContext)
        } else if let pendingSSHServer {
            sshLoginSheet(
                server: pendingSSHServer,
                onAccepted: handleAcceptedManualSSHLogin
            )
        } else {
            NavigationStack {
                ZStack {
                    LitterTheme.backgroundGradient.ignoresSafeArea()
                    Form {
                    if let liveLifecyclePresentation {
                        Section {
                            liveLifecycleCard(liveLifecyclePresentation)
                                .listRowInsets(EdgeInsets())
                        }
                        .listRowBackground(Color.clear)
                    }
                    #if DEBUG
                    if let state = debugCheckpointScenario?.manualServerState {
                        Section {
                            debugCheckpointBanner(issue: "LF-13", state: state)
                            Text(state)
                                .litterFont(.caption, weight: .semibold)
                                .foregroundColor(LitterTheme.textSecondary)
                                .accessibilityIdentifier("manual-server-status")
                        } footer: {
                            Text("Static Debug fixture. The displayed URL is reserved test data and is never contacted.")
                                .litterFont(.caption2)
                                .foregroundColor(LitterTheme.textMuted)
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                    #endif
                    Section {
                        Picker("Connection Type", selection: $manualConnectionMode) {
                            ForEach(ManualConnectionMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("manual-server-method")
                    } header: {
                        Text("Connection")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        if manualConnectionMode == .codex {
                            TextField("ws://host:port or wss://...", text: $manualCodexURL)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .keyboardType(.URL)
                                .accessibilityIdentifier("manual-server-url")
                        } else {
                            TextField("hostname or IP", text: $manualHost)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .accessibilityIdentifier("manual-server-host")
                            TextField("ssh port", text: $manualSSHPort)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                                .keyboardType(.numberPad)
                                .accessibilityIdentifier("manual-server-ssh-port")
                            TextField("wake MAC (optional)", text: $manualWakeMAC)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .accessibilityIdentifier("manual-server-wake-mac")
                        }
                    } header: {
                        Text(manualConnectionMode.formHeader)
                            .foregroundColor(LitterTheme.textSecondary)
                    } footer: {
                        if manualConnectionMode == .codex {
                            Text("Prefer the SSH flow — it bootstraps codex on the remote bound to 127.0.0.1 and forwards the port over SSH.\nIf you run it manually, bind loopback and tunnel yourself: codex app-server --listen ws://127.0.0.1:8390\nFor reverse proxies: wss://example.com/ws?token=SECRET\nDo not bind 0.0.0.0 or expose directly to the internet unless you know what you are doing.")
                                .litterFont(.caption2)
                                .foregroundColor(LitterTheme.textMuted)
                        }
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        Button(manualConnectionMode.primaryButtonTitle) {
                            submitManualEntry()
                        }
                        .disabled(manualWakeTask != nil)
                        .foregroundColor(LitterTheme.accent)
                        .litterFont(.subheadline)
                        .accessibilityIdentifier("manual-server-submit")
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    #if DEBUG
                    if debugCheckpointScenario == .manualServerInvalid,
                       let error = connectionRetryState.errorMessage {
                        Section {
                            Text(error)
                                .foregroundColor(LitterTheme.danger)
                                .litterFont(.caption)
                                .accessibilityIdentifier("manual-server-error")
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                    #endif
                    }
                    .scrollContentBackground(.hidden)
                }
                .navigationTitle("Add Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") { showManualEntry = false }
                            .foregroundColor(LitterTheme.accent)
                            .accessibilityIdentifier("manual-server-cancel")
                    }
                }
            }
            .accessibilityIdentifier("manual-server-checkpoint-root")
            .serverLifecycleStrictHarnessBoundaryIfActive()
            #if DEBUG
            .task {
                guard debugCheckpointScenario == .manualServerInvalid,
                      !debugManualInvalidSubmissionStarted else {
                    return
                }
                debugManualInvalidSubmissionStarted = true
                await Task.yield()
                guard showManualEntry else { return }
                submitManualCodexEntry()
            }
            #endif
        }
    }

    private func maybeStartSimulatorAutoSSH() {
#if DEBUG
        guard !autoSSHStarted else { return }
        guard DiscoverySimulatorAutoSSHGate.allowsStart(
            isInertCheckpoint: runtimeDependencies.isInertCheckpoint,
            strictHarnessActive: LearnfoldStrictHarnessPolicy.isStrictHarnessActive()
        ) else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["CODEXIOS_SIM_AUTO_SSH"] == "1",
              let host = env["CODEXIOS_SIM_AUTO_SSH_HOST"], !host.isEmpty,
              let user = env["CODEXIOS_SIM_AUTO_SSH_USER"], !user.isEmpty else {
            return
        }
        let password = env["CODEXIOS_SIM_AUTO_SSH_PASS"]
        let keyPath = env["CODEXIOS_SIM_AUTO_SSH_KEY_PATH"]
        let keyPem: String? = keyPath.flatMap { path -> String? in
            guard !path.isEmpty else { return nil }
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        guard (password?.isEmpty == false) || (keyPem?.isEmpty == false) else { return }
        autoSSHStarted = true

        Task {
            NSLog("[AUTO_SSH] connecting to %@ as %@ (method=%@)", host, user, keyPem == nil ? "password" : "key")
            let server = DiscoveredServer(
                id: "auto-ssh-\(host)",
                name: host,
                hostname: host,
                port: nil,
                sshPort: 22,
                source: .ssh,
                hasCodexServer: false,
                sshPortForwardingEnabled: false,
                preferredConnectionMode: .ssh
            )
            let credentials: SSHCredentials
            if let keyPem, !keyPem.isEmpty {
                credentials = .key(
                    username: user,
                    privateKey: keyPem,
                    passphrase: env["CODEXIOS_SIM_AUTO_SSH_PASSPHRASE"]
                )
            } else {
                credentials = .password(
                    username: user,
                    password: password ?? "",
                    unlockMacosKeychain: false
                )
            }
            await connectToServer(
                server,
                targetOverride: .sshThenRemote(
                    host: host,
                    credentials: credentials
                )
            )
        }
#endif
    }

    private var showConnectError: Binding<Bool> {
        Binding(
            get: {
                #if DEBUG
                if debugCheckpointScenario == .manualServerInvalid {
                    return false
                }
                #endif
                return connectionRetryState.errorMessage != nil
            },
            // Retry and OK update the source state synchronously. Avoid
            // clearing the preserved attempt from an alert-framework dismiss
            // callback that may race the Retry button action.
            set: { _ in }
        )
    }

    @ViewBuilder
    private var connectionFailureAlertMessage: some View {
        Text(connectionRetryState.errorMessage ?? "Unable to connect.")
    }

    private func submitManualEntry() {
        switch manualConnectionMode {
        case .codex:
            submitManualCodexEntry()
        case .ssh:
            submitManualSSHEntry()
        }
    }

    private func submitManualCodexEntry() {
        let raw = manualCodexURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        // Full URL: ws:// or wss://
        if let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           (scheme == "ws" || scheme == "wss"),
           let host = url.host, !host.isEmpty {
            let port = url.port.flatMap { UInt16(exactly: $0) }
            let server = DiscoveredServer(
                id: "manual-url-\(raw)",
                name: host,
                hostname: host,
                port: port,
                codexPorts: port.map { [$0] } ?? [],
                sshPort: nil,
                source: .manual,
                hasCodexServer: true,
                websocketURL: raw,
                preferredConnectionMode: .directCodex,
                preferredCodexPort: port
            )
            showManualEntry = false
            Task { await connectToServer(server) }
            return
        }

        // Bare host:port (e.g. "192.168.1.5:8390" or "myhost:8390")
        let parts = raw.split(separator: ":", maxSplits: 1)
        let host: String
        let port: UInt16
        if parts.count == 2, let p = UInt16(parts[1]) {
            host = String(parts[0])
            port = p
        } else if parts.count == 1 {
            host = raw
            port = 8390
        } else {
            connectionRetryState.presentNonRetryableError("Enter a ws:// URL or host:port")
            return
        }

        guard !host.isEmpty else { return }
        let server = DiscoveredServer(
            id: "manual-\(host):\(port)",
            name: host,
            hostname: host,
            port: port,
            codexPorts: [port],
            sshPort: nil,
            source: .manual,
            hasCodexServer: true,
            preferredConnectionMode: .directCodex,
            preferredCodexPort: port
        )
        showManualEntry = false
        Task { await connectToServer(server) }
    }

    private func submitManualSSHEntry() {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }

        let wakeInput = manualWakeMAC.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWakeMAC = DiscoveredServer.normalizeWakeMAC(wakeInput)
        if !wakeInput.isEmpty && normalizedWakeMAC == nil {
            connectionRetryState.presentNonRetryableError("Wake MAC must look like aa:bb:cc:dd:ee:ff")
            return
        }

        guard let sshPort = UInt16(manualSSHPort) else {
            connectionRetryState.presentNonRetryableError("SSH port must be a valid number")
            return
        }
        let server = DiscoveredServer(
            id: "manual-ssh-\(host):\(sshPort)",
            name: host,
            hostname: host,
            port: nil,
            sshPort: sshPort,
            source: .manual,
            hasCodexServer: false,
            wakeMAC: normalizedWakeMAC,
            preferredConnectionMode: .ssh
        )
        guard normalizedWakeMAC != nil else {
            pendingSSHServer = server
            return
        }
        guard manualWakeTask == nil,
              let lifecycleEpoch = connectionLifecycleGate.currentEpoch else { return }
        manualWakeTask = Task { @MainActor in
            defer { manualWakeTask = nil }
            let prepared = await prepareServerForSelection(server)
            guard !Task.isCancelled,
                  connectionLifecycleGate.isCurrent(lifecycleEpoch),
                  showManualEntry else { return }
            pendingSSHServer = prepared.server
        }
    }

    private var connectionChoicePresented: Binding<Bool> {
        Binding(
            get: { connectionChoiceServer != nil },
            set: { newValue in
                if !newValue {
                    connectionChoiceServer = nil
                }
            }
        )
    }

    private func connectionChoiceMessage(for server: DiscoveredServer) -> String {
        let directPorts = server.availableDirectCodexPorts.map(String.init)
        if directPorts.isEmpty {
            return "Use SSH to bootstrap Codex on \(server.hostname)."
        }
        if server.canConnectViaSSH {
            return "Codex is available on ports \(directPorts.joined(separator: ", ")) and SSH is also available on port \(server.resolvedSSHPort)."
        }
        return "Choose a Codex app-server port on \(server.hostname)."
    }

    private func progressTag(
        for serverSnapshot: AppServerSnapshot?
    ) -> (label: String, color: Color)? {
        guard let serverSnapshot,
              let label = serverSnapshot.connectionProgressLabel,
              let step = serverSnapshot.currentConnectionStep else {
            return nil
        }

        let color: Color
        switch step.state {
        case .failed:
            color = .red
        case .completed where step.kind == .connected:
            color = LitterTheme.accentStrong
        case .awaitingUserInput:
            color = .orange
        default:
            color = LitterTheme.accent
        }

        return (label, color)
    }
}

private final class WakeProbeResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed {
            return false
        }
        resumed = true
        return true
    }
}

private enum ManualConnectionMode: String, CaseIterable, Identifiable {
    case codex
    case ssh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .codex:
            return "Codex"
        case .ssh:
            return "SSH"
        }
    }

    var formHeader: String {
        switch self {
        case .codex:
            return "Codex Server"
        case .ssh:
            return "SSH Bootstrap"
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .codex:
            return "Connect"
        case .ssh:
            return "Continue to SSH Login"
        }
    }
}

#if DEBUG
#Preview("Discovery") {
    let appModel = LitterPreviewData.makeDiscoveryAppModel()
    let appState = LitterPreviewData.makeAppState()
    LitterPreviewScene(
        appModel: appModel,
        appState: appState,
        includeBackground: false
    ) {
        NavigationStack {
            DiscoveryView(
                runtimeDependencies: .live(
                    appModel: appModel,
                    appState: appState
                ),
                autoStartDiscovery: false,
                initialServers: LitterPreviewData.sampleDiscoveryServers
            )
        }
    }
}
#endif
