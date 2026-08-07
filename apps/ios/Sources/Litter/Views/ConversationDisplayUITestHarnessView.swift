import SwiftUI

#if DEBUG
struct CourseChatContinuityUITestHarnessView: View {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-course-chat-continuity")
    }

    private static let firstLearner = CourseChatMessage(
        role: .learner,
        text: "UITEST_COURSE_FIRST_QUESTION"
    )
    private static let firstAgent = CourseChatMessage(
        role: .agent,
        text: "UITEST_COURSE_FIRST_ANSWER"
    )
    private static let latestLearner = CourseChatMessage(
        role: .learner,
        text: "UITEST_COURSE_LATEST_QUESTION"
    )
    private static let partialLiveItems = [
        ConversationItem(
            id: "ui-test-course-partial-live-user",
            content: .user(
                ConversationUserMessageData(
                    text: "UITEST_COURSE_LATEST_QUESTION",
                    images: []
                )
            )
        )
    ]

    private var mergedItems: [ConversationItem] {
        CourseChatTimelinePolicy.mergedConversationItems(
            localMessages: [Self.firstLearner, Self.firstAgent, Self.latestLearner],
            liveItems: Self.partialLiveItems
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Course Chat Continuity Test")
                        .font(.headline)
                        .accessibilityIdentifier("courseChatContinuityHarness.title")

                    ConversationTurnTimeline(
                        items: mergedItems,
                        isLive: true,
                        serverId: "ui-test-hermes",
                        originThreadId: "ui-test-course-thread",
                        agentDirectoryVersion: 0,
                        messageActionsDisabled: true,
                        onStreamingSnapshotRendered: nil,
                        onLiveContentLayoutChanged: nil,
                        resolveTargetLabel: { _ in nil },
                        onWidgetPrompt: { _ in },
                        onEditUserItem: { _ in },
                        onForkFromUserItem: { _ in }
                    )
                    .accessibilityIdentifier("courseChatContinuityHarness.timeline")
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Course Chat")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            (UIApplication.shared.delegate as? AppDelegate)?.signalContentReady()
        }
    }
}

struct ConversationDisplayUITestHarnessView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @AppStorage(ConversationDisplayPreferenceKey.reasoning) private var reasoningDisplayMode = ConversationDetailDisplayMode.collapsed.rawValue
    @AppStorage(ConversationDisplayPreferenceKey.commands) private var commandDisplayMode = ConversationDetailDisplayMode.collapsed.rawValue
    @AppStorage(ConversationDisplayPreferenceKey.tools) private var toolDisplayMode = ConversationDetailDisplayMode.collapsed.rawValue
    @State private var showSettings = false

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-conversation-display")
    }

    static var opensSettingsOnLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-open-settings")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Conversation Display Test")
                        .litterFont(.title3, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                        .accessibilityIdentifier("conversationDisplayHarness.title")

                    ConversationTurnTimeline(
                        items: Self.seedItems,
                        isLive: false,
                        serverId: "ui-test-server",
                        originThreadId: nil,
                        agentDirectoryVersion: 0,
                        messageActionsDisabled: true,
                        onStreamingSnapshotRendered: nil,
                        onLiveContentLayoutChanged: nil,
                        resolveTargetLabel: { _ in nil },
                        onWidgetPrompt: { _ in },
                        onEditUserItem: { _ in },
                        onForkFromUserItem: { _ in }
                    )
                    .accessibilityIdentifier("conversationDisplayHarness.timeline")
                }
                .padding(16)
            }
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Display Harness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("conversationDisplayHarness.settingsButton")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(appModel)
                .environment(appState)
                .environment(themeManager)
        }
        .onAppear {
            applyLaunchDisplayModes()
            if Self.opensSettingsOnLaunch {
                DispatchQueue.main.async {
                    showSettings = true
                }
            }
            (UIApplication.shared.delegate as? AppDelegate)?.signalContentReady()
        }
    }

    private func applyLaunchDisplayModes() {
        let environment = ProcessInfo.processInfo.environment
        reasoningDisplayMode = validatedMode(environment["CODEXIOS_UI_TEST_REASONING_MODE"])
        commandDisplayMode = validatedMode(environment["CODEXIOS_UI_TEST_COMMAND_MODE"])
        toolDisplayMode = validatedMode(environment["CODEXIOS_UI_TEST_TOOL_MODE"])
    }

    private func validatedMode(_ rawValue: String?) -> String {
        guard let rawValue,
              ConversationDetailDisplayMode(rawValue: rawValue) != nil else {
            return ConversationDetailDisplayMode.collapsed.rawValue
        }
        return rawValue
    }

    private static let seedItems: [ConversationItem] = [
        ConversationItem(
            id: "ui-test-user",
            content: .user(ConversationUserMessageData(
                text: "UITEST_USER_MESSAGE",
                images: []
            ))
        ),
        ConversationItem(
            id: "ui-test-assistant",
            content: .assistant(ConversationAssistantMessageData(
                text: "UITEST_ASSISTANT_MESSAGE",
                agentNickname: nil,
                agentRole: nil,
                phase: nil
            ))
        ),
        ConversationItem(
            id: "ui-test-reasoning",
            content: .reasoning(ConversationReasoningData(
                summary: ["UITEST_REASONING_DETAIL"],
                content: []
            ))
        ),
        ConversationItem(
            id: "ui-test-command",
            content: .commandExecution(ConversationCommandExecutionData(
                command: "printf UITEST_COMMAND_HEADER",
                cwd: "/tmp",
                status: .completed,
                output: "UITEST_COMMAND_OUTPUT",
                exitCode: 0,
                durationMs: 25,
                processId: nil,
                actions: []
            ))
        ),
        ConversationItem(
            id: "ui-test-tool",
            content: .mcpToolCall(ConversationMcpToolCallData(
                server: "uiTest",
                tool: "fixtureTool",
                status: .completed,
                durationMs: 30,
                argumentsJSON: "{\"fixture\":\"UITEST_TOOL_ARGUMENT\"}",
                contentSummary: "UITEST_TOOL_DETAIL",
                structuredContentJSON: nil,
                rawOutputJSON: nil,
                errorMessage: nil,
                progressMessages: [],
                computerUse: nil
            ))
        ),
        ConversationItem(
            id: "ui-test-live-command",
            content: .commandExecution(ConversationCommandExecutionData(
                command: "sleep 10 && echo UITEST_LIVE_COMMAND_HEADER",
                cwd: "/tmp",
                status: .inProgress,
                output: "UITEST_LIVE_COMMAND_OUTPUT",
                exitCode: nil,
                durationMs: nil,
                processId: nil,
                actions: []
            ))
        )
    ]
}

