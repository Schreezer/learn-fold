import SwiftUI

enum SSHLoginSubmissionOutcome: Equatable {
    case accepted
    case rejected(message: String)
    case inProgress

    var disposition: SSHLoginSubmissionDisposition {
        switch self {
        case .accepted:
            return SSHLoginSubmissionDisposition(
                shouldPersistCredentials: true,
                shouldClearSensitiveInput: true,
                shouldKeepSheetPresented: false,
                errorMessage: nil
            )
        case .rejected(let message):
            return SSHLoginSubmissionDisposition(
                shouldPersistCredentials: false,
                shouldClearSensitiveInput: false,
                shouldKeepSheetPresented: true,
                errorMessage: message
            )
        case .inProgress:
            return SSHLoginSubmissionDisposition(
                shouldPersistCredentials: false,
                shouldClearSensitiveInput: false,
                shouldKeepSheetPresented: true,
                errorMessage: nil
            )
        }
    }
}

struct SSHLoginSubmissionDisposition: Equatable {
    let shouldPersistCredentials: Bool
    let shouldClearSensitiveInput: Bool
    let shouldKeepSheetPresented: Bool
    let errorMessage: String?
}

enum SSHLoginRuntimeMode: Equatable {
    case live
    case inertCheckpoint

    var allowsCredentialStoreAccess: Bool {
        self == .live
    }
}

#if DEBUG
enum SSHLoginCheckpointState: String {
    case empty
    case authError = "auth-error"
    case submitted
}
#endif

struct SSHLoginSheet: View {
    let server: DiscoveredServer
    private let onSubmit: (ConnectionTarget) async -> SSHLoginSubmissionOutcome
    private let onAccepted: () -> Void
    private let runtimeMode: SSHLoginRuntimeMode
    private let autoLoadSavedCredentials: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var useKey = false
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var rememberCredentials = true
    @State private var unlockMacosKeychain = false
    @State private var hasSavedCredentials = false
    @State private var loadedSavedCredentials = false
    @State private var isConnecting = false
    @State private var errorMessage: String?
    #if DEBUG
    @State private var checkpointState: SSHLoginCheckpointState?

    var debugRuntimeMode: SSHLoginRuntimeMode { runtimeMode }
    var debugAutoLoadsSavedCredentials: Bool { autoLoadSavedCredentials }
    #endif

    init(
        server: DiscoveredServer,
        runtimeMode: SSHLoginRuntimeMode = .live,
        autoLoadSavedCredentials: Bool = true,
        initialUsername: String = "",
        onConnect: @escaping (ConnectionTarget) -> Void
    ) {
        self.server = server
        self.onSubmit = { target in
            onConnect(target)
            return .accepted
        }
        self.onAccepted = {}
        self.runtimeMode = runtimeMode
        self.autoLoadSavedCredentials =
            autoLoadSavedCredentials && runtimeMode.allowsCredentialStoreAccess
        _username = State(initialValue: initialUsername)
    }

    init(
        server: DiscoveredServer,
        runtimeMode: SSHLoginRuntimeMode = .live,
        autoLoadSavedCredentials: Bool = true,
        initialUsername: String = "",
        onSubmit: @escaping (ConnectionTarget) async -> SSHLoginSubmissionOutcome,
        onAccepted: @escaping () -> Void
    ) {
        self.server = server
        self.onSubmit = onSubmit
        self.onAccepted = onAccepted
        self.runtimeMode = runtimeMode
        self.autoLoadSavedCredentials =
            autoLoadSavedCredentials && runtimeMode.allowsCredentialStoreAccess
        _username = State(initialValue: initialUsername)
    }

    #if DEBUG
    init(
        server: DiscoveredServer,
        checkpointState: SSHLoginCheckpointState,
        onSubmit: @escaping (ConnectionTarget) async -> SSHLoginSubmissionOutcome,
        onAccepted: @escaping () -> Void
    ) {
        self.server = server
        self.onSubmit = onSubmit
        self.onAccepted = onAccepted
        self.runtimeMode = .inertCheckpoint
        self.autoLoadSavedCredentials = false
        _username = State(initialValue: checkpointState == .empty ? "" : "checkpoint-user")
        _password = State(initialValue: checkpointState == .empty ? "" : "fixture-only")
        _rememberCredentials = State(initialValue: false)
        _isConnecting = State(initialValue: checkpointState == .submitted)
        _errorMessage = State(
            initialValue: checkpointState == .authError
                ? "Authentication failed for the redacted test host."
                : nil
        )
        _checkpointState = State(initialValue: checkpointState)
    }
    #endif

    private var sshPort: Int {
        Int(server.resolvedSSHPort)
    }

