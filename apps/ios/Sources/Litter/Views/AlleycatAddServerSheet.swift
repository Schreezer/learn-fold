@preconcurrency import AVFoundation
import Foundation
import Synchronization
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AlleycatConnectedTarget: Equatable {
    let serverId: String
    let nodeId: String
    let displayName: String
    let params: AppAlleycatPairPayload
    let agentName: String
    let agentWire: AppAlleycatAgentWire
}

enum AgentAssistedPairing {
    static func prompt(submitURL: URL) -> String {
        """
    Connect this computer's Hermes agent to the Learnfold app on my iPhone.

    Run exactly this one terminal command now. Do not inspect the environment or run \
    preflight commands first:
    `npx -y learnfold-link@0.3.10 handoff "\(submitURL.absoluteString)"`

    If it exits successfully, reply only "Connected". Otherwise reply only "Setup failed". \
    Do not display a token or pairing JSON, and do not ask me to run a command.

    The URL is a temporary, one-time credential. Do not save it to a file, memory, or log, \
    and do not use it for anything except this Learnfold Link handoff.
    """
    }

    static func pairingPayloadCandidate(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstBrace = trimmed.firstIndex(of: "{"),
              let lastBrace = trimmed.lastIndex(of: "}"),
              firstBrace <= lastBrace
        else {
            return trimmed
        }
        return String(trimmed[firstBrace...lastBrace])
    }

    static func disablePrompt(computerName: String) -> String {
        """
    Securely disable Learnfold connectivity on \(computerName), while keeping Hermes itself running.

    Perform the shutdown yourself in your own terminal:
    1. Run `npx -y learnfold-link@0.3.10 rotate` to invalidate every existing Learnfold pairing.
    2. Run `npx -y learnfold-link@0.3.10 uninstall` to disable autostart and stop the managed service.
    3. If a Learnfold Link or Alleycat daemon is still running, run \
    `npx -y learnfold-link@0.3.10 stop`.
    4. Verify that autostart is disabled and no Learnfold Link or Alleycat daemon remains running.

    Do not display the new token. Do not delete Hermes, projects, configuration, or logs. \
    Do not ask me to run any commands. Report only whether revocation and shutdown succeeded.

    This request intentionally ends Learnfold's connection, so complete it from this external \
    Hermes chat even if Learnfold disconnects before receiving a final response.
    """
    }
}

enum AgentAssistedPairingPromptLabelPolicy {
    static func hasActiveRequest(expiresAt: Date?, now: Date) -> Bool {
        expiresAt.map { $0 > now } ?? false
    }

    static func title(hasCopiedPrompt: Bool, hasActiveRequest: Bool, needsNewPrompt: Bool = false) -> String {
        switch (hasCopiedPrompt, hasActiveRequest) {
        case (true, true):
            "Prompt Copied — Waiting"
        case (true, false):
            "Copy New Setup Prompt"
        case (false, _):
            needsNewPrompt ? "Copy New Setup Prompt" : "Copy Setup Prompt"
        }
    }

    static func systemImage(hasCopiedPrompt: Bool, hasActiveRequest: Bool) -> String {
        hasCopiedPrompt && hasActiveRequest ? "checkmark.circle.fill" : "doc.on.doc"
    }
}

private struct HermesLinkConnectRequest {
    let serverId: String
    let displayName: String
    let params: AppAlleycatPairPayload
    let agentName: String
    let selectedAgentNames: [String]
    let wire: AppAlleycatAgentWire
}

private enum HermesLinkStrictCheckpointEffectError: LocalizedError {
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .blocked(let operation):
            "Strict Link checkpoint blocked \(operation)."
        }
    }
}

/// The production adapter captures the already-live `AppModel`, but every
/// bridge/store singleton lookup remains inside the operation that needs it.
/// The strict adapter is deliberately a set of tripwires: fixture actions must
/// resolve through render-only state before reaching any of these closures.
@MainActor
private struct HermesLinkRuntimeAdapter {
    let parsePairPayload: (String) throws -> AppAlleycatPairPayload
    let listAgents: (AppAlleycatPairPayload) async throws -> [AppAlleycatAgentInfo]
    let connect: (HermesLinkConnectRequest) async throws -> AppAlleycatConnectResult
    let saveCredential: (String, String) throws -> Void
    let persistRuntimeSecretIfNeeded: () -> Void

    static func production(appModel: AppModel) -> Self {
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
            "HermesLink.productionRuntimeAdapter"
        )
        return Self(
            parsePairPayload: { json in
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.parsePairPayload"
                )
                return try RustAlleycatBridge.shared.parsePairPayload(json: json)
            },
            listAgents: { params in
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.listAgents"
                )
                return try await appModel.serverBridge.listAlleycatAgents(params: params)
            },
            connect: { request in
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.connect"
                )
                return try await appModel.serverBridge.connectRemoteOverAlleycat(
                    serverId: request.serverId,
                    displayName: request.displayName,
                    params: request.params,
                    agentName: request.agentName,
                    selectedAgentNames: request.selectedAgentNames,
                    wire: request.wire
                )
            },
            saveCredential: { token, nodeID in
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.saveCredential"
                )
                try AlleycatCredentialStore.shared.saveToken(token, nodeId: nodeID)
            },
            persistRuntimeSecretIfNeeded: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.persistRuntimeSecret"
                )
                AppRuntimeController.shared.persistAlleycatSecretKeyIfNeeded()
            }
        )
    }

    #if DEBUG
    static var strictCheckpoint: Self {
        Self(
            parsePairPayload: { _ in
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.parsePairPayload"
                )
                throw HermesLinkStrictCheckpointEffectError.blocked("pairing parsing")
            },
            listAgents: { _ in
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.listAgents"
                )
                throw HermesLinkStrictCheckpointEffectError.blocked("agent discovery")
            },
            connect: { _ in
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.connect"
                )
                throw HermesLinkStrictCheckpointEffectError.blocked("remote connection")
            },
            saveCredential: { _, _ in
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.saveCredential"
                )
                throw HermesLinkStrictCheckpointEffectError.blocked("credential storage")
            },
            persistRuntimeSecretIfNeeded: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.persistRuntimeSecret"
                )
            }
        )
    }
    #endif
}

