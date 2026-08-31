import SwiftUI

#if DEBUG
enum SSHAgentPickerCheckpointState: String {
    case loading
    case error
    case populated
}
#endif

struct SSHBridgeAgentContext: Identifiable {
    let id: String
    let server: DiscoveredServer
    let sessionId: String
    let host: String
    let availability: [RemoteAgentAvailability]
    let credentials: SSHCredentials
    #if DEBUG
    let checkpointRuntimeMetadata: [AppAgentMetadata]
    #endif

    init(
        server: DiscoveredServer,
        sessionId: String,
        host: String,
        availability: [RemoteAgentAvailability],
        credentials: SSHCredentials
    ) {
        self.id = sessionId
        self.server = server
        self.sessionId = sessionId
        self.host = host
        self.availability = availability
        self.credentials = credentials
        #if DEBUG
        self.checkpointRuntimeMetadata = []
        #endif
    }

    #if DEBUG
    init(
        server: DiscoveredServer,
        sessionId: String,
        host: String,
        availability: [RemoteAgentAvailability],
        credentials: SSHCredentials,
        checkpointRuntimeMetadata: [AppAgentMetadata]
    ) {
        self.id = sessionId
        self.server = server
        self.sessionId = sessionId
        self.host = host
        self.availability = availability
        self.credentials = credentials
        self.checkpointRuntimeMetadata = checkpointRuntimeMetadata
    }
    #endif

    func isBetaRuntime(_ kind: AgentRuntimeKind) -> Bool {
        #if DEBUG
        if let metadata = checkpointRuntimeMetadata.first(where: { $0.name == kind }) {
            return metadata.presentation?.isBeta ?? true
        }
        #endif
        return kind.isBeta
    }
}

struct SSHBridgeAgentResult {
    let serverId: String
    let displayName: String
    let host: String
    let port: UInt16
    let sessionId: String
    let runtimeKinds: [AgentRuntimeKind]
}

@MainActor
enum SSHAgentPickerRuntimeDependencies {
    case live(appModel: AppModel)
    case inertCheckpoint

    var appModel: AppModel? {
        guard case .live(let appModel) = self else { return nil }
        return appModel
    }

    var isInertCheckpoint: Bool {
        if case .inertCheckpoint = self { return true }
        return false
    }
}

struct SSHAgentPickerSheet: View {
    let context: SSHBridgeAgentContext
    private let runtimeDependencies: SSHAgentPickerRuntimeDependencies
    let onConnected: (SSHBridgeAgentResult) -> Void
    let onUseCodex: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKinds: Set<AgentRuntimeKind>
    @State private var isConnecting = false
    @State private var connectError: String?
    #if DEBUG
    @State private var checkpointState: SSHAgentPickerCheckpointState?
    #endif

    init(
        context: SSHBridgeAgentContext,
        appModel: AppModel,
        onConnected: @escaping (SSHBridgeAgentResult) -> Void,
        onUseCodex: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.context = context
        self.runtimeDependencies = .live(appModel: appModel)
        self.onConnected = onConnected
        self.onUseCodex = onUseCodex
        self.onCancel = onCancel
        _selectedKinds = State(initialValue: Set(
            Self.availableBridgeKinds(in: context.availability).filter {
                !context.isBetaRuntime($0)
            }
        ))
    }