    private var hostDisplay: String {
        if sshPort == 22 {
            return server.hostname
        }
        return "\(server.hostname):\(sshPort)"
    }

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
                                Text("LF-11 · \(checkpointState.rawValue)")
                                    .litterFont(.footnote, weight: .semibold)
                                    .foregroundColor(LitterTheme.textPrimary)
                            }
                            Text(checkpointState.rawValue)
                                .litterFont(.caption, weight: .semibold)
                                .foregroundColor(LitterTheme.textSecondary)
                                .accessibilityIdentifier("ssh-login-status")
                            Text(password.isEmpty ? "credential empty" : "credential retained")
                                .litterFont(.caption2)
                                .foregroundColor(LitterTheme.textMuted)
                                .accessibilityIdentifier("ssh-login-password-state")
                        } footer: {
                            Text("Static Debug fixture. Keychain and SSH are disabled.")
                                .litterFont(.caption2)
                                .foregroundColor(LitterTheme.textMuted)
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                    #endif
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "terminal")
                                .foregroundColor(LitterTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .litterFont(.subheadline)
                                    .foregroundColor(LitterTheme.textPrimary)
                                Text(hostDisplay)
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                        }
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        TextField("username", text: $username)
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .accessibilityIdentifier("ssh-login-username")
                    } header: {
                        Text("Username")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        Picker("Method", selection: $useKey) {
                            Text("Password").tag(false)
                            Text("SSH Key").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("ssh-login-method")
                        .listRowBackground(LitterTheme.surface.opacity(0.6))

                        if useKey {
                            TextEditor(text: $privateKey)
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textPrimary)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 100)
                                .overlay(alignment: .topLeading) {
                                    if privateKey.isEmpty {
                                        Text("Paste private key here...")
                                            .litterFont(.caption)
                                            .foregroundColor(LitterTheme.textMuted)
                                            .padding(.top, 8)
                                            .padding(.leading, 4)
                                            .allowsHitTesting(false)
                                    }
                                }
                            SecureField("passphrase (optional)", text: $passphrase)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                        } else {
                            passwordInput

                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(isOn: $unlockMacosKeychain) {
                                    Text("Unlock keychain (macOS)")
                                        .litterFont(.footnote)
                                        .foregroundColor(LitterTheme.textPrimary)
                                }
                                .tint(LitterTheme.accent)

                                Text("Uses your SSH/login password during headless bootstrap. Required for tools like gh CLI auth.")
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                        }
                    } header: {
                        Text("Authentication")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        Toggle(isOn: $rememberCredentials) {
                            Text("Remember credentials on this device")
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                        }
                        .tint(LitterTheme.accent)

                        if hasSavedCredentials {
                            Button(role: .destructive) {
                                forgetSavedCredentials()
                            } label: {
                                Text("Forget saved credentials")
                                    .litterFont(.footnote)
                            }
                        }
                    } header: {
                        Text("Saved Credentials")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

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
                        .disabled(isConnecting || username.isEmpty || (!useKey && password.isEmpty) || (useKey && privateKey.isEmpty))
                        .accessibilityIdentifier("ssh-login-connect")
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    if let err = errorMessage {
                        Section {
                            Text(err)
                                .foregroundColor(.red)
                                .litterFont(.caption)
                                .accessibilityIdentifier("ssh-login-error")
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("SSH Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(LitterTheme.accent)
                        .disabled(isConnecting)
                }
            }
        }
        .accessibilityIdentifier("ssh-login-checkpoint-root")
        .serverLifecycleStrictHarnessBoundaryIfActive()
        .interactiveDismissDisabled(isConnecting)
        .task {
            if autoLoadSavedCredentials {
                loadSavedCredentialsIfNeeded()
            }
        }
        .onChange(of: useKey) { _, isUsingKey in
            if isUsingKey {
                isPasswordVisible = false
                unlockMacosKeychain = false
            }
        }
    }

    private var passwordInput: some View {
        HStack(spacing: 8) {
            Group {
                if isPasswordVisible {
                    TextField("password", text: $password)
                        .textContentType(.password)
                } else {
                    SecureField("password", text: $password)
                        .textContentType(.password)
                }
            }
            .litterFont(.footnote)
            .foregroundColor(LitterTheme.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .accessibilityIdentifier("ssh-login-password")

            Button {
                isPasswordVisible.toggle()
            } label: {
                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                    .foregroundColor(LitterTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
        }
    }

    private func connect() {
        let credentials: SSHCredentials
        if useKey {
            credentials = .key(
                username: username,
                privateKey: privateKey,
                passphrase: passphrase.isEmpty ? nil : passphrase
            )
        } else {
            credentials = .password(
                username: username,
                password: password,
                unlockMacosKeychain: unlockMacosKeychain
            )
        }
        isConnecting = true
        errorMessage = nil

        Task {
            let outcome = await onSubmit(
                .sshThenRemote(host: server.hostname, credentials: credentials)
            )
            let disposition = outcome.disposition

            if disposition.shouldPersistCredentials {
                persistAcceptedCredentials(credentials)
            }
            if disposition.shouldClearSensitiveInput {
                clearSensitiveInput()
            }

            switch outcome {
            case .accepted:
                isConnecting = false
                errorMessage = nil
                onAccepted()
            case .rejected(let message):
                isConnecting = false
                errorMessage = message
                #if DEBUG
                if checkpointState != nil {
                    checkpointState = .authError
                }
                #endif
            case .inProgress:
                errorMessage = nil
                #if DEBUG
                if checkpointState != nil {
                    checkpointState = .submitted
                }
                #endif
            }
        }
    }

    private func persistAcceptedCredentials(_ credentials: SSHCredentials) {
        guard runtimeMode.allowsCredentialStoreAccess else {
            LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                "SSHLoginSheet.inertCheckpoint.persistCredentials"
            )
            return
        }
        #if DEBUG
        guard checkpointState == nil else {
            LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                "SSHLoginSheet.checkpoint.persistCredentials"
            )
            return
        }
        #endif
        do {
            if rememberCredentials {
                try SSHCredentialStore.shared.save(
                    savedCredential(from: credentials),
                    host: server.hostname,
                    port: sshPort
                )
                hasSavedCredentials = true
            } else {
                try SSHCredentialStore.shared.delete(host: server.hostname, port: sshPort)
                hasSavedCredentials = false
            }
        } catch {
            NSLog("[SSH_CREDENTIALS] keychain update failed: %@", error.localizedDescription)
        }
    }

    private func loadSavedCredentialsIfNeeded() {
        guard runtimeMode.allowsCredentialStoreAccess else {
            LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                "SSHLoginSheet.inertCheckpoint.loadCredentials"
            )
            return
        }
        #if DEBUG
        guard checkpointState == nil else {
            LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                "SSHLoginSheet.checkpoint.loadCredentials"
            )
            return
        }
        #endif
        guard !loadedSavedCredentials else { return }
        loadedSavedCredentials = true

        do {
            guard let saved = try SSHCredentialStore.shared.load(host: server.hostname, port: sshPort) else {
                hasSavedCredentials = false
                return
            }
            hasSavedCredentials = true
            rememberCredentials = true
            username = saved.username
            useKey = saved.method == .key
            if saved.method == .key {
                privateKey = saved.privateKey ?? ""
                passphrase = saved.passphrase ?? ""
                password = ""
                unlockMacosKeychain = false
            } else {
                password = saved.password ?? ""
                privateKey = ""
                passphrase = ""
                unlockMacosKeychain = saved.unlockMacosKeychain ?? false
            }
        } catch {
            NSLog("[SSH_CREDENTIALS] failed to load: %@", error.localizedDescription)
        }
    }

    private func forgetSavedCredentials() {
        guard runtimeMode.allowsCredentialStoreAccess else {
            LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                "SSHLoginSheet.inertCheckpoint.deleteCredentials"
            )
            return
        }
        #if DEBUG
        guard checkpointState == nil else {
            LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
                "SSHLoginSheet.checkpoint.deleteCredentials"
            )
            return
        }
        #endif
        do {
            try SSHCredentialStore.shared.delete(host: server.hostname, port: sshPort)
            hasSavedCredentials = false
            rememberCredentials = false
            clearSensitiveInput()
        } catch {
            NSLog("[SSH_CREDENTIALS] failed to delete: %@", error.localizedDescription)
        }
    }

    private func savedCredential(from credentials: SSHCredentials) -> SavedSSHCredential {
        switch credentials {
        case .password(let username, let password, let unlockMacosKeychain):
            return SavedSSHCredential(
                username: username,
                method: .password,
                password: password,
                privateKey: nil,
                passphrase: nil,
                unlockMacosKeychain: unlockMacosKeychain
            )
        case .key(let username, let privateKey, let passphrase):
            return SavedSSHCredential(
                username: username,
                method: .key,
                password: nil,
                privateKey: privateKey,
                passphrase: passphrase,
                unlockMacosKeychain: false
            )
        }
    }

    private func clearSensitiveInput() {
        password = ""
        isPasswordVisible = false
        privateKey = ""
        passphrase = ""
    }
}

#if DEBUG
#Preview("SSH Login") {
    SSHLoginSheet(
        server: LitterPreviewData.sampleSSHServer,
        autoLoadSavedCredentials: false,
        initialUsername: "builder"
    ) { _ in }
}
#endif
