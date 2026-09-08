#if DEBUG
import SwiftUI
import NativeBlockEditorCore
import NativeEditorMCP

/// Isolated local fixture exercising the production reader and generation dispatcher.
struct CourseReadingUITestHarness: View {
    static let argument = "--ui-test-course-reading"
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LEARNFOLD_UI_TESTING"] == "1"
            && ProcessInfo.processInfo.arguments.contains(argument)
    }

    @State private var store: CourseExperienceStore?
    @State private var error: String?
    @State private var appState = AppState()

    var body: some View {
        Group {
            if let store {
                ReadingFixtureNavigation(store: store)
                    .environment(appState)
            } else if let error {
                Text(error).accessibilityIdentifier("reading-fixture-error")
            } else {
                ProgressView("Preparing reading fixture")
            }
        }
        .preferredColorScheme(.light)
        .task { if store == nil { await prepare() } }
    }

    @MainActor
    private func prepare() async {
        do {
            let rawToken = ProcessInfo.processInfo.environment["LEARNFOLD_READING_TEST_TOKEN"] ?? ""
            guard let token = UUID(uuidString: rawToken)?.uuidString else { return }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingFixture-\(token)")
            let workspaceID = "reading-\(token.lowercased())"
            let courseRoot = root.appendingPathComponent(workspaceID)
            let database = courseRoot.appendingPathComponent(".course/course-library.sqlite")
            let course = LearningCourse(
                id: workspaceID, title: "Zero-Knowledge SNARKs", subtitle: "From Intuition to Circuits",
                accentHex: "007AFF", progress: 0, lessonCount: 3, duration: "", status: .ready,
                workspaceID: workspaceID, agentRuntimeKind: CourseAgentProvider.hosted,
                hostedSessionID: UUID()
            )
            let defaults = UserDefaults(suiteName: "ReadingFixture.\(token)")!
            if !FileManager.default.fileExists(atPath: database.path) {
                var workspace = PageWorkspace(rootTitle: course.title)
                func document(_ text: String, role: String, status: String = "generated") throws -> BlockDocument {
                    var document = try AppFlowyMarkdownCodec().decode(text)
                    document.root.data["course_role"] = .string(role)
                    document.root.data["course_generation_status"] = .string(status)
                    return document
                }
                let chapter = try workspace.createPage(title: "The Zero-Knowledge Mindset", parentID: workspace.rootPageID,
                    document: document("", role: "chapter"), id: "chapter")
                let section = try workspace.createPage(title: "Proofs without secrets", parentID: chapter.id,
                    document: document("", role: "subchapter"), id: "section")
                let article = (1...18).map { index in
                    "## Idea \(index)\n\nA proof can show that a statement is true while keeping its underlying secret private. Follow the verifier's questions and the prover's responses to see what information each step reveals."
                }.joined(separator: "\n\n")
                _ = try workspace.createPage(title: "What a proof reveals", parentID: section.id,
                    document: document(article, role: "lesson"), id: "article-one")
                _ = try workspace.createPage(title: "A verifier's challenge", parentID: section.id,
                    document: document("## A challenge\n\nTry describing a verification step without sharing the secret.", role: "lesson"), id: "article-two")
                let second = try workspace.createPage(title: "Finite Fields", parentID: workspace.rootPageID,
                    document: document("", role: "chapter"), id: "chapter-two")
                _ = try workspace.createPage(title: "The math playground", parentID: second.id,
                    document: document("", role: "lesson", status: "pending_generation"), id: "article-three")
                try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try await NativeEditorMCPService.open(databaseURL: database, seedWorkspace: workspace)
                var brief = CourseBrief()
                brief.title = course.title
                try JSONEncoder().encode(brief).write(to: courseRoot.appendingPathComponent("course.json"))
                defaults.set(try JSONEncoder().encode([course]), forKey: "snappy.course.savedCourses")
            }
            let runtime = ReadingFixtureRuntime()
            let fixtureStore = CourseExperienceStore(defaults: defaults, hostedRuntime: runtime, coursesRootURL: root)
            fixtureStore.navigationPath = []
            store = fixtureStore
        } catch { self.error = error.localizedDescription }
    }
}

private struct ReadingFixtureNavigation: View {
    @Bindable var store: CourseExperienceStore
    var body: some View {
        NavigationStack(path: $store.navigationPath) {
            if let course = store.courses.first {
                CourseRouteDestinationView(route: .course(course.id), store: store)
                    .navigationDestination(for: CourseRoute.self) { route in
                        CourseRouteDestinationView(route: route, store: store)
                    }
            }
        }
        .safeAreaInset(edge: .top) {
            Text("LOCAL READING FIXTURE · SIMULATED GENERATION")
                .font(.caption2)
                .accessibilityIdentifier("reading-fixture")
        }
    }
}

@MainActor
private final class ReadingFixtureRuntime: HostedCourseAgentRuntime {
    private var attempts = 0
    func availability() -> HostedCourseAgentAvailability { .init(available: true, reason: "Local fixture") }
    func restoredMessages(sessionID: UUID) async throws -> [HostedCourseAgentStoredMessage] { [] }
    func cancel(sessionID: UUID) {}
    func send(sessionID: UUID, workspaceID: String, courseDirectory: URL, prompt: String,
              onRecoveringChanged: @escaping @MainActor (Bool) -> Void,
              onPartialResponse: @escaping @MainActor (String) -> Void,
              onCoursePlan: @escaping @MainActor (CourseBrief) async throws -> Void) async throws {
        attempts += 1
        try await Task.sleep(for: .seconds(3))
        if attempts == 1 {
            throw NSError(domain: "ReadingFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated connection failure"])
        }
        let repository = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID, databaseURL: courseDirectory.appendingPathComponent(".course/course-library.sqlite"), rootTitle: "Reading fixture"
        )
        let page = try await repository.pageSnapshot(id: "article-three")
        var document = try AppFlowyMarkdownCodec().decode("## Working in a finite field\n\nArithmetic wraps around a fixed set of values. This is the final lesson in this local fixture.")
        document.root.data = page.document.root.data
        document.root.data["course_generation_status"] = .string("generated")
        try await repository.stageUserEdit(pageID: page.id, document: document)
        _ = try await repository.flushPendingUserEdits()
        onPartialResponse("The lesson is ready.")
    }
}
#endif