    #if DEBUG
    init(
        context: SSHBridgeAgentContext,
        checkpointState: SSHAgentPickerCheckpointState,
        onConnected: @escaping (SSHBridgeAgentResult) -> Void,
        onUseCodex: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.context = context
        self.runtimeDependencies = .inertCheckpoint
        self.onConnected = onConnected
        self.onUseCodex = onUseCodex
        self.onCancel = onCancel
        _selectedKinds = State(initialValue: Set(
            Self.availableBridgeKinds(in: context.availability).filter {
                !context.isBetaRuntime($0)
            }
        ))
        _isConnecting = State(initialValue: checkpointState == .loading)
        _connectError = State(
            initialValue: checkpointState == .error
                ? "Remote agents could not be started on the redacted test host."
                : nil
        )
        _checkpointState = State(initialValue: checkpointState)
    }
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    #if DEBUG
                    if let checkpointState {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("DEBUG CHECKPOINT · NON-LIVE")
                                    .litterFont(.caption2, weight: .semibold)
                                    .foregroundColor(.orange)
                                Text("LF-12 · \(checkpointState.rawValue)")
                                    .litterFont(.footnote, weight: .semibold)
                                    .foregroundColor(LitterTheme.textPrimary)
                            }
                            Text(checkpointState.rawValue)
                                .litterFont(.caption, weight: .semibold)
                                .foregroundColor(LitterTheme.textSecondary)
                                .accessibilityIdentifier("ssh-agent-picker-status")
                        } footer: {
                            Text("Static Debug fixture. SSH and filesystem state roots are disabled.")
                                .litterFont(.caption2)
                                .foregroundColor(LitterTheme.textMuted)
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                    #endif
                    hostSection
                    agentSection
                    connectSection
                    if let connectError {
                        Section {
                            Text(connectError)
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.danger)
                                .accessibilityIdentifier("ssh-agent-picker-error")
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Remote Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                    .foregroundColor(LitterTheme.accent)
                    .disabled(isConnecting)
                }
            }
        }
        .accessibilityIdentifier("ssh-agent-picker-checkpoint-root")
        .serverLifecycleStrictHarnessBoundaryIfActive()
    }

    private var hostSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .foregroundColor(LitterTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.server.name)
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                    Text(context.host)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                }
            }
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private var agentSection: some View {
        Section {
            ForEach(context.availability, id: \.kind) { agent in
                Button {
                    guard isBridgeKind(agent.kind), agent.status == .available else { return }
                    if selectedKinds.contains(agent.kind) {
                        selectedKinds.remove(agent.kind)
                    } else {
                        selectedKinds.insert(agent.kind)
                    }
                } label: {
                    HStack(spacing: 10) {
                        AgentIconView(kind: agent.kind, size: 22)
                            .opacity(agent.status == .available ? 1 : 0.45)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(runtimeDisplayName(agent.kind))
                                    .litterFont(.subheadline)
                                    .foregroundColor(agent.status == .available ? LitterTheme.textPrimary : LitterTheme.textMuted)
                                if context.isBetaRuntime(agent.kind) {
                                    BetaBadge()
                                }
                            }
                            Text(statusLabel(agent.status, kind: agent.kind))
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        Spacer()
                        if selectedKinds.contains(agent.kind) {
                            Image(systemName: "checkmark.square.fill")
                                .foregroundColor(LitterTheme.accent)
                        } else if isBridgeKind(agent.kind), agent.status == .available {
                            Image(systemName: "square")
                                .foregroundColor(LitterTheme.textMuted)
                        }
                    }
                }
                .disabled(!isBridgeKind(agent.kind) || agent.status != .available || isConnecting)
                .accessibilityIdentifier("ssh-agent-row-\(agent.kind)")
                .accessibilityValue(selectedKinds.contains(agent.kind) ? "selected" : "not selected")
            }
        } header: {
            HStack {
                Text("Agents")
                Spacer()
                if !availableBridgeKinds.isEmpty {
                    Button(selectedKinds.count == availableBridgeKinds.count ? "None" : "All") {
                        if selectedKinds.count == availableBridgeKinds.count {
                            selectedKinds = []
                        } else {
                            selectedKinds = Set(availableBridgeKinds)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(LitterTheme.accent)
                    .disabled(isConnecting)
                }
            }
            .foregroundColor(LitterTheme.textSecondary)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private var connectSection: some View {
        Section {
            Button {
                connect()
            } label: {
                HStack {
                    if isConnecting {
                        ProgressView().tint(LitterTheme.accent)
                    }
                    Text("Connect")
                        .foregroundColor(LitterTheme.accent)
                        .litterFont(.subheadline)
                }
            }
            .disabled(isConnecting || selectedKinds.isEmpty)
            .accessibilityIdentifier("ssh-agent-connect")

            Button("Use Codex SSH") {
                onUseCodex()
                dismiss()
            }
            .litterFont(.footnote)
            .foregroundColor(LitterTheme.textSecondary)
            .disabled(isConnecting)
            .accessibilityIdentifier("ssh-agent-use-codex")
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private var availableBridgeKinds: [AgentRuntimeKind] {
        Self.availableBridgeKinds(in: context.availability)
    }

    private func connect() {
        #if DEBUG
        if checkpointState != nil {
            checkpointState = .loading
            isConnecting = true
            connectError = nil
            return
        }
        #endif
        guard !runtimeDependencies.isInertCheckpoint,
              let appModel = runtimeDependencies.appModel else {
            LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                "SSHAgentPickerSheet.inertCheckpoint.connect"
            )
            return
        }
        isConnecting = true
        connectError = nil
        let runtimeKinds = Array(selectedKinds).sorted { runtimeSortRank($0) < runtimeSortRank($1) }
        Task {
            do {
                let result = try await appModel.ssh.sshConnectBridgeSession(
                    sessionId: context.sessionId,
                    serverId: "ssh-bridge:\(context.host)",
                    displayName: context.server.name,
                    host: context.host,
                    stateRoot: try sshBridgeStateRoot(host: context.host),
                    runtimeKinds: runtimeKinds,
                    transport: .ephemeral
                )
                isConnecting = false
                onConnected(SSHBridgeAgentResult(
                    serverId: result.serverId,
                    displayName: context.server.name,
                    host: context.host,
                    port: context.server.resolvedSSHPort,
                    sessionId: context.sessionId,
                    runtimeKinds: runtimeKinds
                ))
                dismiss()
            } catch {
                isConnecting = false
                connectError = error.localizedDescription
            }
        }
    }

    private static func availableBridgeKinds(in availability: [RemoteAgentAvailability]) -> [AgentRuntimeKind] {
        availability
            .filter { isBridgeKind($0.kind) && $0.status == .available }
            .map(\.kind)
            .sorted { runtimeSortRank($0) < runtimeSortRank($1) }
    }
}

private func isBridgeKind(_ kind: AgentRuntimeKind) -> Bool {
    // Prefer the capability flag from alleycat metadata; fall back to
    // the legacy SSH-bridge-supported allowlist when metadata isn't
    // cached yet (cold start).
    if let supports = kind.metadata?.capabilities?.supportsSshBridge {
        return supports
    }
    switch kind {
    case "codex", "claude", "pi", "opencode":
        return true
    default:
        return false
    }
}

private func runtimeDisplayName(_ kind: AgentRuntimeKind) -> String {
    kind.displayLabel
}

private func runtimeSortRank(_ kind: AgentRuntimeKind) -> Int {
    // SSH-bridge picker keeps its own historical ordering distinct
    // from the general presentation order: Claude leads because it's
    // the most common SSH-bootstrap target.
    switch kind {
    case "claude": return 0
    case "pi": return 1
    case "opencode": return 2
    case "codex": return 3
    case "amp": return 4
    case "droid": return 5
    case "hermes": return 6
    default: return Int.max
    }
}

private func statusLabel(_ status: AgentAvailabilityStatus, kind: AgentRuntimeKind) -> String {
    switch status {
    case .available:
        return "Available"
    case .agentCliMissing:
        return "CLI missing"
    case .windowsNotYetSupported:
        return "Windows not supported"
    }
}

private func sshBridgeStateRoot(host: String) throws -> String {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let safeHost = host
        .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "host"
    let dir = base
        .appendingPathComponent("alleycat-bridges", isDirectory: true)
        .appendingPathComponent(safeHost, isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}
