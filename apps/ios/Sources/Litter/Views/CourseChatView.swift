import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum CourseChatTimelinePolicy {
    static func localMessages(
        _ messages: [CourseChatMessage],
        hasLiveThread: Bool
    ) -> [CourseChatMessage] {
        hasLiveThread ? [] : messages
    }

    static func isAgentWorking(requestPending: Bool, threadHasActiveTurn: Bool) -> Bool {
        requestPending || threadHasActiveTurn
    }
}

struct CourseChatView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Bindable var store: CourseExperienceStore
    @State private var inputText = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsFileImporter = false
    @State private var attachmentError: String?
    @FocusState private var composerFocused: Bool

    private var liveThread: AppThreadSnapshot? {
        guard let key = store.agentThreadKey else { return nil }
        return appModel.threadSnapshot(for: key)
    }

    private var liveConversationItems: [ConversationItem] {
        liveThread?.hydratedConversationItems.map(\.conversationItem) ?? []
    }

    private var localMessages: [CourseChatMessage] {
        CourseChatTimelinePolicy.localMessages(
            store.messages,
            hasLiveThread: liveThread != nil
        )
    }

    private var isAgentWorking: Bool {
        CourseChatTimelinePolicy.isAgentWorking(
            requestPending: store.isAgentRequestPending,
            threadHasActiveTurn: liveThread?.hasActiveTurn == true
        )
    }

    private var liveTimelineDigest: Int {
        var hasher = Hasher()
        for item in liveConversationItems {
            hasher.combine(item.id)
            hasher.combine(item.renderDigest)
        }
        hasher.combine(isAgentWorking)
        return hasher.finalize()
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        CourseChatIntro()

                        ForEach(localMessages) { message in
                            CourseMessageRow(message: message)
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
                                    followLiveAgent(proxy)
                                },
                                onLiveContentLayoutChanged: {
                                    followLiveAgent(proxy)
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

                        if let agentError = store.agentError {
                            Label("\(store.activeAgentID.displayLabel) couldn’t continue. \(agentError)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(12)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                .onChange(of: store.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.3)) {
                        if store.showsBrief {
                            proxy.scrollTo("course-brief", anchor: .bottom)
                        } else if let last = store.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: store.showsBrief) { _, isShown in
                    guard isShown else { return }
                    withAnimation(.easeOut(duration: 0.35)) {
                        proxy.scrollTo("course-brief", anchor: .top)
                    }
                }
                .onChange(of: liveTimelineDigest) { _, _ in
                    guard isAgentWorking else { return }
                    followLiveAgent(proxy)
                }
                .onChange(of: isAgentWorking) { _, working in
                    if working {
                        followLiveAgent(proxy)
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
                onStop: { store.interruptAgent(appModel: appModel) },
                selectedPhoto: $selectedPhoto,
                onChooseFile: { showsFileImporter = true },
                onPasteLink: pasteLink
            )
        }
        .navigationTitle(store.generatedCourseID == nil ? "New Course" : "Course Agent")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let draft = store.courseChatDraft {
                inputText = draft
                store.courseChatDraft = nil
                composerFocused = true
            }
        }
        .task {
            await store.hydrateCourseThread(appModel: appModel, appState: appState)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 7) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    AgentIconView(kind: store.activeAgentID, size: 23)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
                .accessibilityLabel("\(store.activeAgentID.displayLabel) connected")
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
    }

    private func sendCurrentMessage() {
        let text = inputText
        inputText = ""
        composerFocused = false
        store.sendMessage(text, appModel: appModel, appState: appState)
    }

    private func followLiveAgent(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("course-chat-bottom", anchor: .bottom)
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
        if !inputText.isEmpty { inputText += "\n" }
        inputText += pasted
        composerFocused = true
    }
}

private struct CourseChatIntro: View {
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
            Text("Talk naturally. Your course agent can work from files, images, and URLs just like a desktop agent.")
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

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            if message.role == .learner { Spacer(minLength: 40) }

            if message.role == .agent {
                AgentIconView(kind: "codex", size: 27)
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
    let onStop: () -> Void
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
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Photo", systemImage: "photo")
                    }
                    Button(action: onChooseFile) {
                        Label("File", systemImage: "doc")
                    }
                    Button(action: onPasteLink) {
                        Label("Paste Link", systemImage: "link")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .frame(width: 38, height: 38)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("Add a source")

                TextField("Message your course agent", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .focused(isFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 19, style: .continuous))

                Button(action: isAgentWorking ? onStop : onSend) {
                    Image(systemName: isAgentWorking ? "stop.fill" : "arrow.up")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(sendButtonColor, in: Circle())
                }
                .disabled(!isAgentWorking && !canSend)
                .accessibilityLabel(isAgentWorking ? "Stop agent" : "Send message")
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
