import SwiftUI

struct CourseExperienceRootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Bindable var store: CourseExperienceStore
    var onOpenClassicLitter: () -> Void
    var onConnectRemoteAgent: () -> Void

    var body: some View {
        Group {
            if !store.hasCompletedIntro {
                LearnfoldIntroView {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        store.completeIntro()
                    }
                }
                .transition(.opacity)
            } else if store.setupComplete {
                NavigationStack(path: $store.navigationPath) {
                    CourseHomeView(
                        store: store,
                        onOpenClassicLitter: onOpenClassicLitter,
                        onConnectRemoteAgent: onConnectRemoteAgent
                    )
                    .navigationDestination(for: CourseRoute.self) { route in
                        switch route {
                        case .newCourse:
                            CourseChatView(store: store)
                        case .building:
                            CourseBuildingView(store: store)
                        case .course(let courseID):
                            if let course = store.course(withID: courseID) {
                                CourseDetailView(
                                    course: course,
                                    store: store,
                                    onOpenClassicLitter: onOpenClassicLitter
                                )
                            } else {
                                ContentUnavailableView(
                                    "Course unavailable",
                                    systemImage: "book.closed",
                                    description: Text("This course is no longer on this device.")
                                )
                            }
                        case .courseFile(let courseID, let relativePath):
                            if let course = store.course(withID: courseID),
                               let rootURL = store.courseDirectory(for: course) {
                                CourseFileViewerView(
                                    course: course,
                                    relativePath: relativePath,
                                    rootURL: rootURL,
                                    store: store,
                                    onOpenRelativePath: { linkedPath in
                                        store.openCourseFile(courseID: courseID, relativePath: linkedPath)
                                    }
                                )
                            } else {
                                ContentUnavailableView(
                                    "File unavailable",
                                    systemImage: "doc.questionmark",
                                    description: Text("This course’s files are no longer on this device.")
                                )
                            }
                        case .coursePage(let courseID, let pageID):
                            if let course = store.course(withID: courseID) {
                                CoursePageEditorView(
                                    course: course,
                                    pageID: pageID,
                                    store: store
                                )
                            } else {
                                ContentUnavailableView(
                                    "Page unavailable",
                                    systemImage: "doc.questionmark",
                                    description: Text("This course is no longer on this device.")
                                )
                            }
                        }
                    }
                }
                .tint(.blue)
            } else {
                CourseAgentSetupView(
                    store: store,
                    onConnectRemoteAgent: onConnectRemoteAgent
                )
            }
        }
        .preferredColorScheme(.light)
        .task {
            store.installDocumentToolRouterIfNeeded(appModel: appModel)
            await store.recoverReadyCourses()
            if store.setupComplete, store.connectionState != .connected {
                await store.connectLocalAgent(appModel: appModel, agentID: store.selectedAgentID ?? "codex")
            }
        }
    }
}