/// Deterministic, launch-argument-only product states for App Store artwork.
/// These screens compile only into Debug builds and never alter production data.
struct MarketingScreenshotHarnessView: View {
    private enum Screen: String {
        case library
        case plan
        case lesson
        case chat
    }

    private static var requestedScreen: Screen? {
        guard let rawValue = ProcessInfo.processInfo.environment["LEARNFOLD_MARKETING_SCREEN"] else {
            return nil
        }
        return Screen(rawValue: rawValue)
    }

    static var isEnabled: Bool { requestedScreen != nil }

    var body: some View {
        Group {
            switch Self.requestedScreen ?? .library {
            case .library:
                MarketingCourseLibraryScreen()
            case .plan:
                MarketingCoursePlanScreen()
            case .lesson:
                MarketingLessonScreen()
            case .chat:
                MarketingCourseChatScreen()
            }
        }
        .preferredColorScheme(.light)
        .onAppear {
            (UIApplication.shared.delegate as? AppDelegate)?.signalContentReady()
        }
    }
}

private enum MarketingPalette {
    static let background = Color(red: 0.965, green: 0.968, blue: 0.985)
    static let indigo = Color(red: 0.24, green: 0.20, blue: 0.84)
    static let blue = Color(red: 0.02, green: 0.49, blue: 0.98)
    static let lime = Color(red: 0.77, green: 1.00, blue: 0.05)
}

