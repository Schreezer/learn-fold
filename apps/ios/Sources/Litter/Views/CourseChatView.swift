import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum CourseChatTimelinePolicy {
    private enum Speaker: Hashable {
        case learner
        case agent
    }

    private struct MessageSignature: Hashable {
        let speaker: Speaker
        let text: String
    }

    static func localMessages(
        _ messages: [CourseChatMessage],
        representedBy liveItems: [ConversationItem]
    ) -> [CourseChatMessage] {
        var liveCounts = liveItems.reduce(into: [MessageSignature: Int]()) { counts, item in
            guard let signature = signature(for: item) else { return }
            counts[signature, default: 0] += 1
        }

        return messages.filter { message in
            let signature = MessageSignature(
                speaker: message.role == .learner ? .learner : .agent,
                text: normalized(message.text)
            )
            guard let count = liveCounts[signature], count > 0 else {
                return true
            }
            liveCounts[signature] = count - 1
            return false
        }
    }

    static func projectLiveItems(
        _ items: [ConversationItem],
        hidesSelectionEnvelope: Bool = false
    ) -> [ConversationItem] {
        items.compactMap {
            projectLiveItem($0, hidesSelectionEnvelope: hidesSelectionEnvelope)
        }
    }

    static func isAgentWorking(requestPending: Bool, threadHasActiveTurn: Bool) -> Bool {
        requestPending || threadHasActiveTurn
    }

    private static func signature(for item: ConversationItem) -> MessageSignature? {
        switch item.content {
        case .user(let data):
            return MessageSignature(speaker: .learner, text: normalized(data.text))
        case .assistant(let data):
            return MessageSignature(speaker: .agent, text: normalized(data.text))
        default:
            return nil
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func projectLiveItem(
        _ item: ConversationItem,
        hidesSelectionEnvelope: Bool
    ) -> ConversationItem? {
        switch item.content {
        case .mcpToolCall(let data) where isInternalCourseServer(data.server):
            return data.status == .failed
                ? learnerFacingFailure(for: item, tool: data.tool)
                : nil
        case .dynamicToolCall(let data) where isInternalCourseDynamicTool(data):
            return data.status == .failed
                ? learnerFacingFailure(for: item, tool: data.tool)
                : nil
        case .assistant(let data) where isRemoteCourseToolEnvelope(data.text):
            return nil
        case .user(let data):
            if isRemoteCourseToolResultEnvelope(data.text) {
                return nil
            }
            let projectedText: String?
            if let learnerMessage = remoteLearnerMessage(from: data.text) {
                projectedText = learnerMessage
            } else if hidesSelectionEnvelope {
                projectedText = selectionQuestion(from: data.text)
            } else {
                projectedText = nil
            }
            guard let projectedText else { return item }
            return ConversationItem(
                id: item.id,
                content: .user(
                    ConversationUserMessageData(text: projectedText, images: data.images)
                ),
                sourceTurnId: item.sourceTurnId,
                sourceTurnIndex: item.sourceTurnIndex,
                timestamp: item.timestamp,
                isFromUserTurnBoundary: item.isFromUserTurnBoundary
            )
        default:
            return item
        }
    }

    static func selectionQuestion(from prompt: String) -> String? {
        guard prompt.contains("<selected_course_passage"),
              let marker = prompt.range(of: "\nMy question: ") else { return nil }
        let question = prompt[marker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? nil : question
    }

    static func remoteLearnerMessage(from prompt: String) -> String? {
        guard prompt.contains("Learnfold remote native-tool protocol:"),
              let marker = prompt.range(of: "\n\nLearner message:\n") else {
            return nil
        }
        let message = prompt[marker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    private static func isRemoteCourseToolEnvelope(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{")
            && trimmed.contains(#""learnfold_tool_call""#)
    }

    private static func isRemoteCourseToolResultEnvelope(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{")
            && trimmed.contains(#""learnfold_tool_result""#)
    }

    private static func isInternalCourseServer(_ server: String) -> Bool {
        server == CourseAgentTools.mcpServerName ||
            server == CourseAgentTools.mcpDirectNamespace
    }

    private static func isInternalCourseDynamicTool(
        _ data: ConversationDynamicToolCallData
    ) -> Bool {
        if data.tool == CourseAgentTools.presentPlan ||
            CourseAgentTools.isEditorTool(data.tool) {
            return true
        }

        if let namespace = data.namespace,
           namespace == CourseAgentTools.mcpServerName ||
               namespace == CourseAgentTools.mcpDirectNamespace {
            return true
        }

        return data.tool.hasPrefix("\(CourseAgentTools.mcpDirectNamespace)__")
    }

    private static func learnerFacingFailure(
        for item: ConversationItem,
        tool: String
    ) -> ConversationItem {
        let message = tool == CourseAgentTools.presentPlan
            ? "The course plan couldn’t be prepared. Please try again."
            : "The course couldn’t be updated. Please try again."

        return ConversationItem(
            id: item.id,
            content: .error(
                ConversationSystemErrorData(
                    title: "Course action failed",
                    message: message,
                    details: nil
                )
            ),
            sourceTurnId: item.sourceTurnId,
            sourceTurnIndex: item.sourceTurnIndex,
            timestamp: item.timestamp,
            isFromUserTurnBoundary: item.isFromUserTurnBoundary
        )
    }
}

enum CourseChatScrollPolicy {
    static let nearBottomDistance: CGFloat = 12

    static func shouldFollow(
        autoFollowEnabled: Bool,
        userIsDragging: Bool
    ) -> Bool {
        autoFollowEnabled && !userIsDragging
    }

    static func updatedAutoFollow(
        currentValue: Bool,
        distanceFromBottom: CGFloat,
        userIsDragging: Bool,
        isAgentWorking: Bool
    ) -> Bool {
        if distanceFromBottom <= nearBottomDistance {
            return true
        }
        if userIsDragging && isAgentWorking {
            return false
        }
        return currentValue
    }
}

enum CourseChatAuthPolicy {
    static func needsSignIn(
        isCodex: Bool,
        requiresOpenAIAuth: Bool,
        hasAccount: Bool,
        explicitlyRequired: Bool
    ) -> Bool {
        isCodex && (explicitlyRequired || (requiresOpenAIAuth && !hasAccount))
    }

    static func isReady(
        isCodex: Bool,
        transportConnected: Bool,
        requiresOpenAIAuth: Bool,
        hasAccount: Bool
    ) -> Bool {
        guard transportConnected else { return false }
        return !isCodex || !requiresOpenAIAuth || hasAccount
    }
}

struct CourseChatView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CourseExperienceStore
    let selectionContext: CourseTextReference?
    let selectionDiscussionID: UUID?
    let showsDismissButton: Bool
    @State private var inputText = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsFileImporter = false
    @State private var attachmentError: String?
    @State private var hasSentSelectionContext = false
    @State private var isNearBottom = true
    @State private var autoFollowStreaming = true
    @State private var userIsDraggingScroll = false
    @State private var followScrollScheduled = false
    @State private var isResolvingDiscussion = false
    @State private var resolveError: String?
    @FocusState private var composerFocused: Bool

    init(
        store: CourseExperienceStore,
        selectionContext: CourseTextReference? = nil,
        selectionDiscussionID: UUID? = nil,
        showsDismissButton: Bool = false
    ) {
        self.store = store
        self.selectionContext = selectionContext
        self.selectionDiscussionID = selectionDiscussionID
        self.showsDismissButton = showsDismissButton
    }

    private var activeThreadKey: ThreadKey? {
        if let selectionDiscussionID {
            return store.selectionDiscussionThreadKey(id: selectionDiscussionID)
        }
        return store.agentThreadKey
    }

    private var liveThread: AppThreadSnapshot? {
        guard let key = activeThreadKey else { return nil }
        return appModel.threadSnapshot(for: key)
    }

    private var liveConversationItems: [ConversationItem] {
        CourseChatTimelinePolicy.projectLiveItems(
            liveThread?.hydratedConversationItems.map(\.conversationItem) ?? [],
            hidesSelectionEnvelope: selectionDiscussionID != nil
        )
    }

    private var localMessages: [CourseChatMessage] {
        CourseChatTimelinePolicy.localMessages(
            store.localMessages(for: selectionDiscussionID),
            representedBy: liveConversationItems
        )
    }

    private var localStreamingTextLength: Int {
        localMessages.last(where: { $0.role == .agent })?.text.utf16.count ?? 0
    }

    private var isPreparingSelectionDiscussion: Bool {
        selectionDiscussionID.map {
            store.preparingSelectionDiscussionIDs.contains($0)
        } ?? false
    }

    private var displayedAgentError: String? {
        if let selectionDiscussionID {
            return store.selectionDiscussionErrors[selectionDiscussionID]
        }
        return store.agentError
    }

    private var isAgentWorking: Bool {
        CourseChatTimelinePolicy.isAgentWorking(
            requestPending: store.isAgentRequestPending,
            threadHasActiveTurn: liveThread?.hasActiveTurn == true
        )
    }

    private var courseServer: AppServerSnapshot? {
        if let serverID = activeThreadKey?.serverId {
            return appModel.snapshot?.serverSnapshot(for: serverID)
        }
        return appModel.snapshot?.servers.first(where: \.isLocal)
    }

    private var codexNeedsSignIn: Bool {
        CourseChatAuthPolicy.needsSignIn(
            isCodex: store.activeAgentID == .codex,
            requiresOpenAIAuth: courseServer?.requiresOpenaiAuth == true,
            hasAccount: courseServer?.account != nil,
            explicitlyRequired: store.agentNeedsAuthentication
        )
    }

    private var isAgentReady: Bool {
        if CourseAgentProvider.isApple(store.activeAgentID) {
            return store.connectionState == .connected
        }
        return CourseChatAuthPolicy.isReady(
            isCodex: store.activeAgentID == .codex,
            transportConnected: courseServer?.isConnected == true,
            requiresOpenAIAuth: courseServer?.requiresOpenaiAuth == true,
            hasAccount: courseServer?.account != nil
        )
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if let selectionContext {
                            CourseSelectionContextCard(reference: selectionContext)
                        } else {
                            CourseChatIntro(
                                supportsBinarySources: !CourseAgentProvider.isApple(
                                    store.activeAgentID
                                )
                            )
                        }

                        if isPreparingSelectionDiscussion {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Starting a focused discussion…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Starting a focused discussion")
                        }

                        ForEach(localMessages) { message in
                            CourseMessageRow(
                                message: message,
                                agentID: store.activeAgentID
                            )
                                .id(message.id)
                        }

                        if let liveThread {
                            ConversationTurnTimeline(
                                items: liveConversationItems,
                                isLive: liveThread.hasActiveTurn,
                                serverId: liveThread.key.serverId,
                                originThreadId: liveThread.key.threadId,
                                agentDirectoryVersion: appModel.snapshot?.agentDirectoryVersion ?? 0,
                                messageActionsDisabled: true,
                                onStreamingSnapshotRendered: {
                                    requestFollowScrollAfterLayout(proxy)
                                },
                                onLiveContentLayoutChanged: {
                                    requestFollowScrollAfterLayout(proxy)
                                },
                                resolveTargetLabel: { target in
                                    appModel.snapshot?.resolvedAgentTargetLabel(
                                        for: target,
                                        serverId: liveThread.key.serverId
                                    )
                                },
                                onWidgetPrompt: { prompt in
                                    inputText = prompt
                                    composerFocused = true
                                },
                                onEditUserItem: { _ in },
                                onForkFromUserItem: { _ in }
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("course-live-timeline")
                        }

                        if isAgentWorking {
                            HStack(alignment: .center, spacing: 8) {
                                AgentIconView(kind: store.activeAgentID, size: 27)
                                TypingIndicator()
                                Spacer()
                            }
                            .id("course-agent-working")
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(store.activeAgentID.displayLabel) is thinking")
                        }

                        if store.showsBrief {
                            CourseBriefCard(
                                brief: store.brief,
                                agentName: store.activeAgentID.displayLabel,
                                isAgentWorking: isAgentWorking,
                                buildAction: {
                                    store.approveCoursePlan(appModel: appModel, appState: appState)
                                }
                            )
                                .id("course-brief")
                        }

                        if let agentError = displayedAgentError {
                            CourseAgentErrorCard(
                                agentName: store.activeAgentID.displayLabel,
                                message: agentError,
                                needsAuthentication: codexNeedsSignIn,
                                isConnecting: store.connectionState == .connecting,
                                onReconnect: reconnectAgent,
                                onDismiss: dismissDisplayedError
                            )
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("course-chat-bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 22)
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
                } action: { _, distance in
                    updateDistanceFromBottom(distance)
                }
                .onScrollPhaseChange { _, newPhase in
                    switch newPhase {
                    case .tracking, .interacting:
                        userIsDraggingScroll = true
                        if isAgentWorking {
                            autoFollowStreaming = false
                        }
                    case .decelerating:
                        userIsDraggingScroll = true
                    default:
                        userIsDraggingScroll = false
                        if isNearBottom {
                            autoFollowStreaming = true
                        }
                    }
                }
                .onChange(of: localMessages.count) { _, _ in
                    // Once the Rust-backed thread exists, these local messages
                    // are hidden. Its timeline callbacks own follow scrolling.
                    guard liveConversationItems.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        if store.showsBrief {
                            proxy.scrollTo("course-brief", anchor: .bottom)
                        } else if let last = localMessages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: localStreamingTextLength) { _, _ in
                    guard CourseAgentProvider.isApple(store.activeAgentID),
                          isAgentWorking else { return }
                    requestFollowScrollAfterLayout(proxy)
                }
                .onChange(of: store.showsBrief) { _, isShown in
                    guard isShown,
                          CourseChatScrollPolicy.shouldFollow(
                              autoFollowEnabled: autoFollowStreaming,
                              userIsDragging: userIsDraggingScroll
                          ) else { return }
                    withAnimation(.easeOut(duration: 0.35)) {
                        proxy.scrollTo("course-brief", anchor: .top)
                    }
                }
                .onChange(of: isAgentWorking) { wasWorking, working in
                    if wasWorking || working {
                        requestFollowScrollAfterLayout(proxy)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CourseChatComposer(
                inputText: $inputText,
                sources: store.sources,
                isFocused: $composerFocused,
                onRemoveSource: store.removeSource,
                onSend: sendCurrentMessage,
                isAgentWorking: isAgentWorking,
                isPreparing: isPreparingSelectionDiscussion,
                onStop: {
                    store.interruptAgent(
                        appModel: appModel,
                        selectionDiscussionID: selectionDiscussionID
                    )
                },
                supportsBinarySources: !CourseAgentProvider.isApple(store.activeAgentID),
                selectedPhoto: $selectedPhoto,
                onChooseFile: { showsFileImporter = true },
                onPasteLink: pasteLink
            )
        }
        .litterFontFamily(.system)
        // Course surfaces use native Dynamic Type. The classic conversation
        // zoom is a separate preference and otherwise makes this screen's
        // messages larger than its surrounding controls and guidance.
        .environment(\.textScale, 1.0)
        .navigationTitle(selectionContext == nil ? (store.generatedCourseID == nil ? "New Course" : "Course Agent") : "Ask Course Agent")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let draft = store.takeDraft(for: selectionDiscussionID) {
                inputText = draft
                composerFocused = true
            }
            hasSentSelectionContext =
                selectionDiscussionID.map {
                    store.selectionDiscussionHasSubmittedQuestion(id: $0)
                } ?? false
        }
        .onDisappear {
            store.saveDraft(inputText, for: selectionDiscussionID)
        }
        .onChange(of: store.lastAcceptedSelectionContextID) { _, acceptedID in
            if acceptedID == selectionContext?.id {
                hasSentSelectionContext = true
            }
        }
        .task {
            await store.refreshAgentReadiness(appModel: appModel)
            if let selectionDiscussionID {
                await store.prepareSelectionDiscussionThread(
                    id: selectionDiscussionID,
                    appModel: appModel,
                    appState: appState
                )
                hasSentSelectionContext =
                    store.selectionDiscussionHasSubmittedQuestion(
                        id: selectionDiscussionID
                    )
            } else {
                await store.hydrateCourseThread(appModel: appModel, appState: appState)
            }
        }
        .toolbar {
            if showsDismissButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 6) {
                    if selectionDiscussionID != nil {
                        Button("Resolve") {
                            resolveDiscussion()
                        }
                        .font(.subheadline.weight(.semibold))
                        .disabled(
                            isResolvingDiscussion ||
                                isPreparingSelectionDiscussion ||
                                isAgentWorking
                        )
                        .accessibilityIdentifier("course-chat-resolve")
                    }
                    if CourseAgentProvider.isApple(store.activeAgentID) {
                        Menu {
                            Button {
                                store.switchCurrentAppleProvider(
                                    to: CourseAgentProvider.applePrivateCloud
                                )
                            } label: {
                                Label(
                                    "Private Cloud Compute",
                                    systemImage: store.activeAgentID == CourseAgentProvider.applePrivateCloud
                                        ? "checkmark.circle.fill"
                                        : "cloud"
                                )
                            }
                            .disabled(
                                !store.canSwitchCurrentThread(
                                    to: CourseAgentProvider.applePrivateCloud
                                )
                            )

                            Button {
                                store.switchCurrentAppleProvider(
                                    to: CourseAgentProvider.appleOnDevice
                                )
                            } label: {
                                Label(
                                    "On‑Device",
                                    systemImage: store.activeAgentID == CourseAgentProvider.appleOnDevice
                                        ? "checkmark.circle.fill"
                                        : "iphone"
                                )
                            }
                            .disabled(
                                !store.canSwitchCurrentThread(
                                    to: CourseAgentProvider.appleOnDevice
                                )
                            )
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .disabled(isAgentWorking)
                        .accessibilityLabel("Switch Apple model")
                        .accessibilityIdentifier("course-chat-apple-provider-switch")
                    }
                    agentStatusControl
                }
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    do {
                        store.addSource(try store.copySourceIntoCourse(url: url))
                    } catch {
                        attachmentError = error.localizedDescription
                    }
                }
            case .failure(let error):
                attachmentError = error.localizedDescription
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                defer { selectedPhoto = nil }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    attachmentError = "That image could not be loaded."
                    return
                }
                store.addSource(
                    CourseSource(
                        name: "Reference image",
                        detail: "PHOTO",
                        kind: .image,
                        image: image
                    )
                )
            }
        }
        .alert("Couldn’t Add Source", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK", role: .cancel) { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "Unknown error")
        }
        .alert("Couldn’t Resolve Discussion", isPresented: Binding(
            get: { resolveError != nil },
            set: { if !$0 { resolveError = nil } }
        )) {
            Button("OK", role: .cancel) { resolveError = nil }
        } message: {
            Text(resolveError ?? "The discussion is still open.")
        }
    }

    private func sendCurrentMessage() {
        guard !isPreparingSelectionDiscussion else { return }
        let text = inputText
        inputText = ""
        composerFocused = false
        autoFollowStreaming = true
        isNearBottom = true
        let reference = hasSentSelectionContext ? nil : selectionContext
        store.sendMessage(
            text,
            reference: reference,
            selectionDiscussionID: selectionDiscussionID,
            appModel: appModel,
            appState: appState
        )
    }

    private func resolveDiscussion() {
        guard let selectionDiscussionID else { return }
        isResolvingDiscussion = true
        Task {
            defer { isResolvingDiscussion = false }
            do {
                try await store.resolveSelectionDiscussion(
                    id: selectionDiscussionID,
                    appModel: appModel
                )
                dismiss()
            } catch {
                resolveError = "The agent discussion could not be closed, so the passage remains highlighted. \(error.localizedDescription)"
            }
        }
    }

    private func dismissDisplayedError() {
        if let selectionDiscussionID {
            store.selectionDiscussionErrors[selectionDiscussionID] = nil
        } else {
            store.agentError = nil
        }
    }

    @ViewBuilder
    private var agentStatusControl: some View {
        if codexNeedsSignIn {
            Button(action: reconnectAgent) {
                agentStatusLabel(color: .orange)
            }
            .accessibilityLabel("Sign in to \(store.activeAgentID.displayLabel)")
        } else {
            agentStatusLabel(color: isAgentReady ? .green : .gray)
                .accessibilityLabel(
                    isAgentReady
                        ? "\(store.activeAgentID.displayLabel) connected"
                        : "\(store.activeAgentID.displayLabel) unavailable"
                )
        }
    }

    private func agentStatusLabel(color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            AgentIconView(kind: store.activeAgentID, size: 23)
        }
        .frame(minWidth: 44, minHeight: 44)
        .padding(.horizontal, 4)
        .background(.thinMaterial, in: Capsule())
    }

    private func reconnectAgent() {
        Task {
            await store.connectLocalAgent(
                appModel: appModel,
                agentID: store.activeAgentID,
                modelID: store.selectedModelID,
                reasoningEffortID: store.selectedReasoningEffortID
            )
        }
    }

    private func requestFollowScrollAfterLayout(_ proxy: ScrollViewProxy) {
        guard !followScrollScheduled else { return }
        followScrollScheduled = true
        DispatchQueue.main.async {
            followScrollScheduled = false
            guard CourseChatScrollPolicy.shouldFollow(
                autoFollowEnabled: autoFollowStreaming,
                userIsDragging: userIsDraggingScroll
            ) else { return }
            proxy.scrollTo("course-chat-bottom", anchor: .bottom)
        }
    }

    private func updateDistanceFromBottom(_ distance: CGFloat) {
        let clampedDistance = max(0, distance)
        let nextIsNearBottom =
            clampedDistance <= CourseChatScrollPolicy.nearBottomDistance
        if nextIsNearBottom != isNearBottom {
            isNearBottom = nextIsNearBottom
        }

        let nextAutoFollow = CourseChatScrollPolicy.updatedAutoFollow(
            currentValue: autoFollowStreaming,
            distanceFromBottom: clampedDistance,
            userIsDragging: userIsDraggingScroll,
            isAgentWorking: isAgentWorking
        )
        if nextAutoFollow != autoFollowStreaming {
            autoFollowStreaming = nextAutoFollow
        }
    }

    private func pasteLink() {
        guard let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: pasted),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            attachmentError = "Copy a web link first, then choose Paste Link."
            return
        }
        store.addSource(
            CourseSource(
                name: pasted,
                detail: url.host?.uppercased() ?? "LINK",
                kind: .link
            )
        )
    }
}

private struct CourseAgentErrorCard: View {
    let agentName: String
    let message: String
    let needsAuthentication: Bool
    let isConnecting: Bool
    let onReconnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(agentName) couldn’t continue", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if needsAuthentication {
                    Button(action: onReconnect) {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting)
                }

                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct CourseSelectionContextCard: View {
    let reference: CourseTextReference

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Selected from \(reference.pageTitle)", systemImage: "text.quote")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)

            Text(reference.selectedText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)

            if reference.wasTruncated {
                Text("The first \(CourseTextReference.maximumLength.formatted()) characters will be sent as context.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.blue.opacity(0.14))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected passage from \(reference.pageTitle). \(reference.selectedText)")
    }
}

private struct CourseChatIntro: View {
    let supportsBinarySources: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(.blue.opacity(0.1))
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 58, height: 58)

            Text("Build something worth learning")
                .font(.title3.weight(.bold))
            Text(
                supportsBinarySources
                    ? "Talk naturally. Your course agent can work from files, images, and URLs just like a desktop agent."
                    : "Talk naturally. Your Apple course agent can answer questions, use web links, and build native course pages after you approve its plan."
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

private struct CourseMessageRow: View {
    let message: CourseChatMessage
    let agentID: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            if message.role == .learner { Spacer(minLength: 40) }

            if message.role == .agent {
                AgentIconView(kind: agentID, size: 27)
                    .padding(.bottom, 5)
            }

            VStack(alignment: message.role == .learner ? .trailing : .leading, spacing: 8) {
                if !message.sources.isEmpty {
                    VStack(spacing: 7) {
                        ForEach(message.sources) { source in
                            CourseSourceTile(source: source, compact: false)
                        }
                    }
                }

                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(message.role == .learner ? .white : .primary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                message.role == .learner ? AnyShapeStyle(Color.blue) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                if message.role == .agent {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.black.opacity(0.05))
                }
            }

            if message.role == .agent { Spacer(minLength: 34) }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CourseSourceTile: View {
    let source: CourseSource
    var compact: Bool

    private var symbol: String {
        switch source.kind {
        case .document: "doc.fill"
        case .image: "photo.fill"
        case .link: "link"
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            if let image = source.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: compact ? 30 : 38, height: compact ? 30 : 38)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: compact ? 30 : 38, height: compact ? 30 : 38)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(source.detail)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 7 : 9)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .foregroundStyle(.primary)
    }
}

private struct CourseChatComposer: View {
    @Binding var inputText: String
    let sources: [CourseSource]
    var isFocused: FocusState<Bool>.Binding
    let onRemoveSource: (CourseSource) -> Void
    let onSend: () -> Void
    let isAgentWorking: Bool
    let isPreparing: Bool
    let onStop: () -> Void
    let supportsBinarySources: Bool
    @Binding var selectedPhoto: PhotosPickerItem?
    let onChooseFile: () -> Void
    let onPasteLink: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if !sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sources) { source in
                            HStack(spacing: 5) {
                                CourseSourceTile(source: source, compact: true)
                                    .frame(width: 164)
                                Button {
                                    onRemoveSource(source)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(4)
                            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            HStack(alignment: .bottom, spacing: 9) {
                Menu {
                    if supportsBinarySources {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Photo", systemImage: "photo")
                        }
                        Button(action: onChooseFile) {
                            Label("File", systemImage: "doc")
                        }
                    }
                    Button(action: onPasteLink) {
                        Label("Paste Link", systemImage: "link")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("Add a source")
                .accessibilityIdentifier("course-chat-add-source")
                .disabled(isPreparing)

                TextField("Message your course agent", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .focused(isFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .accessibilityLabel("Message your course agent")
                    .accessibilityIdentifier("course-chat-composer")
                    .disabled(isPreparing)

                Button(action: isAgentWorking ? onStop : onSend) {
                    Group {
                        if isPreparing {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: isAgentWorking ? "stop.fill" : "arrow.up")
                                .font(.headline.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(sendButtonColor, in: Circle())
                }
                .disabled(isPreparing || (!isAgentWorking && !canSend))
                .accessibilityLabel(
                    isPreparing
                        ? "Starting discussion"
                        : (isAgentWorking ? "Stop agent" : "Send message")
                )
                .accessibilityIdentifier(isAgentWorking ? "course-chat-stop" : "course-chat-send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !sources.isEmpty
    }

    private var sendButtonColor: Color {
        if isPreparing { return .gray.opacity(0.5) }
        if isAgentWorking { return .primary }
        return canSend ? .blue : .gray.opacity(0.35)
    }
}

private struct CourseBriefCard: View {
    let brief: CourseBrief
    let agentName: String
    let isAgentWorking: Bool
    let buildAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(.blue.gradient)
                    Image(systemName: "sparkles")
                        .foregroundStyle(.white)
                        .font(.headline)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Your Course Brief")
                        .font(.title3.bold())
                    Text(brief.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text("v\(brief.revision)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.blue.opacity(0.1), in: Capsule())
            }

            Text(brief.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                CourseBriefFact(icon: "target", title: "Outcome", detail: brief.outcome)
                Divider().padding(.leading, 40)
                CourseBriefFact(icon: "figure.walk", title: "Starting point", detail: brief.startingPoint)
                Divider().padding(.leading, 40)
                CourseBriefFact(icon: "scope", title: "Focus gap", detail: brief.focusGap)
                Divider().padding(.leading, 40)
                CourseBriefFact(icon: "clock", title: "Estimated time", detail: brief.estimatedDuration)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("COURSE PATH")
                    .font(.caption2.bold())
                    .tracking(1.2)
                    .foregroundStyle(.secondary)

                ForEach(Array(brief.chapters.enumerated()), id: \.element.id) { index, chapter in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                            .frame(width: 30, height: 30)
                            .background(.blue.opacity(0.1), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chapter.title)
                                .font(.subheadline.weight(.semibold))
                            Text(chapter.objective)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                }
            }

            Button(action: buildAction) {
                Label(
                    isAgentWorking ? "Finishing Plan…" : "Create Course & Chapter 1",
                    systemImage: isAgentWorking ? "ellipsis" : "wand.and.stars"
                )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .foregroundStyle(.white)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isAgentWorking)
            .accessibilityIdentifier("build-course-button")

            Text("This creates the full course map and Chapter 1. Later chapters adapt as you learn. Want a change? Message \(agentName) first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.blue.opacity(0.14)))
        .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    }
}

private struct CourseBriefFact: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(.blue.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.bold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }
}