private struct CourseAgentSetupView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var store: CourseExperienceStore
    let onConnectRemoteAgent: () -> Void
    @State private var selectedAgent: String
    @State private var selectedModelID = ""
    @State private var showsOpenAICompatibleSetup = false
    @State private var hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL

    init(
        store: CourseExperienceStore,
        onConnectRemoteAgent: @escaping () -> Void
    ) {
        self.store = store
        self.onConnectRemoteAgent = onConnectRemoteAgent
        _selectedAgent = State(initialValue: store.preferredSetupAgentID)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [.blue, .indigo],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 78, height: 78)
                            Image(systemName: "sparkles.rectangle.stack.fill")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.white)
                        }

                        Text("Choose your course agent")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .tracking(-1.1)

                        Text("Choose Apple On‑Device, Apple Private Cloud Compute, or Codex. Each course keeps the provider family it starts with.")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 12) {
                        ForEach(store.agentOptions.filter(\.available)) { choice in
                            CourseAgentChoiceRow(
                                id: choice.id,
                                title: choice.title,
                                subtitle: choice.subtitle,
                                available: choice.available,
                                selected: selectedAgent == choice.id,
                                onSelect: { selectedAgent = choice.id }
                            )
                        }
                    }

                    Button(action: onConnectRemoteAgent) {
                        HStack(spacing: 14) {
                            Image(systemName: "server.rack")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.indigo)
                                .frame(width: 42, height: 42)
                                .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Connect Hermes on a server")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("Pair with Learnfold Link, then continue in a private remote chat.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(16)
                        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.black.opacity(0.07))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("course-agent-add-server")

                    if selectedAgent == "codex" {
                        Button {
                            showsOpenAICompatibleSetup = true
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.blue)
                                    .frame(width: 34, height: 34)
                                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hasCustomEndpoint ? "Custom provider connected" : "Use an OpenAI-compatible provider")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(hasCustomEndpoint ? "Change endpoint, key, or model" : "Add a base URL, API key, and model ID")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(16)
                            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.black.opacity(0.07))
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(spacing: 12) {
                        Button {
                            Task {
                                await store.connectLocalAgent(
                                    appModel: appModel,
                                    agentID: selectedAgent,
                                    modelID: selectedModelID.isEmpty ? nil : selectedModelID
                                )
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if store.connectionState == .connecting {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "iphone.and.arrow.forward")
                                }
                                Text(store.connectionState == .connecting ? "Connecting…" : "Connect \(selectedAgent.displayLabel)")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .foregroundStyle(.white)
                            .background(.blue, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("course-agent-connect")
                        .disabled(
                            store.connectionState == .connecting
                                || store.agentOptions.first(where: { $0.id == selectedAgent })?.available != true
                        )

                        Label("Private Cloud Compute is preferred when Apple makes it available. On older iPhones, Codex remains available.", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if case .failed(let message) = store.connectionState {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 38)
                .padding(.bottom, 28)
            }
        }
        .task {
            selectedModelID = store.selectedModelID ?? ""
            if let saved = store.selectedAgentID,
               store.agentOptions.first(where: { $0.id == saved })?.available == true {
                selectedAgent = saved
            } else {
                selectedAgent = store.preferredSetupAgentID
            }
            if !CourseAgentProvider.isApple(selectedAgent) {
                await store.prepareLocalAgentCatalog(appModel: appModel)
            }
        }
        .onChange(of: selectedAgent) { _, agentID in
            guard !CourseAgentProvider.isApple(agentID) else { return }
            Task {
                await store.prepareLocalAgentCatalog(appModel: appModel)
            }
        }
        .onChange(of: store.selectedAgentID) { _, agentID in
            guard let agentID,
                  store.agentOptions.first(where: { $0.id == agentID })?.available == true else {
                return
            }
            selectedAgent = agentID
            selectedModelID = store.selectedModelID ?? ""
        }
        .sheet(isPresented: $showsOpenAICompatibleSetup) {
            OpenAICompatibleProviderSheet(initialModelID: selectedModelID) { modelID in
                selectedModelID = modelID
                hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
            }
            .environment(appModel)
        }
    }
}

private struct CourseHomeView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var store: CourseExperienceStore
    var onOpenClassicLitter: () -> Void
    var onConnectRemoteAgent: () -> Void
    @State private var showsCourseSettings = false

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .center) {
                        Text("My Courses")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .tracking(-1)

                        Spacer()

                        Button {
                            showsCourseSettings = true
                        } label: {
                            ZStack {
                                Circle().fill(.thinMaterial)
                                AgentIconView(kind: store.selectedAgentID ?? "codex", size: 28)
                            }
                            .frame(width: 46, height: 46)
                            .overlay(Circle().stroke(Color.black.opacity(0.07)))
                        }
                        .accessibilityLabel("Course agent menu")
                    }
                    .zIndex(10)

                    if let featured = store.courses.first {
                        CourseFeaturedCard(course: featured) {
                            store.navigationPath.append(.course(featured.id))
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("All Courses")
                                    .font(.title3.weight(.bold))
                                Spacer()
                                Text("\(store.courses.count)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }

                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(Array(store.courses.dropFirst())) { course in
                                    CourseGridCard(course: course) {
                                        store.navigationPath.append(.course(course.id))
                                    }
                                }
                            }
                        }
                    } else {
                        CourseLibraryEmptyState()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 112)
            }

            Button {
                store.beginNewCourse()
            } label: {
                Label("New Course", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 21)
                    .padding(.vertical, 15)
                    .foregroundStyle(.white)
                    .background(.blue, in: Capsule())
                    .shadow(color: .blue.opacity(0.25), radius: 18, y: 8)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 18)
            .padding(.bottom, 22)
            .accessibilityIdentifier("new-course-button")
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showsCourseSettings) {
            CourseAgentSettingsView(
                store: store,
                onConnectRemoteAgent: onConnectRemoteAgent
            )
                .environment(appModel)
        }
    }
}

private struct CourseLibraryEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 72, height: 72)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(spacing: 6) {
                Text("Your library is ready")
                    .font(.title3.weight(.bold))
                Text("Create a course with your agent. Only courses actually generated on this device will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 44)
        .background(.background, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.black.opacity(0.05))
        }
    }
}