private struct MarketingCourseLibraryScreen: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MarketingPalette.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("My Courses")
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                            Text("Keep learning where you left off")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "cloud.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(MarketingPalette.blue)
                            .frame(width: 50, height: 50)
                            .background(.white, in: Circle())
                            .overlay(Circle().stroke(Color.black.opacity(0.06)))
                    }

                    ZStack(alignment: .bottomLeading) {
                        LinearGradient(
                            colors: [MarketingPalette.indigo, MarketingPalette.blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        MarketingNetworkDiagram()
                            .opacity(0.72)
                            .padding(.leading, 145)
                            .padding(.bottom, 64)
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.78)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        VStack(alignment: .leading, spacing: 9) {
                            Text("CONTINUE LEARNING")
                                .font(.caption.weight(.bold))
                                .tracking(1.4)
                                .foregroundStyle(MarketingPalette.lime)
                            Text("Neural Networks")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("From intuition to backpropagation")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.82))
                            HStack(spacing: 10) {
                                ProgressView(value: 3, total: 8)
                                    .tint(MarketingPalette.lime)
                                Text("3 of 8")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.82))
                            }
                        }
                        .padding(22)
                    }
                    .frame(height: 310)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .shadow(color: MarketingPalette.indigo.opacity(0.22), radius: 22, y: 12)

                    HStack {
                        Text("All Courses")
                            .font(.title3.weight(.bold))
                        Spacer()
                        Text("3")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 14) {
                        MarketingCourseTile(
                            icon: "atom",
                            title: "Quantum Computing",
                            detail: "2 of 6 lessons",
                            tint: .purple
                        )
                        MarketingCourseTile(
                            icon: "leaf.fill",
                            title: "Systems Thinking",
                            detail: "Ready to begin",
                            tint: .green
                        )
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Your courses stay together", systemImage: "books.vertical.fill")
                            .font(.headline)
                        Text("Lessons, questions, sources, and progress live in one focused workspace.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 118)
            }

            Label("New Course", systemImage: "plus")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(MarketingPalette.blue, in: Capsule())
                .shadow(color: MarketingPalette.blue.opacity(0.28), radius: 18, y: 8)
                .padding(.trailing, 20)
                .padding(.bottom, 22)
        }
        .accessibilityIdentifier("marketing.library")
    }
}

private struct MarketingCourseTile: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 15))
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.black.opacity(0.05)))
    }
}

