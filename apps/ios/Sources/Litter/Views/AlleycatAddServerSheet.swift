import AVFoundation
import Foundation
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
    `npx -y learnfold-link@0.3.9 handoff "\(submitURL.absoluteString)"`

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
    1. Run `npx -y learnfold-link@0.3.9 rotate` to invalidate every existing Learnfold pairing.
    2. Run `npx -y learnfold-link@0.3.9 uninstall` to disable autostart and stop the managed service.
    3. If a Learnfold Link or Alleycat daemon is still running, run \
    `npx -y learnfold-link@0.3.9 stop`.
    4. Verify that autostart is disabled and no Learnfold Link or Alleycat daemon remains running.

    Do not display the new token. Do not delete Hermes, projects, configuration, or logs. \
    Do not ask me to run any commands. Report only whether revocation and shutdown succeeded.

    This request intentionally ends Learnfold's connection, so complete it from this external \
    Hermes chat even if Learnfold disconnects before receiving a final response.
    """
    }
}

struct HermesPairingRequest: Decodable, Equatable {
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

struct HermesPairingStatus: Decodable, Equatable {
    struct Host: Decodable, Equatable {
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

actor HermesPairingBrokerClient {
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

struct AlleycatAddServerSheet: View {
    let appModel: AppModel
    let onConnected: (AlleycatConnectedTarget) -> Void

    @Environment(\.dismiss) private var dismiss
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
    @State private var cameraDenied = false
    // pasteJSON / showPaste are used by the Mac paste-JSON UI
    // (Catalyst + iOS-on-Mac) and the iOS QR fallback.
    @State private var pasteJSON: String = ""
    @State private var showPaste: Bool = false
    @State private var copiedAgentPrompt = false
    @State private var isPreparingAgentPrompt = false
    @State private var hermesPairingRequest: HermesPairingRequest?
    @State private var hermesPairingStatus = "Create a secure request, then paste the prompt into Hermes."
    @State private var hermesReadyHost: HermesPairingStatus.Host?
    @State private var showHermesConfirmation = false
    @State private var hermesPollingTask: Task<Void, Never>?
    @State private var connectAfterAgentLoad = false

    private let alleycat = RustAlleycatBridge.shared
    private let pairingBroker = HermesPairingBrokerClient.shared

    init(
        appModel: AppModel,
        onConnected: @escaping (AlleycatConnectedTarget) -> Void
    ) {
        self.appModel = appModel
        self.onConnected = onConnected
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    pairingSection
                    if let params = parsedParams {
                        previewSection(params: params)
                        agentSection
                    }
                    if let parseError {
                        errorSection(parseError, color: LitterTheme.warning)
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
        .onDisappear {
            cancelHermesPairing()
        }
        // QR scanner cover + camera-denied alert are applied
        // unconditionally; on Mac builds (Catalyst + iOS-on-Mac) the
        // pairing section never triggers `requestCameraAndScan`, so
        // neither presentation ever fires.
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerScreen(
                onScan: { scanned in
                    showScanner = false
                    handleScannedPayload(scanned)
                },
                onCancel: {
                    showScanner = false
                },
                onPermissionDenied: {
                    showScanner = false
                    cameraDenied = true
                }
            )
        }
        .alert(
            "Camera Access Needed",
            isPresented: $cameraDenied,
            actions: {
                Button("Open Settings") { openAppSettings() }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("Allow camera access in Settings to scan an Alleycat pairing QR code.")
            }
        )
        .alert(
            "Hermes is ready",
            isPresented: $showHermesConfirmation,
            actions: {
                Button("Connect") { claimHermesPairingAndConnect() }
                Button("Not now", role: .cancel) { cancelHermesPairing() }
            },
            message: {
                Text(hermesConfirmationMessage)
            }
        )
    }

    private var pairingSection: some View {
        Section {
            agentAssistedPairingControls

            // Mac (Catalyst + iOS-on-Mac) shows paste-JSON only; iOS shows
            // QR scanning first, with paste available as a production fallback
            // for users who already copied the pairing payload.
            if LitterPlatform.rendersAsMacApp {
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
                    if isPreparingAgentPrompt {
                        ProgressView().tint(.black)
                    }
                    Label(
                        copiedAgentPrompt ? "Prompt Copied — Waiting" : "Copy Setup Prompt",
                        systemImage: copiedAgentPrompt ? "checkmark.circle.fill" : "doc.on.doc"
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(LitterTheme.accent)
            .foregroundColor(.black)
            .disabled(isPreparingAgentPrompt)
            .accessibilityIdentifier("alleycat.copyAgentSetupPrompt")

            if hermesPairingRequest != nil {
                HStack(spacing: 8) {
                    ProgressView().tint(LitterTheme.accent)
                    Text(hermesPairingStatus)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                    Spacer()
                    Button("Cancel") {
                        cancelHermesPairing()
                    }
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.warning)
                }
            } else {
                Text(hermesPairingStatus)
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
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
                if let clipboard = UIPasteboard.general.string {
                    pasteJSON = clipboard
                }
            }
            .litterFont(.footnote)
            .foregroundColor(LitterTheme.accent)

            Spacer()

            Button(parsedParams == nil ? "Parse JSON" : "Reparse JSON") {
                handleScannedPayload(pasteJSON)
            }
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
            .disabled(!canConnect)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private func errorSection(_ message: String, color: Color) -> some View {
        Section {
            Text(message)
                .litterFont(.caption)
                .foregroundColor(color)
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

    private func handleScannedPayload(_ raw: String, connectAfterLoading: Bool = false) {
        let trimmed = AgentAssistedPairing.pairingPayloadCandidate(from: raw)
        guard !trimmed.isEmpty else { return }
        do {
            let params = try alleycat.parsePairPayload(json: trimmed)
            connectAfterAgentLoad = connectAfterLoading
            parsedParams = params
            displayName = suggestedDisplayName(for: params)
            parseError = nil
            connectError = nil
            agentError = nil
            agents = []
            selectedAgentNames = []
            loadAgents(params: params)
        } catch {
            connectAfterAgentLoad = false
            parsedParams = nil
            agents = []
            selectedAgentNames = []
            parseError = error.localizedDescription
        }
    }

    private func copyAgentSetupPrompt() {
        cancelHermesPairing()
        isPreparingAgentPrompt = true
        parseError = nil

        Task {
            do {
                let pairing = try await pairingBroker.createRequest(
                    installationId: pairingInstallationId
                )
                await MainActor.run {
                    hermesPairingRequest = pairing
                    hermesPairingStatus = "Waiting for Hermes…"
                    let prompt = AgentAssistedPairing.prompt(
                        submitURL: pairing.submitURL
                    )
                    UIPasteboard.general.setItems(
                        [[UTType.plainText.identifier: prompt]],
                        options: [.expirationDate: pairing.expiresAt]
                    )
                    withAnimation(.easeOut(duration: 0.15)) {
                        copiedAgentPrompt = true
                    }
                    isPreparingAgentPrompt = false
                    startPollingHermesPairing(pairing)
                }
            } catch {
                await MainActor.run {
                    isPreparingAgentPrompt = false
                    copiedAgentPrompt = false
                    hermesPairingStatus = "Create a secure request, then paste the prompt into Hermes."
                    parseError = error.localizedDescription
                }
            }
        }
    }

    private var pairingInstallationId: String {
        let key = "learnfold.pairingInstallationId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private var hermesConfirmationMessage: String {
        guard let host = hermesReadyHost else {
            return "Hermes submitted a pairing request. Connect to this computer?"
        }
        let name = host.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = name?.isEmpty == false ? name! : shortNodeId(host.nodeId)
        return "\(display) is ready to connect. The one-time credential will only be claimed after you tap Connect."
    }

    private func startPollingHermesPairing(_ pairing: HermesPairingRequest) {
        hermesPollingTask?.cancel()
        hermesPollingTask = Task {
            while !Task.isCancelled {
                if Date() >= pairing.expiresAt {
                    await MainActor.run {
                        clearHermesPairingState(
                            status: "The request expired. Copy a new setup prompt to try again."
                        )
                    }
                    return
                }
                do {
                    let status = try await pairingBroker.status(for: pairing)
                    if status.state == "ready", let host = status.host {
                        await MainActor.run {
                            hermesPairingStatus = "Hermes sent the pairing securely."
                            hermesReadyHost = host
                            showHermesConfirmation = true
                        }
                        return
                    }
                } catch {
                    await MainActor.run {
                        parseError = error.localizedDescription
                        clearHermesPairingState(
                            status: "Could not continue this request. Copy a new prompt to retry."
                        )
                    }
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func claimHermesPairingAndConnect() {
        guard let pairing = hermesPairingRequest else { return }
        hermesPollingTask?.cancel()
        hermesPairingStatus = "Claiming the one-time credential…"
        Task {
            do {
                let payload = try await pairingBroker.claim(pairing)
                await MainActor.run {
                    hermesPairingRequest = nil
                    hermesReadyHost = nil
                    copiedAgentPrompt = false
                    hermesPairingStatus = "Pairing received securely."
                    handleScannedPayload(payload, connectAfterLoading: true)
                }
            } catch {
                await MainActor.run {
                    parseError = error.localizedDescription
                    clearHermesPairingState(
                        status: "The credential could not be claimed. Copy a new prompt to retry."
                    )
                }
            }
        }
    }

    private func cancelHermesPairing() {
        hermesPollingTask?.cancel()
        if let pairing = hermesPairingRequest {
            Task { await pairingBroker.cancel(pairing) }
        }
        clearHermesPairingState(
            status: "Create a secure request, then paste the prompt into Hermes."
        )
    }

    private func clearHermesPairingState(status: String) {
        hermesPairingRequest = nil
        hermesReadyHost = nil
        copiedAgentPrompt = false
        isPreparingAgentPrompt = false
        showHermesConfirmation = false
        hermesPairingStatus = status
    }

    private func loadAgents(params: AppAlleycatPairPayload) {
        isLoadingAgents = true
        Task {
            do {
                let loaded = try await appModel.serverBridge.listAlleycatAgents(params: params)
                await MainActor.run {
                    guard parsedParams?.nodeId == params.nodeId else { return }
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
                            connect()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    guard parsedParams?.nodeId == params.nodeId else { return }
                    agents = []
                    selectedAgentNames = []
                    isLoadingAgents = false
                    agentError = error.localizedDescription
                    connectAfterAgentLoad = false
                }
            }
        }
    }

    private func connect() {
        guard let params = parsedParams, let fallbackAgent = selectedAgents.first else { return }
        let trimmedDisplay = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedDisplay.isEmpty ? suggestedDisplayName(for: params) : trimmedDisplay
        let selectedNames = selectedAgents.map(\.name)
        let serverId = "alleycat:\(params.nodeId)"

        isConnecting = true
        connectError = nil

        Task {
            do {
                let result = try await appModel.serverBridge.connectRemoteOverAlleycat(
                    serverId: serverId,
                    displayName: resolvedName,
                    params: params,
                    agentName: fallbackAgent.name,
                    selectedAgentNames: selectedNames,
                    wire: fallbackAgent.wire
                )
                do {
                    try AlleycatCredentialStore.shared.saveToken(params.token, nodeId: params.nodeId)
                } catch {
                    NSLog("[ALLEYCAT_CREDENTIALS] keychain save failed: %@", error.localizedDescription)
                }
                // First successful alleycat pair triggers the iroh
                // endpoint bind. Persist the freshly-generated device
                // secret key so the next cold launch reuses the same
                // `EndpointId`.
                await MainActor.run {
                    AppRuntimeController.shared.persistAlleycatSecretKeyIfNeeded()
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
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            showScanner = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        showScanner = true
                    } else {
                        cameraDenied = true
                    }
                }
            }
        case .denied, .restricted:
            cameraDenied = true
        @unknown default:
            cameraDenied = true
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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

// MARK: - QR Scanner

private struct QRScannerScreen: View {
    let onScan: (String) -> Void
    let onCancel: () -> Void
    let onPermissionDenied: () -> Void

    private static let pairCommand = "npx learnfold-link"

    @State private var copied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            QRCaptureSheet(
                onScan: onScan,
                onCancel: onCancel,
                onPermissionDenied: onPermissionDenied
            )
            .ignoresSafeArea()

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
            Button(action: onCancel) {
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
        UIPasteboard.general.string = Self.pairCommand
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }
}

private struct QRCaptureSheet: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onCancel: () -> Void
    let onPermissionDenied: () -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        controller.onCancel = onCancel
        controller.onPermissionDenied = onPermissionDenied
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let metadataQueue = DispatchQueue(label: "com.alleycat.qrscanner")
    private var didReportScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !captureSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
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

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didReportScan else { return }
        guard let payload = metadataObjects
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first(where: { $0.type == .qr })?
            .stringValue
        else { return }
        didReportScan = true
        DispatchQueue.main.async { [weak self] in
            self?.captureSession.stopRunning()
            self?.onScan?(payload)
        }
    }
}