private struct CourseAgentSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CourseExperienceStore
    let onConnectRemoteAgent: () -> Void
    @State private var selectedAgent: String
    @State private var selectedModel: String
    @State private var selectedEffort: String
    @State private var showsOpenAICompatibleSetup = false
    @State private var hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
    @State private var cloudSyncAvailability: CourseCloudSyncAvailability = .missingEntitlement

    init(
        store: CourseExperienceStore,
        onConnectRemoteAgent: @escaping () -> Void
    ) {
        self.store = store
        self.onConnectRemoteAgent = onConnectRemoteAgent
        _selectedAgent = State(initialValue: store.selectedAgentID ?? "codex")
        _selectedModel = State(initialValue: store.selectedModelID ?? "")
        _selectedEffort = State(initialValue: store.selectedReasoningEffortID ?? "")
    }

    private var models: [ModelInfo] {
        store.models(for: selectedAgent)
    }

    private var selectedModelInfo: ModelInfo? {
        models.first(where: { $0.id == selectedModel || $0.model == selectedModel })
    }

    private var connectedHermesServer: AppServerSnapshot? {
        let connectedServers = appModel.snapshot?.servers.filter { server in
            !server.isLocal
                && server.isConnected
                && server.agentRuntimes.contains {
                    $0.kind == "hermes" && $0.available
                }
        } ?? []
        if let selectedServerID = store.selectedAgentServerID,
           let selected = connectedServers.first(where: { $0.serverId == selectedServerID }) {
            return selected
        }
        return connectedServers.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        Text(cloudSyncAvailability.label)
                            .foregroundStyle(cloudSyncAvailability.tint)
                    } label: {
                        Label("Course iCloud Sync", systemImage: "icloud")
                    }
                    if cloudSyncAvailability.canRetry {
                        Button("Retry iCloud Connection") {
                            Task {
                                await CourseCloudSyncEngine.shared.startIfAvailable()
                                cloudSyncAvailability = await CourseCloudSyncEngine.shared.availability
                            }
                        }
                    }
                } footer: {
                    Text(cloudSyncAvailability.explanation)
                }

                Section {
                    ForEach(store.agentOptions.filter(\.available)) { option in
                        Button {
                            let optionModels = store.models(for: option.id)
                            selectedAgent = option.id
                            let defaultModel = optionModels.first(where: \.isDefault) ?? optionModels.first
                            selectedModel = defaultModel?.id ?? ""
                            selectedEffort = defaultModel?.defaultReasoningEffort.wireValue ?? ""
                        } label: {
                            HStack(spacing: 14) {
                                AgentIconView(kind: option.id, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).foregroundStyle(.primary)
                                    Text(option.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedAgent == option.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Course agent")
                } footer: {
                    Text("Only agents currently available through this device or the selected server are shown.")
                }

                if !CourseAgentProvider.isApple(selectedAgent) {
                    Section("Model") {
                    if store.isLoadingAgentCatalog {
                        HStack {
                            ProgressView()
                            Text("Loading models…").foregroundStyle(.secondary)
                        }
                    } else if models.isEmpty {
                        Text("This agent will choose its default model.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(models, id: \.id) { model in
                            Button {
                                selectedModel = model.id
                                selectedEffort = model.defaultReasoningEffort.wireValue
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(modelPickerDisplayName(model)).foregroundStyle(.primary)
                                            if model.isDefault {
                                                Text("DEFAULT")
                                                    .font(.caption2.weight(.bold))
                                                    .foregroundStyle(.blue)
                                            }
                                        }
                                        if !model.description.isEmpty {
                                            Text(model.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    if modelMatchesSelection(model, selectedModel, runtime: selectedAgent) {
                                        Image(systemName: "checkmark").foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
                }

                if let selectedModelInfo, !selectedModelInfo.supportedReasoningEfforts.isEmpty {
                    Section("Reasoning") {
                        Picker("Effort", selection: $selectedEffort) {
                            ForEach(selectedModelInfo.supportedReasoningEfforts) { option in
                                Text(option.reasoningEffort.wireValue.capitalized)
                                    .tag(option.reasoningEffort.wireValue)
                            }
                        }
                    }
                }

                if selectedAgent == "codex" {
                    Section {
                        Button {
                            showsOpenAICompatibleSetup = true
                        } label: {
                            HStack {
                                Label(
                                    hasCustomEndpoint ? "Manage custom provider" : "Add custom provider",
                                    systemImage: "point.3.connected.trianglepath.dotted"
                                )
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        if hasCustomEndpoint {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("OpenAI-compatible endpoint active")
                                    .font(.subheadline.weight(.semibold))
                                if !selectedModel.isEmpty {
                                    Text("New courses will request model “\(selectedModel)”.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Custom provider")
                    } footer: {
                        Text("Uses Learnfold’s existing local Codex runtime. Endpoint changes are app-wide and affect existing Codex conversations too.")
                    }
                }

                Section {
                    Text("This changes the default for new courses. Existing Codex and Apple courses cannot cross provider families. An Apple course can switch between On‑Device and Private Cloud Compute from its chat.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if let connectedHermesServer {
                        LabeledContent {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Hermes")
                                Text(connectedHermesServer.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Button {
                            dismiss()
                            Task { @MainActor in
                                await Task.yield()
                                onConnectRemoteAgent()
                            }
                        } label: {
                            Label("Connect Hermes", systemImage: "server.rack")
                        }
                        .accessibilityIdentifier("course-settings-add-server")
                    }
                } header: {
                    Text("Remote agent")
                } footer: {
                    if connectedHermesServer == nil {
                        Text("Pairs through Learnfold Link. Hermes can build and edit native course pages through Learnfold’s approval-gated tool bridge.")
                    }
                }

                if let error = store.agentError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .task {
                cloudSyncAvailability = await CourseCloudSyncEngine.shared.availability
            }
            .navigationTitle("Course Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.connectionState == .connecting ? "Saving…" : "Save") {
                        Task {
                            await store.connectLocalAgent(
                                appModel: appModel,
                                agentID: selectedAgent,
                                modelID: selectedModel.isEmpty ? nil : selectedModel,
                                reasoningEffortID: selectedEffort.isEmpty ? nil : selectedEffort
                            )
                            if store.connectionState == .connected { dismiss() }
                        }
                    }
                    .disabled(store.connectionState == .connecting)
                }
            }
            .task {
                await store.prepareLocalAgentCatalog(appModel: appModel)
                let availableOptions = store.agentOptions.filter(\.available)
                if !availableOptions.contains(where: { $0.id == selectedAgent }),
                   let fallback = availableOptions.first {
                    selectedAgent = fallback.id
                    selectedModel = store.defaultModelID(for: fallback.id) ?? ""
                    selectedEffort = ""
                }
                if selectedModel.isEmpty {
                    selectedModel = store.defaultModelID(for: selectedAgent) ?? ""
                }
                hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
            }
            .sheet(isPresented: $showsOpenAICompatibleSetup) {
                OpenAICompatibleProviderSheet(initialModelID: selectedModel) { modelID in
                    selectedModel = modelID
                    selectedEffort = ""
                    hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
                }
                .environment(appModel)
            }
        }
    }
}

private extension CourseCloudSyncAvailability {
    var label: String {
        switch self {
        case .available: "Synced"
        case .missingEntitlement: "On This Device"
        case .noAccount: "Sign In Required"
        case .failed: "Needs Attention"
        }
    }

    var explanation: String {
        switch self {
        case .available:
            "Generated courses and later edits are synced through your private iCloud database."
        case .missingEntitlement:
            "Courses remain on this device because the Learnfold iCloud container is not enabled in this build."
        case .noAccount:
            "Sign in to iCloud in Settings to sync generated courses."
        case .failed(let message):
            "Course sync paused without changing local data. \(message)"
        }
    }

    var tint: Color {
        switch self {
        case .available: .green
        case .missingEntitlement: .secondary
        case .noAccount, .failed: .orange
        }
    }

    var canRetry: Bool {
        switch self {
        case .noAccount, .failed: true
        case .available, .missingEntitlement: false
        }
    }
}

private struct OpenAICompatibleProviderSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let onSaved: (String) -> Void

    @State private var baseURL: String
    @State private var apiKey = ""
    @State private var modelID: String
    @State private var hasStoredKey = OpenAIApiKeyStore.shared.hasStoredKey
    @State private var hasStoredBaseURL = OpenAIApiKeyStore.shared.hasStoredBaseURL
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(initialModelID: String, onSaved: @escaping (String) -> Void) {
        self.onSaved = onSaved
        _baseURL = State(initialValue: (try? OpenAIApiKeyStore.shared.loadBaseURL()) ?? "")
        _modelID = State(initialValue: initialModelID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://provider.example/v1", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    SecureField(hasStoredKey ? "API key saved — enter to replace" : "API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Model ID, for example gpt-oss-120b", text: $modelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Connection")
                } footer: {
                    Text("The API key and base URL are stored securely on this iPhone. The model ID is sent exactly as entered.")
                }

                Section {
                    Label("Runs through the on-device Codex agent", systemImage: "iphone.gen3")
                    Label("Course files remain in the app’s local workspace", systemImage: "folder.badge.gearshape")
                    Label("Prompts and selected source content go to your endpoint", systemImage: "arrow.up.forward.app")
                } header: {
                    Text("How it works")
                } footer: {
                    Text("Compatibility requires the OpenAI Responses API, streaming, and tool calling. A chat-completions-only endpoint may not work with Codex. Changing this endpoint restarts local Codex and affects existing Codex conversations too.")
                }

                if hasStoredBaseURL {
                    Section {
                        Button("Use Default OpenAI Endpoint", role: .destructive) {
                            Task { await clearCustomEndpoint() }
                        }
                        .disabled(isSaving)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Custom Provider")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
        }
    }

    private var canSave: Bool {
        OpenAICompatibleProviderConfiguration.normalizedBaseURL(baseURL) != nil
            && OpenAICompatibleProviderConfiguration.normalizedModelID(modelID) != nil
            && (hasStoredKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @MainActor
    private func save() async {
        guard let normalizedBaseURL = OpenAICompatibleProviderConfiguration.normalizedBaseURL(baseURL),
              let normalizedModelID = OpenAICompatibleProviderConfiguration.normalizedModelID(modelID) else {
            errorMessage = "Enter a valid http or https base URL and a model ID."
            return
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasStoredKey || !trimmedKey.isEmpty else {
            errorMessage = "Enter an API key. For a local endpoint that ignores authentication, use the placeholder key it recommends."
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            errorMessage = nil
            if !trimmedKey.isEmpty {
                try OpenAIApiKeyStore.shared.save(trimmedKey)
            }
            try OpenAIApiKeyStore.shared.saveBaseURL(normalizedBaseURL)
            try await appModel.restartLocalServer()
            hasStoredKey = OpenAIApiKeyStore.shared.hasStoredKey
            hasStoredBaseURL = OpenAIApiKeyStore.shared.hasStoredBaseURL
            onSaved(normalizedModelID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func clearCustomEndpoint() async {
        isSaving = true
        defer { isSaving = false }
        do {
            errorMessage = nil
            try OpenAIApiKeyStore.shared.clearBaseURL()
            try await appModel.restartLocalServer()
            hasStoredBaseURL = false
            onSaved("")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CourseFeaturedCard: View {
    let course: LearningCourse
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                CourseArtwork(course: course)
                    .frame(height: 236)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.88)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("CONTINUE LEARNING")
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.72))
                    Text(course.title)
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(spacing: 10) {
                        ProgressView(value: course.progress)
                            .tint(.white)
                            .frame(maxWidth: 130)
                        Text("\(Int(course.progress * 100))%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Image(systemName: "play.fill")
                            .font(.headline)
                            .foregroundStyle(.blue)
                            .frame(width: 46, height: 46)
                            .background(.white, in: Circle())
                    }
                }
                .padding(19)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 236)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
    }
}

private struct CourseGridCard: View {
    let course: LearningCourse
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                CourseArtwork(course: course)
                    .frame(maxWidth: .infinity)
                    .frame(height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(course.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(course.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.stack")
                        Text("\(course.lessonCount)")
                        Text("·")
                        Text(course.duration)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.black.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }
}

private struct CourseArtwork: View {
    let title: String
    let accentHex: String

    init(course: LearningCourse) {
        title = course.title
        accentHex = course.accentHex
    }

    init(title: String, accentHex: String) {
        self.title = title
        self.accentHex = accentHex
    }

    var body: some View {
        let accent = Color(hex: accentHex)
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.72), accent, .black.opacity(0.86)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 190, height: 190)
                .blur(radius: 2)
                .offset(x: 95, y: -60)

            Circle()
                .stroke(.white.opacity(0.2), lineWidth: 1)
                .frame(width: 118, height: 118)
                .offset(x: 82, y: -45)

            Image(systemName: "book.pages.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        }
        .accessibilityHidden(true)
    }
}

private enum CourseDetailSection: String, CaseIterable, Identifiable {
    case learn = "Learn"
    case structure = "Structure"

    var id: String { rawValue }
}

private struct CourseDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    let course: LearningCourse
    @Bindable var store: CourseExperienceStore
    let onOpenClassicLitter: () -> Void

    @State private var selectedSection: CourseDetailSection
    @State private var workspaceSnapshot: CourseWorkspaceSnapshot?
    @State private var documentOutline: CourseDocumentOutline?
    @State private var structureError: String?
    @State private var expandedLearningNodeIDs: Set<String> = []

    init(
        course: LearningCourse,
        store: CourseExperienceStore,
        onOpenClassicLitter: @escaping () -> Void
    ) {
        self.course = course
        self.store = store
        self.onOpenClassicLitter = onOpenClassicLitter
        _selectedSection = State(initialValue: course.workspaceID == nil ? .learn : .structure)
    }

    private var chapters: [CourseChapter] {
        if let loaded = store.courseBrief(for: course) {
            return loaded.chapters
        }
        return [
            CourseChapter(id: "visual-map", title: "A visual map of the idea", objective: "See the complete idea first.", deliverables: []),
            CourseChapter(id: "core-intuition", title: "Build the core intuition", objective: "Understand the central concept.", deliverables: []),
            CourseChapter(id: "worked-example", title: "Follow one worked example", objective: "Make the idea concrete.", deliverables: []),
            CourseChapter(id: "practice", title: "Try it yourself", objective: "Practice independently.", deliverables: []),
            CourseChapter(id: "review", title: "Review and extend", objective: "Consolidate and continue.", deliverables: []),
        ]
    }

    private var learningNodes: [CourseLearningNode] {
        let resolved: [CourseLearningNode]
        if let documentOutline, !documentOutline.learningPages.isEmpty {
            resolved = documentOutline.learningPages
        } else if let loaded = store.courseBrief(for: course) {
            resolved = CourseLearningPathResolver.resolve(brief: loaded, snapshot: workspaceSnapshot)
        } else {
            resolved = chapters.map {
                CourseLearningNode(
                    id: $0.id,
                    title: $0.title,
                    kind: .folder,
                    status: .pendingGeneration
                )
            }
        }
        let activeNodeID = store.backgroundGeneratingCourseID == course.id
            ? store.backgroundGeneratingNodeID
            : nil
        return CourseLearningPathResolver.overlayGeneratingStatus(
            in: resolved,
            targetNodeID: activeNodeID
        )
    }

    private var isBackgroundGenerationActive: Bool {
        store.backgroundGeneratingCourseID == course.id && store.backgroundGeneratingNodeID != nil
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    courseHeader

                    if course.workspaceID != nil {
                        Picker("Course view", selection: $selectedSection) {
                            ForEach(CourseDetailSection.allCases) { section in
                                Text(section.rawValue).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(4)
                        .background(.thinMaterial, in: Capsule())
                        .accessibilityIdentifier("course-detail-section-picker")
                    }

                    switch selectedSection {
                    case .learn:
                        learnSection
                    case .structure:
                        structureSection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, course.workspaceID == nil ? 32 : 104)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if course.workspaceID != nil {
                bottomActionBar
            }
        }
        .navigationTitle("Course")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshWorkspace)
        .task(id: store.courseWorkspaceRefreshVersion) {
            await refreshDocumentOutline()
        }
        .onChange(of: store.courseWorkspaceRefreshVersion) { _, _ in
            refreshWorkspace()
        }
        .task(id: store.backgroundGeneratingNodeID) {
            guard isBackgroundGenerationActive else { return }
            while !Task.isCancelled, isBackgroundGenerationActive {
                refreshWorkspace()
                try? await Task.sleep(for: .milliseconds(500))
            }
            refreshWorkspace()
        }
    }

    private var courseHeader: some View {
        HStack(spacing: 16) {
            CourseArtwork(course: course)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(course.title)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .lineLimit(2)
                Text(course.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Label(course.status == .ready ? "Ready to learn" : "In progress", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(CourseCompletionLabelStyle())
            }

            Spacer(minLength: 0)
        }
    }

    private var learnSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Learning path")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.headline)
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(.blue.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Learn at your own pace")
                        .font(.subheadline.weight(.semibold))
                    Text("Open any ready module. Generate a pending section when you want to continue, and your agent will adapt it to your progress.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            CourseLearningTreeView(
                nodes: learningNodes,
                expandedNodeIDs: $expandedLearningNodeIDs,
                generationDisabled: isBackgroundGenerationActive,
                runtimeID: course.agentRuntimeKind ?? CourseAgentProvider.codex,
                onOpenMarkdown: { pageID in
                    store.openCoursePage(courseID: course.id, pageID: pageID)
                },
                onGenerate: { node in
                    store.generateCourseNodeInBackground(
                        for: course,
                        node: node,
                        appModel: appModel,
                        appState: appState
                    )
                }
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            if store.backgroundGenerationErrorCourseID == course.id,
               let error = store.backgroundGenerationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .onAppear(perform: expandInitialLearningNode)
    }

    @ViewBuilder
    private var structureSection: some View {
        if let documentOutline {
            VStack(alignment: .leading, spacing: 24) {
                CoursePageStructureBrowser(
                    nodes: documentOutline.allPages,
                    onOpenPage: { pageID in
                        store.openCoursePage(courseID: course.id, pageID: pageID)
                    }
                )

                if let workspaceSnapshot,
                   workspaceSnapshot.nodes.contains(where: { $0.relativePath == "sources" || $0.relativePath == "assets" }) {
                    Divider()
                    Text("Source files and assets")
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                    CourseStructureBrowser(
                        snapshot: workspaceSnapshot,
                        recommendedFilePath: nil,
                        onOpenFile: { node in
                            store.openCourseFile(courseID: course.id, relativePath: node.relativePath)
                        }
                    )
                }
            }
        } else if let structureError {
            ContentUnavailableView(
                "Course structure unavailable",
                systemImage: "folder.badge.questionmark",
                description: Text(structureError)
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 50)
        } else {
            ProgressView("Reading course structure…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 64)
        }
    }

    private var bottomActionBar: some View {
        Button {
            store.resumeCourseAgent(for: course)
        } label: {
            Label("Talk to Course Agent", systemImage: "bubble.left.and.bubble.right.fill")
                .font(.headline)
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("talk-to-course-agent-button")
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private func refreshWorkspace() {
        guard let rootURL = store.courseDirectory(for: course) else {
            workspaceSnapshot = nil
            structureError = CourseWorkspaceError.unavailable.localizedDescription
            return
        }
        do {
            workspaceSnapshot = try CourseWorkspaceSnapshot.load(from: rootURL)
            structureError = nil
        } catch {
            workspaceSnapshot = nil
            structureError = error.localizedDescription
        }
    }

    private func refreshDocumentOutline() async {
        do {
            let repository = try await store.documentRepository(for: course)
            documentOutline = try await repository.outline()
            structureError = nil
        } catch {
            documentOutline = nil
            structureError = error.localizedDescription
        }
    }

    private func expandInitialLearningNode() {
        guard expandedLearningNodeIDs.isEmpty,
              let firstReadyFolder = learningNodes.first(where: {
                  $0.kind == .folder && !$0.children.isEmpty && $0.status != .pendingGeneration
              }) else { return }
        expandedLearningNodeIDs.insert(firstReadyFolder.id)
    }
}

private struct CourseCompletionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(.blue)
            configuration.title
        }
    }
}

private struct CourseAgentChoiceRow: View {
    let id: String
    let title: String
    let subtitle: String
    let available: Bool
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button {
            guard available else { return }
            onSelect()
        } label: {
            HStack(spacing: 16) {
                AgentIconView(kind: id, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(available ? Color.primary : Color.secondary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                trailingStatus
            }
            .padding(16)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(selected ? Color.blue : Color.black.opacity(0.06), lineWidth: selected ? 2 : 1)
            }
            .opacity(available ? 1 : 0.62)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityIdentifier("course-agent-option-\(id)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if available {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(selected ? Color.blue : Color.secondary.opacity(0.5))
        } else {
            Text("Later")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
        }
    }
}

private struct CourseLearningTreeView: View {
    let nodes: [CourseLearningNode]
    @Binding var expandedNodeIDs: Set<String>
    let generationDisabled: Bool
    let runtimeID: String
    let onOpenMarkdown: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                CourseLearningTreeNodeView(
                    node: node,
                    depth: 0,
                    expandedNodeIDs: $expandedNodeIDs,
                    generationDisabled: generationDisabled,
                    runtimeID: runtimeID,
                    onOpenMarkdown: onOpenMarkdown,
                    onGenerate: onGenerate
                )
                if index < nodes.count - 1 {
                    Divider().padding(.leading, 46)
                }
            }
        }
    }
}

private struct CourseLearningTreeNodeView: View {
    let node: CourseLearningNode
    let depth: Int
    @Binding var expandedNodeIDs: Set<String>
    let generationDisabled: Bool
    let runtimeID: String
    let onOpenMarkdown: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void

    private var isExpanded: Bool {
        expandedNodeIDs.contains(node.id)
    }

    private var canExpand: Bool {
        node.kind == .folder && !node.children.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: primaryAction) {
                    HStack(spacing: 10) {
                        if node.kind == .folder {
                            Image(systemName: canExpand ? (isExpanded ? "chevron.down" : "chevron.right") : "folder.fill")
                                .font(canExpand ? .caption.weight(.bold) : .body)
                                .foregroundStyle(node.status == .pendingGeneration ? Color.secondary : Color.blue)
                                .frame(width: 24)

                            if canExpand {
                                Image(systemName: "folder.fill")
                                    .font(.body)
                                    .foregroundStyle(.blue)
                            }
                        } else {
                            Image(systemName: "doc.text.fill")
                                .font(.body)
                                .foregroundStyle(node.status == .generated ? Color.blue : Color.secondary)
                                .frame(width: 24)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.title)
                                .font(.system(size: depth == 0 ? 16 : 15, weight: depth == 0 ? .semibold : .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            if node.kind == .folder, !node.children.isEmpty {
                                Text("\(node.children.count) \(node.children.count == 1 ? "item" : "items")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(node.kind == .markdown && node.status != .generated)

                trailingControl
            }
            .padding(.leading, CGFloat(depth) * 22 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, depth == 0 ? 13 : 11)
            .opacity(node.status == .pendingGeneration ? 0.82 : 1)

            if canExpand, isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                        CourseLearningTreeNodeView(
                            node: child,
                            depth: depth + 1,
                            expandedNodeIDs: $expandedNodeIDs,
                            generationDisabled: generationDisabled,
                            runtimeID: runtimeID,
                            onOpenMarkdown: onOpenMarkdown,
                            onGenerate: onGenerate
                        )
                        if index < node.children.count - 1 {
                            Divider().padding(.leading, CGFloat(depth + 2) * 22 + 34)
                        }
                    }
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.blue.opacity(0.16))
                        .frame(width: 2)
                        .padding(.leading, CGFloat(depth + 1) * 22 + 18)
                }
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch node.status {
        case .pendingGeneration:
            if CourseExperienceStore.allowsDirectGeneration(of: node, runtimeID: runtimeID) {
                Button("Generate") { onGenerate(node) }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(.blue, in: Capsule())
                    .buttonStyle(.plain)
                    .accessibilityLabel("Generate \(node.title)")
                    .disabled(generationDisabled)
                    .opacity(generationDisabled ? 0.45 : 1)
            } else {
                Text("Pending")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        case .generating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Generating")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        case .partiallyGenerated:
            Text("In progress")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.1), in: Capsule())
        case .generated:
            if node.kind == .markdown {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Open \(node.title)")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Generated")
            }
        }
    }

    private func primaryAction() {
        if node.kind == .folder, canExpand {
            withAnimation(.snappy(duration: 0.24)) {
                if isExpanded {
                    expandedNodeIDs.remove(node.id)
                } else {
                    expandedNodeIDs.insert(node.id)
                }
            }
        } else if node.kind == .markdown,
                  node.status == .generated,
                  let pageID = node.pageID {
            onOpenMarkdown(pageID)
        }
    }
}

private struct CourseBuildingView: View {
    @Bindable var store: CourseExperienceStore

    private let milestones = [
        ("Saving your learner profile", "person.text.rectangle"),
        ("Creating your course map", "point.3.connected.trianglepath.dotted"),
        ("Preparing every chapter folder", "folder.fill.badge.plus"),
        ("Writing Chapter 1", "text.book.closed.fill"),
        ("Ready to start learning", "sparkles"),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.025, green: 0.07, blue: 0.17), Color(red: 0.05, green: 0.16, blue: 0.35)],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("Building Your Course")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("\(store.activeAgentID.displayLabel) is mapping the full course and writing only your first chapter.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    CourseArtwork(title: store.brief.title, accentHex: "1F6FEB")
                        .frame(height: 255)
                        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 32, style: .continuous)
                                .stroke(.white.opacity(0.15))
                        }
                        .shadow(color: .blue.opacity(0.28), radius: 30, y: 16)

                    VStack(spacing: 0) {
                        ForEach(Array(milestones.enumerated()), id: \.offset) { index, milestone in
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(index < store.generationStep ? Color.green : Color.white.opacity(0.1))
                                    if index < store.generationStep {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    } else if index == store.generationStep {
                                        ProgressView().tint(.white)
                                    } else {
                                        Image(systemName: milestone.1)
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.45))
                                    }
                                }
                                .frame(width: 34, height: 34)

                                Text(milestone.0)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(index <= store.generationStep ? .white : .white.opacity(0.45))
                                Spacer()
                            }
                            .padding(.vertical, 13)

                            if index < milestones.count - 1 {
                                Rectangle()
                                    .fill(.white.opacity(0.12))
                                    .frame(height: 1)
                                    .padding(.leading, 48)
                            }
                        }
                    }
                    .padding(.horizontal, 17)
                    .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("YOUR COURSE PATH")
                            .font(.caption2.bold())
                            .tracking(1.3)
                            .foregroundStyle(.white.opacity(0.5))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(Array(store.brief.chapters.enumerated()), id: \.element.id) { index, chapter in
                                    Text("\(index + 1)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                        .frame(width: 44, height: 36)
                                        .background(.white.opacity(index < max(store.generationStep, 1) ? 0.18 : 0.07), in: Capsule())
                                        .accessibilityLabel("Chapter \(index + 1), \(chapter.title)")
                                }
                            }
                        }
                    }

                    if store.generationStep >= milestones.count {
                        Button("Open My Course", action: store.openGeneratedCourse)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .foregroundStyle(.blue)
                            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        Text("You can close this screen while generation continues with the app open.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.48))
                    }

                    if let generationError = store.generationError {
                        VStack(spacing: 12) {
                            Label(generationError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                                .multilineTextAlignment(.center)
                            Button("Return to Course Agent", action: store.returnToCourseAgent)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.white.opacity(0.14), in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 64)
                .padding(.bottom, 30)
            }
        }
        .overlay(alignment: .topLeading) {
            Button(action: store.leaveBuildingScreen) {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close course generation")
            .padding(.leading, 16)
            .padding(.top, 8)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeInOut(duration: 0.35), value: store.generationStep)
    }
}