private enum HermesLinkCameraAuthorization {
    case authorized
    case notDetermined
    case denied
}

private enum HermesLinkAlertPresentation: Identifiable {
    case cameraDenied(id: UUID)
    case hermesReady(
        id: UUID,
        host: HermesPairingStatus.Host,
        isRetry: Bool
    )

    var id: UUID {
        switch self {
        case .cameraDenied(let id), .hermesReady(let id, _, _):
            id
        }
    }
}

/// Platform effects are closures so constructing a strict checkpoint never
/// asks UIKit, AVFoundation, pasteboard, or preferences for a live singleton.
@MainActor
private struct HermesLinkPlatformAdapter {
    let now: () -> Date
    let rendersAsMacApp: () -> Bool
    let readClipboard: () -> String?
    let writeExpiringPrompt: (String, Date) -> Void
    let copyScannerCommand: () -> Void
    let loadOrCreateInstallationID: () -> String
    let cameraAuthorization: () -> HermesLinkCameraAuthorization
    let requestCameraAccess: () async -> Bool
    let openAppSettings: () -> Void

    static func production() -> Self {
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
            "HermesLink.productionPlatformAdapter"
        )
        return Self(
            now: Date.init,
            rendersAsMacApp: { LitterPlatform.rendersAsMacApp },
            readClipboard: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.clipboardRead"
                )
                return UIPasteboard.general.string
            },
            writeExpiringPrompt: { prompt, expiresAt in
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.clipboardWrite"
                )
                UIPasteboard.general.setItems(
                    [[UTType.plainText.identifier: prompt]],
                    options: [.expirationDate: expiresAt]
                )
            },
            copyScannerCommand: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.clipboardWrite"
                )
                UIPasteboard.general.string = "npx learnfold-link"
            },
            loadOrCreateInstallationID: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.installationStorage"
                )
                let key = "learnfold.pairingInstallationId"
                if let existing = UserDefaults.standard.string(forKey: key) {
                    return existing
                }
                let generated = UUID().uuidString
                UserDefaults.standard.set(generated, forKey: key)
                return generated
            },
            cameraAuthorization: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.cameraAuthorization"
                )
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized:
                    return .authorized
                case .notDetermined:
                    return .notDetermined
                case .denied, .restricted:
                    return .denied
                @unknown default:
                    return .denied
                }
            },
            requestCameraAccess: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.cameraRequest"
                )
                return await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .video) { granted in
                        continuation.resume(returning: granted)
                    }
                }
            },
            openAppSettings: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.settingsOpen"
                )
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        )
    }

    #if DEBUG
    static var strictCheckpoint: Self {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        return Self(
            now: { fixedNow },
            rendersAsMacApp: { false },
            readClipboard: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.clipboardRead"
                )
                return nil
            },
            writeExpiringPrompt: { _, _ in
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.clipboardWrite"
                )
            },
            copyScannerCommand: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.clipboardWrite"
                )
            },
            loadOrCreateInstallationID: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.installationStorage"
                )
                return "STRICT-CHECKPOINT-BLOCKED"
            },
            cameraAuthorization: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.cameraAuthorization"
                )
                return .denied
            },
            requestCameraAccess: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.cameraRequest"
                )
                return false
            },
            openAppSettings: {
                LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                    "HermesLink.settingsOpen"
                )
            }
        )
    }
    #endif
}

#if DEBUG
private actor HermesLinkStrictCheckpointBroker: HermesPairingBrokerServing {
    func createRequest(installationId: String) async throws -> HermesPairingRequest {
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry("HermesLink.brokerCreate")
        throw HermesLinkStrictCheckpointEffectError.blocked("broker create")
    }

    func status(for pairing: HermesPairingRequest) async throws -> HermesPairingStatus {
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry("HermesLink.brokerStatus")
        throw HermesLinkStrictCheckpointEffectError.blocked("broker status")
    }

    func claim(_ pairing: HermesPairingRequest) async throws -> String {
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry("HermesLink.brokerClaim")
        throw HermesLinkStrictCheckpointEffectError.blocked("broker claim")
    }

    func cancel(_ pairing: HermesPairingRequest) async {
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry("HermesLink.brokerCancel")
    }
}

private final class HermesLinkStrictCheckpointStore: HermesPairingPendingStoring {
    func load() throws -> HermesPairingRequest? {
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry("HermesLink.pendingStoreLoad")
        return nil
    }

    func save(_ request: HermesPairingRequest) throws {
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry("HermesLink.pendingStoreSave")
        throw HermesLinkStrictCheckpointEffectError.blocked("pending request save")
    }

    func clear() throws {
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry("HermesLink.pendingStoreClear")
    }
}
#endif