private struct MarketingCoursePlanScreen: View {
    private let modules = [
        ("Build the intuition", "Weights, signals, and predictions"),
        ("See learning as error correction", "Loss functions and useful feedback"),
        ("Follow the gradient", "Derivatives without the intimidation"),
        ("Make it work in practice", "Backpropagation, training, and debugging"),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            MarketingPalette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 14) {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(.white, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Review your course")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("Edit the path before Learnfold builds it")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("YOUR GOAL", systemImage: "scope")
                            .font(.caption.weight(.bold))
                            .tracking(1.3)
                            .foregroundStyle(MarketingPalette.lime)
                        Text("Build an intuitive mental model of how neural networks learn.")
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Designed for a curious builder who knows basic algebra but wants the ideas before the notation.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(24)
                    .background(
                        LinearGradient(
                            colors: [MarketingPalette.indigo, MarketingPalette.blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                    )

                    HStack {
                        Text("Course path")
                            .font(.title2.weight(.bold))
                        Spacer()
                        Label("8 lessons", systemImage: "book.pages")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(modules.enumerated()), id: \.offset) { index, module in
                            HStack(alignment: .top, spacing: 16) {
                                Text("\(index + 1)")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(index == 0 ? MarketingPalette.indigo : .secondary)
                                    .frame(width: 42, height: 42)
                                    .background(
                                        index == 0 ? MarketingPalette.lime : Color.black.opacity(0.05),
                                        in: Circle()
                                    )
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(module.0)
                                        .font(.headline)
                                    Text(module.1)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(18)
                            if index < modules.count - 1 {
                                Divider().padding(.leading, 76)
                            }
                        }
                    }
                    .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.black.opacity(0.05)))

                    Label("You stay in control: approve the outline now, then generate lessons progressively.", systemImage: "checkmark.shield.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 126)
            }

            Label("Approve & build", systemImage: "checkmark")
                .font(.headline)
                .foregroundStyle(MarketingPalette.indigo)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(MarketingPalette.lime, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .background(.ultraThinMaterial)
        }
        .accessibilityIdentifier("marketing.plan")
    }
}

private struct MarketingLessonScreen: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            MarketingPalette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Neural Networks")
                                .font(.headline)
                            Text("Lesson 3 of 8")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(MarketingPalette.blue)
                            .frame(width: 44, height: 44)
                            .background(.white, in: Circle())
                    }

                    ProgressView(value: 3, total: 8)
                        .tint(MarketingPalette.blue)

                    Text("LEARNING PATH  /  CORE INTUITION")
                        .font(.caption.weight(.bold))
                        .tracking(1.15)
                        .foregroundStyle(MarketingPalette.blue)
                    Text("Gradient descent:\nlearning by taking better steps")
                        .font(.system(size: 35, weight: .bold, design: .rounded))
                        .tracking(-0.8)
                    Text("Instead of memorizing every answer, a network measures how wrong it was and nudges millions of tiny settings in a better direction.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineSpacing(5)

                    MarketingNetworkDiagram()
                        .frame(height: 255)
                        .padding(18)
                        .background(
                            LinearGradient(
                                colors: [MarketingPalette.indigo, MarketingPalette.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 12) {
                        Label("THE KEY IDEA", systemImage: "lightbulb.fill")
                            .font(.caption.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(MarketingPalette.indigo)
                        Text("The gradient is a compass, not a destination.")
                            .font(.title2.weight(.bold))
                        Text("It tells each weight which small change would reduce the current error fastest. Training repeats that feedback loop across many examples.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                    }
                    .padding(22)
                    .background(MarketingPalette.lime.opacity(0.72), in: RoundedRectangle(cornerRadius: 24))

                    Text("What gradient descent is doing")
                        .font(.title2.weight(.bold))
                    Text("Picture hiking downhill in fog. You cannot see the whole landscape, but you can feel the local slope. One careful step gives you a slightly better position—and a new slope to measure.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineSpacing(5)
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 118)
            }

            Label("Ask about this lesson", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(MarketingPalette.blue, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .background(.ultraThinMaterial)
        }
        .accessibilityIdentifier("marketing.lesson")
    }
}

private struct MarketingCourseChatScreen: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Course Chat")
                        .font(.headline)
                    Text("Neural Networks · Lesson 3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Private")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(.white, in: Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)

            ScrollView {
                VStack(spacing: 22) {
                    Text("Today · Learning in context")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer(minLength: 56)
                        Text("Why does following the local slope eventually help the whole network?")
                            .font(.body)
                            .foregroundStyle(.white)
                            .padding(16)
                            .background(MarketingPalette.blue, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(MarketingPalette.indigo)
                                .frame(width: 34, height: 34)
                                .background(MarketingPalette.lime, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Your course agent")
                                    .font(.subheadline.weight(.bold))
                                Text("Using Lesson 3 and your course goal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("Each weight influences the final error through a chain of operations. Backpropagation applies the chain rule to trace that influence backward.")
                            .font(.body)
                            .lineSpacing(4)
                        Text("So the local slope for one weight is already informed by the network’s overall mistake—it answers: “If only this weight moved slightly, how would the final error change?”")
                            .font(.body)
                            .lineSpacing(4)

                        HStack(spacing: 8) {
                            Label("Lesson 3", systemImage: "book.pages.fill")
                            Label("Course goal", systemImage: "scope")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MarketingPalette.indigo)
                    }
                    .padding(20)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.black.opacity(0.05)))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Try this mental check")
                            .font(.headline)
                        Text("If a weight’s gradient is positive, should you increase or decrease it to reduce the error?")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MarketingPalette.lime.opacity(0.66), in: RoundedRectangle(cornerRadius: 22))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(MarketingPalette.background)

            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.title3)
                    .foregroundStyle(MarketingPalette.blue)
                Text("Ask about your course")
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(MarketingPalette.blue, in: Circle())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .background(MarketingPalette.background.ignoresSafeArea())
        .accessibilityIdentifier("marketing.chat")
    }
}

private struct MarketingNetworkDiagram: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let nodes = [
                CGPoint(x: width * 0.12, y: height * 0.25),
                CGPoint(x: width * 0.12, y: height * 0.50),
                CGPoint(x: width * 0.12, y: height * 0.75),
                CGPoint(x: width * 0.48, y: height * 0.18),
                CGPoint(x: width * 0.48, y: height * 0.40),
                CGPoint(x: width * 0.48, y: height * 0.62),
                CGPoint(x: width * 0.48, y: height * 0.82),
                CGPoint(x: width * 0.86, y: height * 0.50),
            ]

            Canvas { context, _ in
                for start in nodes[0...2] {
                    for end in nodes[3...6] {
                        var path = Path()
                        path.move(to: start)
                        path.addLine(to: end)
                        context.stroke(path, with: .color(.white.opacity(0.28)), lineWidth: 1.4)
                    }
                }
                for start in nodes[3...6] {
                    var path = Path()
                    path.move(to: start)
                    path.addLine(to: nodes[7])
                    context.stroke(path, with: .color(.white.opacity(0.36)), lineWidth: 1.6)
                }
            }

            ForEach(Array(nodes.enumerated()), id: \.offset) { index, point in
                Circle()
                    .fill(index == nodes.count - 1 ? MarketingPalette.lime : .white)
                    .frame(width: index == nodes.count - 1 ? 28 : 20, height: index == nodes.count - 1 ? 28 : 20)
                    .shadow(color: .white.opacity(0.5), radius: 8)
                    .position(point)
            }
        }
    }
}
#endif