@MainActor
private enum HermesLinkPairingCoordinatorFactory {
    static func production(now: @escaping () -> Date) -> HermesPairingLifecycleCoordinator {
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
            "HermesLink.productionPairingCoordinator"
        )
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
            "HermesLink.brokerSingleton"
        )
        let broker = HermesPairingBrokerClient.shared
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
            "HermesLink.pendingStoreSingleton"
        )
        let store = HermesPairingPendingKeychainStore.shared
        return HermesPairingLifecycleCoordinator(
            broker: broker,
            store: store,
            now: now
        )
    }

    #if DEBUG
    static func strictCheckpoint(
        scenario: HermesLinkCheckpointScenario,
        now: @escaping () -> Date
    ) -> HermesPairingLifecycleCoordinator {
        HermesPairingLifecycleCoordinator(
            broker: HermesLinkStrictCheckpointBroker(),
            store: HermesLinkStrictCheckpointStore(),
            now: now,
            checkpointScenario: scenario,
            checkpointIsolated: true
        )
    }
    #endif
}

struct AlleycatAddServerSheet: View {
    let onConnected: (AlleycatConnectedTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var hermesPairing: HermesPairingLifecycleCoordinator
    @State private var displayName: String = ""
    @State private var parsedParams: AppAlleycatPairPayload?
    @State private var agents: [AppAlleycatAgentInfo] = []
    @State private var selectedAgentNames: Set<String> = []
    @State private var isLoadingAgents = false
    @State private var parseError: String?
    @State private var agentError: String?
    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var showScanner = false
    @State private var pendingCameraDeniedAlert = false
    @State private var alertPresentation: HermesLinkAlertPresentation?
    // pasteJSON / showPaste are used by the Mac paste-JSON UI
    // (Catalyst + iOS-on-Mac) and the iOS QR fallback.
    @State private var pasteJSON: String = ""
    @State private var showPaste: Bool = false
    @State private var copiedAgentPrompt = false
    @State private var connectAfterAgentLoad = false
    @State private var pairingRequestIDForParsedParams: String?
    #if DEBUG
    @State private var reviewActivationCount = 0
    #endif

    private let runtime: HermesLinkRuntimeAdapter
    private let platform: HermesLinkPlatformAdapter

    #if DEBUG
    private let checkpointScenario: HermesLinkCheckpointScenario?
    #endif

    init(
        appModel: AppModel,
        onConnected: @escaping (AlleycatConnectedTarget) -> Void
    ) {
        let platform = HermesLinkPlatformAdapter.production()
        self.runtime = HermesLinkRuntimeAdapter.production(appModel: appModel)
        self.platform = platform
        self.onConnected = onConnected
        #if DEBUG
        checkpointScenario = nil
        #endif
        _hermesPairing = StateObject(
            wrappedValue: HermesLinkPairingCoordinatorFactory.production(
                now: platform.now
            )
        )
    }

    #if DEBUG
    init(checkpointScenario: HermesLinkCheckpointScenario) {
        let platform = HermesLinkPlatformAdapter.strictCheckpoint
        self.runtime = .strictCheckpoint
        self.platform = platform
        self.onConnected = { _ in
            LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                "HermesLink.checkpointOnConnected"
            )
        }
        self.checkpointScenario = checkpointScenario
        _hermesPairing = StateObject(
            wrappedValue: HermesLinkPairingCoordinatorFactory.strictCheckpoint(
                scenario: checkpointScenario,
                now: platform.now
            )
        )
    }
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    #if DEBUG
                    if let checkpointScenario {
                        checkpointBoundary(scenario: checkpointScenario)
                    }
                    #endif
                    pairingSection
                    if let params = parsedParams {
                        previewSection(params: params)
                        agentSection
                    }
                    if let parseError {
                        errorSection(parseError, color: LitterTheme.warning, accessibilityID: "hermes-link-error")
                    }
                    if let agentError {
                        errorSection(agentError, color: LitterTheme.warning)
                    }
                    connectSection
                    if let connectError {
                        errorSection(connectError, color: LitterTheme.danger)
                    }
                }
                .scrollContentBackground(.hidden)

                #if DEBUG
                if checkpointScenario != nil {
                    Text("Hermes review activation")
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .frame(width: 1, height: 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Hermes review activation")
                        .accessibilityIdentifier("hermes-link-review-activation")
                        .accessibilityValue(String(reviewActivationCount))
                        .allowsHitTesting(false)
                }
                #endif
            }
            .alert(item: $alertPresentation) { presentation in
                switch presentation {
                case .cameraDenied:
                    Alert(
                        title: Text("Camera Access Needed"),
                        message: Text("Allow camera access in Settings to scan an Alleycat pairing QR code."),
                        primaryButton: .default(Text("Open Settings"), action: openAppSettings),
                        secondaryButton: .cancel(Text("Cancel"))
                    )
                case .hermesReady(_, let host, let isRetry):
                    Alert(
                        title: Text("Hermes is ready"),
                        message: Text(hermesConfirmationMessage(host: host, isRetry: isRetry)),
                        primaryButton: .default(Text("Connect"), action: claimHermesPairingAndConnect),
                        secondaryButton: .cancel(Text("Not now"))
                    )
                }
            }
            .navigationTitle("Add Remote Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        cancelHermesPairing()
                        dismiss()
                    }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
        #if DEBUG
        .accessibilityIdentifier(
            checkpointScenario.map { "hermes-link-checkpoint-\($0.rawValue)" }
                ?? "alleycat-add-server-sheet"
        )
        #else
        .accessibilityIdentifier("alleycat-add-server-sheet")
        #endif
        .onDisappear {
            hermesPairing.pause()
        }
        .task {
            hermesPairing.restoreAndResume()
            #if DEBUG
            switch checkpointScenario {
            case .copied, .renewed:
                copiedAgentPrompt = true
            case .scanner:
                showScanner = true
            case .cameraDenied:
                presentCameraDeniedAlert()
            case .parseError:
                parseError = "Redacted fixture could not parse the pairing response."
            case .confirmation:
                if let host = hermesPairing.readyHost {
                    presentHermesConfirmation(host: host)
                }
            case .validReview:
                installCheckpointPairingFixture()
            default:
                break
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                hermesPairing.resume()
            } else {
                hermesPairing.pause()
            }
        }
        .onChange(of: hermesPairing.readyHost) { _, host in
            guard let host else { return }
            presentHermesConfirmation(host: host)
        }
        #if DEBUG
        .overlay {
            strictScannerOverlay
        }
        #endif
        // Production keeps the full-screen camera presentation. Strict roots
        // render the same scanner chrome in-place so the screenshot-visible
        // isolation sentinel remains above it and no capture view is created.
        .fullScreenCover(
            isPresented: productionScannerPresentation,
            onDismiss: handleProductionScannerDismissed
        ) {
            QRScannerScreen(
                onScan: { scanned in
                    showScanner = false
                    handleScannedPayload(scanned)
                },
                onCancel: {
                    showScanner = false
                },
                onPermissionDenied: {
                    pendingCameraDeniedAlert = true
                    showScanner = false
                },
                captureEnabled: true,
                copyCommand: platform.copyScannerCommand,
                showsNonLiveCheckpointBadge: false
            )
        }
    }

    private func handleProductionScannerDismissed() {
        guard pendingCameraDeniedAlert else { return }
        pendingCameraDeniedAlert = false
        presentCameraDeniedAlert()
    }

    private var productionScannerPresentation: Binding<Bool> {
        Binding(
            get: {
                #if DEBUG
                return checkpointScenario == nil && showScanner
                #else
                return showScanner
                #endif
            },
            set: { showScanner = $0 }
        )
    }

    #if DEBUG
    @ViewBuilder
    private var strictScannerOverlay: some View {
        if checkpointScenario != nil, showScanner {
            QRScannerScreen(
                onScan: { _ in },
                onCancel: { showScanner = false },
                onPermissionDenied: { showScanner = false },
                captureEnabled: false,
                copyCommand: {},
                showsNonLiveCheckpointBadge: true
            )
            .transition(.opacity)
            .zIndex(10)
        }
    }

    private func checkpointBoundary(scenario: HermesLinkCheckpointScenario) -> some View {
        Text("NON-LIVE CHECKPOINT — redacted fixture only")
            .litterFont(.caption2, weight: .bold)
            .foregroundColor(LitterTheme.warning)
            .accessibilityIdentifier("hermes-link-checkpoint-boundary")
            .accessibilityLabel("NON-LIVE CHECKPOINT — redacted fixture only")
    }

    private func installCheckpointPairingFixture() {
        let params = AppAlleycatPairPayload(
            v: 1, nodeId: "fixture-node", token: "REDACTED", relay: nil, hostName: "Redacted Test Host"
        )
        let agent = AppAlleycatAgentInfo(
            name: "fixture-agent", displayName: "Fixture Agent", runtimeKind: nil,
            wire: .websocket, available: true, presentation: nil, capabilities: nil
        )
        parsedParams = params
        displayName = "Redacted Test Host"
        agents = [agent]
        selectedAgentNames = [agent.name]
        isLoadingAgents = false
        pairingRequestIDForParsedParams = hermesPairing.request?.requestId
    }
    #endif

    private var pairingSection: some View {
        Section {
            agentAssistedPairingControls

            // Mac (Catalyst + iOS-on-Mac) shows paste-JSON only; iOS shows
            // QR scanning first, with paste available as a production fallback
            // for users who already copied the pairing payload.
            if platform.rendersAsMacApp() {
                pasteJSONPairingControls
            } else {
                qrPairingControls
            }
        } header: {
            Text("Pairing")
                .foregroundColor(LitterTheme.textSecondary)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    @ViewBuilder
    private var agentAssistedPairingControls: some View {
        let hasActiveRequest = AgentAssistedPairingPromptLabelPolicy.hasActiveRequest(
            expiresAt: hermesPairing.request?.expiresAt,
            now: platform.now()
        )
        VStack(alignment: .leading, spacing: 10) {
            Label("Let Hermes set it up", systemImage: "sparkles")
                .litterFont(.subheadline, weight: .semibold)
                .foregroundColor(LitterTheme.textPrimary)

            Text("Copy this prompt into Hermes on the computer you want to connect. Hermes performs the setup and sends the pairing securely to Learnfold.")
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                copyAgentSetupPrompt()
            } label: {
                HStack {
                    if hermesPairing.isCreating {
                        ProgressView().tint(.black).accessibilityIdentifier("hermes-link-action-spinner")
                    }
                    Label(
                        AgentAssistedPairingPromptLabelPolicy.title(
                            hasCopiedPrompt: copiedAgentPrompt,
                            hasActiveRequest: hasActiveRequest,
                            needsNewPrompt: hermesPairing.shouldCopyNewSetupPrompt
                        ),
                        systemImage: AgentAssistedPairingPromptLabelPolicy.systemImage(
                            hasCopiedPrompt: copiedAgentPrompt,
                            hasActiveRequest: hasActiveRequest
                        )
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(LitterTheme.accent)
            .foregroundColor(.black)
            .disabled(hermesPairing.isCreating)
            .accessibilityIdentifier("alleycat.copyAgentSetupPrompt")

            if hermesPairing.request != nil {
                HStack(spacing: 8) {
                    if hermesPairing.phase == .polling || hermesPairing.phase == .claiming {
                        ProgressView().tint(LitterTheme.accent).accessibilityIdentifier("hermes-link-status-spinner")
                    }
                    Text(hermesPairing.statusMessage)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                        .accessibilityIdentifier("hermes-link-status")
                    Spacer()
                    if hermesPairing.canReviewReadyPairing && !isConnecting && !isLoadingAgents {
                        Button {
                            #if DEBUG
                            if checkpointScenario != nil {
                                reviewActivationCount += 1
                            }
                            #endif
                            guard let host = hermesPairing.readyHost else { return }
                            presentHermesConfirmation(host: host)
                        } label: {
                            Text("Review")
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.accent)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("hermes-link-review")
                    } else {
                        Button("Cancel") {
                            cancelHermesPairing()
                        }
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.warning)
                    }
                }
            } else {
                Text(hermesPairing.statusMessage)
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textMuted)
                    .accessibilityIdentifier("hermes-link-status")
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = hermesPairing.errorMessage {
                Text(error)
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hermes-link-error")
            }

            Text("No command or credential needs to be copied back. Learnfold will show the computer name and ask before connecting.")
                .litterFont(.caption2)
                .foregroundColor(LitterTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var pasteJSONPairingControls: some View {
        Text("Or paste a pairing response manually.")
            .litterFont(.caption)
            .foregroundColor(LitterTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        pasteJSONEntryControls(minHeight: 110)
    }

    @ViewBuilder
    private var qrPairingControls: some View {
        Button {
            requestCameraAndScan()
        } label: {
            HStack {
                Image(systemName: "qrcode.viewfinder")
                    .foregroundColor(LitterTheme.accent)
                Text(parsedParams == nil ? "Scan Pairing QR" : "Rescan QR")
                    .litterFont(.subheadline)
                    .foregroundColor(LitterTheme.accent)
            }
        }
        .accessibilityIdentifier("alleycat.scanPairingQR")

        DisclosureGroup(
            isExpanded: $showPaste,
            content: {
                pasteJSONEntryControls(minHeight: 90)
            },
            label: {
                Text("Advanced: paste pairing JSON")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textSecondary)
            }
        )
    }

    @ViewBuilder
    private func pasteJSONEntryControls(minHeight: CGFloat) -> some View {
        TextEditor(text: $pasteJSON)
            .litterFont(.caption)
            .foregroundColor(LitterTheme.textPrimary)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .overlay(alignment: .topLeading) {
                if pasteJSON.isEmpty {
                    Text(#"{"v":1,"node_id":"...","token":"...","relay":"https://..."}"#)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textMuted)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
            }

        HStack {
            Button("Paste from Clipboard") {
                #if DEBUG
                if checkpointScenario != nil {
                    pasteJSON = #"{"fixture":"NON-LIVE"}"#
                } else if let clipboard = platform.readClipboard() {
                    pasteJSON = clipboard
                }
                #else
                if let clipboard = platform.readClipboard() {
                    pasteJSON = clipboard
                }
                #endif
            }
            .accessibilityIdentifier("alleycat.pastePairingJSON")
            .litterFont(.footnote)
            .foregroundColor(LitterTheme.accent)

            Spacer()

            Button(parsedParams == nil ? "Parse JSON" : "Reparse JSON") {
                handleScannedPayload(pasteJSON)
            }
            .accessibilityIdentifier("alleycat.parsePairingJSON")
            .litterFont(.footnote)
            .foregroundColor(LitterTheme.accent)
            .disabled(pasteJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func previewSection(params: AppAlleycatPairPayload) -> some View {
        Section {
            previewRow(label: "node", value: shortNodeId(params.nodeId))
            previewRow(label: "protocol", value: "v\(params.v)")
            if let relay = params.relay, !relay.isEmpty {
                previewRow(label: "relay", value: relay)
            }
            if let hostName = params.hostName, !hostName.isEmpty {
                previewRow(label: "host", value: hostName)
            }
            TextField("display name (optional)", text: $displayName)
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        } header: {
            Text("Scanned Host")
                .foregroundColor(LitterTheme.textSecondary)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private var agentSection: some View {
        Section {
            if isLoadingAgents {
                HStack {
                    ProgressView().tint(LitterTheme.accent)
                    Text("Loading agents")
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                }
            } else if agents.isEmpty {
                Text("No agents are available on this host.")
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textMuted)
            } else {
                ForEach(agents, id: \.name) { agent in
                    Button {
                        guard agent.available else { return }
                        toggleAgentSelection(agent)
                    } label: {
                        HStack(spacing: 10) {
                            AgentIconView(kind: agent.name.lowercased(), size: 22)
                                .opacity(agent.available ? 1 : 0.45)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(agent.displayName)
                                        .litterFont(.subheadline)
                                        .foregroundColor(agent.available ? LitterTheme.textPrimary : LitterTheme.textMuted)
                                    if AgentRuntimeKind.isBetaAgentName(agent.name, displayName: agent.displayName) {
                                        BetaBadge()
                                    }
                                }
                                Text(wireLabel(agent.wire))
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                            Spacer()
                            if selectedAgentNames.contains(agent.name) {
                                Image(systemName: "checkmark.square.fill")
                                    .foregroundColor(LitterTheme.accent)
                            } else if !agent.available {
                                Text("Unavailable")
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.textMuted)
                            } else {
                                Image(systemName: "square")
                                    .foregroundColor(LitterTheme.textMuted)
                            }
                        }
                    }
                    .disabled(!agent.available)
                }
            }
        } header: {
            HStack {
                Text("Agents")
                Spacer()
                if !availableAgents.isEmpty {
                    Button(selectedAgents.count == availableAgents.count ? "None" : "All") {
                        if selectedAgents.count == availableAgents.count {
                            selectedAgentNames = []
                        } else {
                            selectedAgentNames = Set(availableAgents.map(\.name))
                        }
                    }
                    .font(.caption)
                    .foregroundColor(LitterTheme.accent)
                }
            }
                .foregroundColor(LitterTheme.textSecondary)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private func previewRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textSecondary)
            Spacer()
            Text(value)
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var connectSection: some View {
        Section {
            Button {
                connect(pairingRequestID: pairingRequestIDForParsedParams)
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
            .disabled(!canConnect)
            .accessibilityIdentifier("alleycat.connectRemoteHost")
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private func errorSection(
        _ message: String,
        color: Color,
        accessibilityID: String = "alleycat-error"
    ) -> some View {
        Section {
            Text(message)
                .litterFont(.caption)
                .foregroundColor(color)
                .accessibilityIdentifier(accessibilityID)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private var availableAgents: [AppAlleycatAgentInfo] {
        agents.filter(\.available)
    }

    private var selectedAgents: [AppAlleycatAgentInfo] {
        agents.filter { $0.available && selectedAgentNames.contains($0.name) }
    }

    private var canConnect: Bool {
        !isConnecting && !isLoadingAgents && parsedParams != nil && !selectedAgents.isEmpty
    }

    private func toggleAgentSelection(_ agent: AppAlleycatAgentInfo) {
        if selectedAgentNames.contains(agent.name) {
            selectedAgentNames.remove(agent.name)
        } else {
            selectedAgentNames.insert(agent.name)
        }
    }

    private func handleScannedPayload(
        _ raw: String,
        connectAfterLoading: Bool = false,
        pairingRequestID: String? = nil
    ) {
        let trimmed = AgentAssistedPairing.pairingPayloadCandidate(from: raw)
        guard !trimmed.isEmpty else { return }
        #if DEBUG
        if checkpointScenario != nil {
            connectAfterAgentLoad = false
            pairingRequestIDForParsedParams = nil
            parsedParams = nil
            agents = []
            selectedAgentNames = []
            parseError = "Redacted fixture could not parse the pairing response."
            return
        }
        #endif
        do {
            let params = try runtime.parsePairPayload(trimmed)
            connectAfterAgentLoad = connectAfterLoading
            pairingRequestIDForParsedParams = pairingRequestID
            parsedParams = params
            displayName = suggestedDisplayName(for: params)
            parseError = nil
            connectError = nil
            agentError = nil
            agents = []
            selectedAgentNames = []
            loadAgents(params: params, pairingRequestID: pairingRequestID)
        } catch {
            connectAfterAgentLoad = false
            pairingRequestIDForParsedParams = nil
            parsedParams = nil
            agents = []
            selectedAgentNames = []
            parseError = error.localizedDescription
        }
    }

    private func copyAgentSetupPrompt() {
        parseError = nil
        copiedAgentPrompt = false

        Task {
            do {
                let pairing = try await hermesPairing.createRequest(
                    installationId: pairingInstallationId
                )
                guard hermesPairing.request?.requestId == pairing.requestId else { return }
                let prompt = AgentAssistedPairing.prompt(
                    submitURL: pairing.submitURL
                )
                #if DEBUG
                if checkpointScenario != nil {
                    withAnimation(.easeOut(duration: 0.15)) { copiedAgentPrompt = true }
                    return
                }
                #endif
                platform.writeExpiringPrompt(prompt, pairing.expiresAt)
                withAnimation(.easeOut(duration: 0.15)) {
                    copiedAgentPrompt = true
                }
            } catch is CancellationError {
                return
            } catch {
                copiedAgentPrompt = false
            }
        }
    }

    private var pairingInstallationId: String {
        #if DEBUG
        if checkpointScenario != nil { return "REDACTED-INSTALLATION" }
        #endif
        return platform.loadOrCreateInstallationID()
    }

    private func hermesConfirmationMessage(
        host: HermesPairingStatus.Host,
        isRetry: Bool
    ) -> String {
        let name = host.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = name?.isEmpty == false ? name! : shortNodeId(host.nodeId)
        if isRetry {
            return "Retry the connection to \(display) using the same secure pairing request?"
        }
        return "\(display) is ready to connect. The one-time credential will only be claimed after you tap Connect."
    }

    private func presentCameraDeniedAlert() {
        alertPresentation = .cameraDenied(id: UUID())
    }

    private func presentHermesConfirmation(host: HermesPairingStatus.Host) {
        alertPresentation = .hermesReady(
            id: UUID(),
            host: host,
            isRetry: hermesPairing.phase == .claimed
        )
    }

    private func claimHermesPairingAndConnect() {
        Task {
            if let claim = await hermesPairing.claim() {
                #if DEBUG
                if checkpointScenario != nil {
                    alertPresentation = nil
                    installCheckpointPairingFixture()
                    connect(pairingRequestID: claim.requestID)
                    return
                }
                #endif
                alertPresentation = nil
                handleScannedPayload(
                    claim.payload,
                    connectAfterLoading: true,
                    pairingRequestID: claim.requestID
                )
            }
        }
    }

    private func cancelHermesPairing() {
        hermesPairing.cancel()
        copiedAgentPrompt = false
        alertPresentation = nil
    }

    private func loadAgents(params: AppAlleycatPairPayload, pairingRequestID: String?) {
        isLoadingAgents = true
        Task {
            do {
                let loaded = try await runtime.listAgents(params)
                await MainActor.run {
                    guard parsedParams?.nodeId == params.nodeId,
                          pairingRequestIDForParsedParams == pairingRequestID
                    else { return }
                    agents = loaded
                    selectedAgentNames = Set(
                        loaded
                            .filter { $0.available && !AgentRuntimeKind.isBetaAgentName($0.name, displayName: $0.displayName) }
                            .map(\.name)
                    )
                    isLoadingAgents = false
                    agentError = nil
                    if connectAfterAgentLoad {
                        connectAfterAgentLoad = false
                        Task { @MainActor in
                            await Task.yield()
                            connect(pairingRequestID: pairingRequestID)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    guard parsedParams?.nodeId == params.nodeId,
                          pairingRequestIDForParsedParams == pairingRequestID
                    else { return }
                    agents = []
                    selectedAgentNames = []
                    isLoadingAgents = false
                    agentError = error.localizedDescription
                    connectAfterAgentLoad = false
                }
            }
        }
    }

    private func connect(pairingRequestID: String?) {
        #if DEBUG
        if checkpointScenario != nil {
            isConnecting = false
            _ = hermesPairing.completeConnection(requestID: pairingRequestID)
            return
        }
        #endif
        guard let params = parsedParams, let fallbackAgent = selectedAgents.first else { return }
        let trimmedDisplay = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedDisplay.isEmpty ? suggestedDisplayName(for: params) : trimmedDisplay
        let selectedNames = selectedAgents.map(\.name)
        let serverId = "alleycat:\(params.nodeId)"

        isConnecting = true
        connectError = nil

        Task {
            do {
                let result = try await runtime.connect(
                    HermesLinkConnectRequest(
                        serverId: serverId,
                        displayName: resolvedName,
                        params: params,
                        agentName: fallbackAgent.name,
                        selectedAgentNames: selectedNames,
                        wire: fallbackAgent.wire
                    )
                )
                let credentialCommit = HermesPairingConnectionCommitPolicy.persistCredential(
                    token: params.token,
                    nodeID: params.nodeId
                ) { token, nodeID in
                    try runtime.saveCredential(token, nodeID)
                }
                if case .failure = credentialCommit {
                    await MainActor.run {
                        isConnecting = false
                        connectError = HermesPairingConnectionCommitPolicy.credentialPersistenceFailureMessage
                    }
                    return
                }
                // First successful alleycat pair triggers the iroh
                // endpoint bind. Persist the freshly-generated device
                // secret key so the next cold launch reuses the same
                // `EndpointId`.
                await MainActor.run {
                    runtime.persistRuntimeSecretIfNeeded()
                }

                // The broker request stays recoverable until the remote target
                // is actually connected and its credential is committed.
                if pairingRequestID != nil,
                   !hermesPairing.completeConnection(requestID: pairingRequestID) {
                    await MainActor.run {
                        isConnecting = false
                        connectError = hermesPairing.errorMessage
                            ?? "The host connected, but the active Hermes request changed. The current request was kept."
                    }
                    return
                }

                await MainActor.run {
                    isConnecting = false
                    onConnected(
                        AlleycatConnectedTarget(
                            serverId: result.serverId,
                            nodeId: result.nodeId,
                            displayName: resolvedName,
                            params: params,
                            agentName: result.agentName,
                            agentWire: fallbackAgent.wire
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    connectError = error.localizedDescription
                }
            }
        }
    }

    private func requestCameraAndScan() {
        #if DEBUG
        if checkpointScenario != nil {
            showScanner = true
            return
        }
        #endif
        switch platform.cameraAuthorization() {
        case .authorized:
            showScanner = true
        case .notDetermined:
            Task { @MainActor in
                if await platform.requestCameraAccess() {
                    showScanner = true
                } else {
                    presentCameraDeniedAlert()
                }
            }
        case .denied:
            presentCameraDeniedAlert()
        }
    }

    private func openAppSettings() {
        #if DEBUG
        guard checkpointScenario == nil else { return }
        #endif
        platform.openAppSettings()
    }

    private func suggestedDisplayName(for params: AppAlleycatPairPayload) -> String {
        let hostName = params.hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hostName.isEmpty {
            return hostName
        }
        return "Alleycat \(shortNodeId(params.nodeId))"
    }

    private func shortNodeId(_ raw: String) -> String {
        if raw.count <= 16 { return raw }
        return "\(raw.prefix(8))...\(raw.suffix(8))"
    }

    private func wireLabel(_ wire: AppAlleycatAgentWire) -> String {
        switch wire {
        case .websocket:
            return "websocket"
        case .jsonl:
            return "jsonl"
        }
    }

}

#if DEBUG
/// Direct typed root for central strict-launch dispatch. It deliberately has
/// no `AppModel` input and owns the Link sentinel boundary so callers must not
/// wrap it in a second banner.
@MainActor
struct HermesLinkStrictCheckpointRoot: View {
    let scenario: HermesLinkCheckpointScenario

    var body: some View {
        AlleycatAddServerSheet(checkpointScenario: scenario)
            .learnfoldStrictHarnessBoundary(.hermesLink)
    }
}
#endif

// MARK: - QR Scanner

private struct QRScannerScreen: View {
    let onScan: (String) -> Void
    let onCancel: () -> Void
    let onPermissionDenied: () -> Void
    let captureEnabled: Bool
    let onCopyCommand: () -> Void
    let showsNonLiveCheckpointBadge: Bool

    private static let pairCommand = "npx learnfold-link"

    @State private var copied = false
    @State private var captureController: QRScannerViewController?

    init(
        onScan: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onPermissionDenied: @escaping () -> Void,
        captureEnabled: Bool,
        copyCommand: @escaping () -> Void,
        showsNonLiveCheckpointBadge: Bool
    ) {
        self.onScan = onScan
        self.onCancel = onCancel
        self.onPermissionDenied = onPermissionDenied
        self.captureEnabled = captureEnabled
        self.onCopyCommand = copyCommand
        self.showsNonLiveCheckpointBadge = showsNonLiveCheckpointBadge
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if captureEnabled {
                QRCaptureSheet(
                    onScan: onScan,
                    onPermissionDenied: onPermissionDenied,
                    onControllerReady: { controller in
                        captureController = controller
                    }
                )
                .ignoresSafeArea()
            }

            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 320)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 16) {
                if showsNonLiveCheckpointBadge {
                    Text("NON-LIVE CHECKPOINT — camera disabled")
                        .font(.caption.weight(.bold))
                        .foregroundColor(LitterTheme.accent)
                        .accessibilityIdentifier("hermes-link-scanner-checkpoint-boundary")
                }
                topBar
                instructionsCard
                Spacer()
                framingHint
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button(action: cancelCapture) {
                Text("Cancel")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("alleycat.scanner.cancelButton")
        }
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair with Learnfold Link")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            stepRow(number: "1", title: "On the host you want to connect to, run:")
            commandRow
            stepRow(number: "2", title: "Point this camera at the QR code it prints.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.8)
        )
    }

    private func stepRow(number: String, title: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.black)
                .frame(width: 20, height: 20)
                .background(LitterTheme.accent, in: Circle())
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var commandRow: some View {
        HStack(spacing: 10) {
            Text(Self.pairCommand)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.12))
                )
            Button(action: copyCommand) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("alleycat.scanner.copyCommandButton")
            .accessibilityLabel(copied ? "Copied" : "Copy command")
        }
        .padding(.leading, 30)
    }

    private var framingHint: some View {
        Text("Hold steady — the QR code is detected automatically.")
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.75))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.4), in: Capsule())
    }

    private func copyCommand() {
        onCopyCommand()
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }

    private func cancelCapture() {
        captureController?.cancelCapture()
        onCancel()
    }
}

private struct QRCaptureSheet: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onPermissionDenied: () -> Void
    let onControllerReady: (QRScannerViewController) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        controller.onPermissionDenied = onPermissionDenied
        onControllerReady(controller)
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    static func dismantleUIViewController(
        _ uiViewController: QRScannerViewController,
        coordinator: ()
    ) {
        uiViewController.invalidateCaptureLifecycle()
    }
}

private struct QRScannerCaptureLifecycle: Sendable {
    var generation: UInt64 = 0
    var isActive = false
    var didReportScan = false
}

/// `Mutex` is noncopyable, so it stays inside this immutable reference while
/// the session queue retains the reference rather than consuming a field from
/// the main-actor view controller. Every mutable field is protected by `state`.
private final class QRScannerCaptureLifecycleStore: @unchecked Sendable {
    private let state = Mutex(QRScannerCaptureLifecycle())

    func begin() -> UInt64 {
        state.withLock { lifecycle in
            lifecycle.generation &+= 1
            lifecycle.isActive = true
            lifecycle.didReportScan = false
            return lifecycle.generation
        }
    }

    func invalidate() {
        state.withLock { lifecycle in
            lifecycle.generation &+= 1
            lifecycle.isActive = false
        }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { lifecycle in
            lifecycle.isActive && lifecycle.generation == generation
        }
    }

    func claimDelivery() -> UInt64? {
        state.withLock { lifecycle in
            guard lifecycle.isActive, !lifecycle.didReportScan else { return nil }
            lifecycle.didReportScan = true
            return lifecycle.generation
        }
    }
}

@MainActor
private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let metadataQueue = DispatchQueue(label: "com.alleycat.qrscanner")
    private let sessionQueue = DispatchQueue(label: "com.alleycat.qrscanner.session")
    // AVFoundation invokes its metadata delegate on `metadataQueue`, not the
    // main actor. The generation gates both repeat frames and callbacks queued
    // while the scanner is being dismissed.
    nonisolated private let captureLifecycle = QRScannerCaptureLifecycleStore()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        beginCaptureLifecycle()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        invalidateCaptureLifecycle()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            onPermissionDenied?()
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            onPermissionDenied?()
            return
        }
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        } else {
            onPermissionDenied?()
            return
        }

        let output = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: metadataQueue)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
        } else {
            onPermissionDenied?()
            return
        }

        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    func cancelCapture() {
        invalidateCaptureLifecycle()
    }

    func invalidateCaptureLifecycle() {
        captureLifecycle.invalidate()
        stopCaptureSession()
    }

    private func beginCaptureLifecycle() {
        let generation = captureLifecycle.begin()
        let captureSession = captureSession
        let captureLifecycle = captureLifecycle
        sessionQueue.async {
            guard captureLifecycle.isCurrent(generation) else { return }

            if !captureSession.isRunning {
                captureSession.startRunning()
            }

            // Cancellation can win just after start. Queueing the stop on the
            // same session queue ensures it cannot leave capture resurrected.
            guard captureLifecycle.isCurrent(generation) else {
                if captureSession.isRunning {
                    captureSession.stopRunning()
                }
                return
            }
        }
    }

    private func stopCaptureSession() {
        let captureSession = captureSession
        sessionQueue.async {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let payload = metadataObjects
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first(where: { $0.type == .qr })?
            .stringValue
        else { return }

        let deliveryGeneration = captureLifecycle.claimDelivery()
        guard let deliveryGeneration else { return }

        // `payload` is an immutable String snapshot, so no AVFoundation
        // metadata object crosses into the main-actor UI/state callback. The
        // generation check rejects a frame queued before Cancel/dismissal.
        Task { @MainActor [weak self, payload, deliveryGeneration] in
            guard let self,
                  self.captureLifecycle.isCurrent(deliveryGeneration)
            else { return }
            self.invalidateCaptureLifecycle()
            self.onScan?(payload)
        }
    }
}
