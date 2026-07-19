import XCTest
@testable import Litter

@MainActor
final class CourseExperienceStoreTests: XCTestCase {
    func testFreshStoreStartsWithEmptyCourseLibraryAndRequiresAgentSetup() throws {
        let defaults = try makeDefaults()
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: ["SNAPPY_RESET_ONBOARDING": "1"]
        )

        XCTAssertFalse(store.setupComplete)
        XCTAssertNil(store.selectedAgentID)
        XCTAssertTrue(store.courses.isEmpty)
        XCTAssertTrue(store.agentOptions.map(\.id).contains("claude"))
        XCTAssertTrue(store.agentOptions.map(\.id).contains("opencode"))
        XCTAssertTrue(store.agentOptions.map(\.id).contains("hermes"))
    }

    func testUITestEnvironmentCanEnterCourseHomeWithoutRuntimeSetup() throws {
        let defaults = try makeDefaults()
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: ["SNAPPY_SKIP_AGENT_SETUP": "1"]
        )

        XCTAssertTrue(store.setupComplete)
        XCTAssertEqual(store.selectedAgentID, "codex")
        XCTAssertEqual(store.connectionState, .connected)
    }

    func testSavedCourseAgentAndModelSelectionRestore() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: "snappy.course.agentSetupComplete")
        defaults.set("opencode", forKey: "snappy.course.selectedAgent")
        defaults.set("qwen3-coder", forKey: "snappy.course.selectedModel")
        defaults.set("high", forKey: "snappy.course.selectedReasoningEffort")

        let store = CourseExperienceStore(defaults: defaults, environment: [:])

        XCTAssertTrue(store.setupComplete)
        XCTAssertEqual(store.selectedAgentID, "opencode")
        XCTAssertEqual(store.selectedModelID, "qwen3-coder")
        XCTAssertEqual(store.selectedReasoningEffortID, "high")
    }

    func testOpenAICompatibleConfigurationNormalizesBaseURLAndModelID() {
        XCTAssertEqual(
            OpenAICompatibleProviderConfiguration.normalizedBaseURL(" https://provider.example/v1/// "),
            "https://provider.example/v1"
        )
        XCTAssertEqual(
            OpenAICompatibleProviderConfiguration.normalizedBaseURL("http://192.168.1.20:11434/v1/"),
            "http://192.168.1.20:11434/v1"
        )
        XCTAssertNil(OpenAICompatibleProviderConfiguration.normalizedBaseURL("provider.example/v1"))
        XCTAssertNil(OpenAICompatibleProviderConfiguration.normalizedBaseURL("ftp://provider.example/v1"))
        XCTAssertEqual(
            OpenAICompatibleProviderConfiguration.normalizedModelID("  qwen3-coder  "),
            "qwen3-coder"
        )
        XCTAssertNil(OpenAICompatibleProviderConfiguration.normalizedModelID("   "))
    }

    func testCustomEndpointPreservesManualModelIDOutsideLitterCatalog() {
        XCTAssertEqual(
            OpenAICompatibleProviderConfiguration.resolvedModelID(
                requestedModelID: "custom-model-v2",
                catalogMatchID: nil,
                fallbackModelID: "gpt-default",
                customEndpointEnabled: true
            ),
            "custom-model-v2"
        )
        XCTAssertEqual(
            OpenAICompatibleProviderConfiguration.resolvedModelID(
                requestedModelID: "custom-model-v2",
                catalogMatchID: nil,
                fallbackModelID: "gpt-default",
                customEndpointEnabled: false
            ),
            "gpt-default"
        )
        XCTAssertEqual(
            OpenAICompatibleProviderConfiguration.resolvedModelID(
                requestedModelID: "model-alias",
                catalogMatchID: "catalog-model-id",
                fallbackModelID: "gpt-default",
                customEndpointEnabled: true
            ),
            "catalog-model-id"
        )
    }

    func testBeginningNewCourseResetsDraftAndCreatesWorkspaceRoute() throws {
        let defaults = try makeDefaults()
        let store = CourseExperienceStore(defaults: defaults, environment: [:])
        store.showsBrief = true
        store.sources = [
            CourseSource(name: "Paper", detail: "PDF", kind: .document)
        ]

        store.beginNewCourse()

        XCTAssertEqual(store.navigationPath, [.newCourse])
        XCTAssertFalse(store.showsBrief)
        XCTAssertTrue(store.sources.isEmpty)
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testCourseBriefDecodesTypedToolArguments() throws {
        let payload = """
        {
          "plan_id": "swift-concurrency",
          "revision": 3,
          "title": "Swift Concurrency",
          "summary": "Learn structured concurrency by building a small app.",
          "outcome": "Use tasks, actors, and cancellation safely.",
          "starting_point": "Comfortable with basic Swift.",
          "focus_gap": "Reasoning about isolation and cancellation.",
          "estimated_duration": "3h 30m",
          "chapters": [{
            "id": "tasks",
            "title": "Tasks",
            "objective": "Understand structured task lifetimes.",
            "deliverables": ["lesson", "exercise"]
          }]
        }
        """

        let brief = try JSONDecoder().decode(CourseBrief.self, from: Data(payload.utf8))

        XCTAssertEqual(brief.planID, "swift-concurrency")
        XCTAssertEqual(brief.revision, 3)
        XCTAssertEqual(brief.estimatedDuration, "3h 30m")
        XCTAssertEqual(brief.chapters.first?.deliverables, ["lesson", "exercise"])
    }

    func testCoursePlanDynamicToolPublishesTypedSchema() throws {
        let spec = try CourseAgentTools.dynamicToolSpec()
        let data = try XCTUnwrap(spec.inputSchemaJson.data(using: .utf8))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let revision = try XCTUnwrap(properties["revision"] as? [String: Any])
        let required = try XCTUnwrap(schema["required"] as? [String])

        XCTAssertEqual(spec.name, "present_course_plan")
        XCTAssertEqual(revision["type"] as? String, "integer")
        XCTAssertTrue(required.contains("plan_id"))
        XCTAssertTrue(required.contains("chapters"))
    }

    func testCourseChatUsesLiveThreadInsteadOfDuplicatingLocalTranscript() {
        let learner = CourseChatMessage(role: .learner, text: "Swift concurrency")
        let completedPreview = CourseChatMessage(role: .agent, text: "Let’s start with tasks.")

        let beforeThread = CourseChatTimelinePolicy.localMessages(
            [learner],
            hasLiveThread: false
        )
        let afterThread = CourseChatTimelinePolicy.localMessages(
            [learner, completedPreview],
            hasLiveThread: true
        )

        XCTAssertEqual(beforeThread.map(\.id), [learner.id])
        XCTAssertTrue(afterThread.isEmpty)
    }

    func testCourseChatWorkingStateIncludesStartupAndLiveTurns() {
        XCTAssertTrue(CourseChatTimelinePolicy.isAgentWorking(
            requestPending: true,
            threadHasActiveTurn: false
        ))
        XCTAssertTrue(CourseChatTimelinePolicy.isAgentWorking(
            requestPending: false,
            threadHasActiveTurn: true
        ))
        XCTAssertFalse(CourseChatTimelinePolicy.isAgentWorking(
            requestPending: false,
            threadHasActiveTurn: false
        ))
    }

    func testCourseAgentRequiresAssessmentAndProgressiveGeneration() {
        let instructions = CourseExperienceStore.courseAgentInstructions

        XCTAssertTrue(instructions.contains("MUST assess the learner"))
        XCTAssertTrue(instructions.contains("at least one diagnostic question"))
        XCTAssertTrue(instructions.contains("actual learning content ONLY for Chapter 1"))
        XCTAssertTrue(instructions.contains("recursive `learning_path`"))
        XCTAssertTrue(instructions.contains("pending_generation"))
        XCTAssertTrue(instructions.contains("status: \"bootstrap_complete\""))
        XCTAssertTrue(instructions.contains("ask for any pending chapter, subchapter, or module by node ID"))
        XCTAssertTrue(instructions.contains("Atomically mark only the requested node `generating`"))
    }

    func testTargetedGenerationPromptRunsAutonomouslyAndScopesTheNode() {
        let node = CourseLearningNode(
            id: "forward-diffusion",
            title: "Forward diffusion",
            kind: .folder,
            status: .pendingGeneration
        )

        let prompt = CourseExperienceStore.targetedGenerationPrompt(for: node)

        XCTAssertTrue(prompt.contains("node ID: forward-diffusion"))
        XCTAssertTrue(prompt.contains("work autonomously without asking for confirmation"))
        XCTAssertTrue(prompt.contains("mark only this node generating"))
        XCTAssertTrue(prompt.contains("Mark only completed Markdown leaves generated"))
        XCTAssertTrue(prompt.contains("generated or partially_generated"))
        XCTAssertTrue(prompt.contains("Do not generate any sibling or later section"))
    }

    func testCourseBriefDecodesHierarchicalLearningPath() throws {
        let payload = """
        {
          "plan_id": "swift",
          "revision": 1,
          "title": "Swift",
          "summary": "Learn Swift.",
          "outcome": "Build an app.",
          "starting_point": "New to Swift.",
          "focus_gap": "Language fundamentals.",
          "estimated_duration": "Adaptive",
          "chapters": [],
          "learning_path": [{
            "id": "chapter-1",
            "title": "Foundations",
            "kind": "folder",
            "status": "partially_generated",
            "relative_path": null,
            "children": [{
              "id": "variables",
              "title": "Variables",
              "kind": "markdown",
              "status": "generated",
              "relative_path": "chapters/01-foundations/variables.md",
              "children": []
            }]
          }]
        }
        """

        let brief = try JSONDecoder().decode(CourseBrief.self, from: Data(payload.utf8))
        let chapter = try XCTUnwrap(brief.learningPath?.first)

        XCTAssertEqual(chapter.status, .partiallyGenerated)
        XCTAssertEqual(chapter.children.first?.kind, .markdown)
        XCTAssertEqual(chapter.children.first?.relativePath, "chapters/01-foundations/variables.md")
    }

    func testCompletedBuildAcceptsGeneratedExerciseAndManifestDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseBuildStateTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var brief = CourseBrief()
        brief.planID = "binary-search"
        brief.revision = 2
        brief.chapters = [
            CourseChapter(id: "core", title: "Core", objective: "Learn it.", deliverables: ["lesson", "exercise"]),
            CourseChapter(id: "boundaries", title: "Boundaries", objective: "Make it reliable.", deliverables: ["outline"]),
        ]

        try write("# Index", to: root.appendingPathComponent("index.md"))
        try write("# Profile", to: root.appendingPathComponent("context/learner-profile.md"))
        try write("# Design", to: root.appendingPathComponent("context/course-design.md"))
        try write("# Notes", to: root.appendingPathComponent(".course/agent-notes.md"))
        try write("{}", to: root.appendingPathComponent(".course/generation-state.json"))
        try write("# Core", to: root.appendingPathComponent("chapters/01-core/README.md"))
        try write("# Lesson", to: root.appendingPathComponent("chapters/01-core/lesson.md"))
        try write("# Exercise", to: root.appendingPathComponent("chapters/01-core/exercise.md"))
        try write("# Boundaries", to: root.appendingPathComponent("chapters/02-boundaries/README.md"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write(
            """
            {
              "plan_id": "binary-search",
              "revision": 2,
              "title": "Binary Search",
              "summary": "A compact course.",
              "outcome": "Implement binary search.",
              "estimated_duration": "45m",
              "chapters": [
                {"id":"core","title":"Core"},
                {"id":"boundaries","title":"Boundaries"}
              ],
              "learning_path": [{
                "id":"chapter-core",
                "title":"Core",
                "kind":"folder",
                "status":"generated",
                "relative_path":null,
                "children":[
                  {"id":"overview","title":"Overview","kind":"markdown","status":"generated","relative_path":"chapters/01-core/README.md","children":[]},
                  {"id":"lesson","title":"Lesson","kind":"markdown","status":"generated","relative_path":"chapters/01-core/lesson.md","children":[]},
                  {"id":"exercise","title":"Exercise","kind":"markdown","status":"generated","relative_path":"chapters/01-core/exercise.md","children":[]}
                ]
              }]
            }
            """,
            to: root.appendingPathComponent("course.json")
        )
        try write(
            """
            {
              "plan_id":"binary-search",
              "revision":2,
              "status":"bootstrap_complete",
              "files":[
                ".course/agent-notes.md",
                ".course/generation-state.json",
                "assets/",
                "context/learner-profile.md",
                "context/course-design.md",
                "course.json",
                "index.md",
                "chapters/01-core/README.md",
                "chapters/01-core/lesson.md",
                "chapters/01-core/exercise.md",
                "chapters/02-boundaries/README.md"
              ],
              "generated_chapter_ids":["core"],
              "next_chapter_id":"boundaries"
            }
            """,
            to: root.appendingPathComponent(".course/build-manifest.json")
        )

        let state = CourseExperienceStore.courseBuildState(root: root, brief: brief)

        XCTAssertEqual(state.step, 5)
        XCTAssertTrue(state.isComplete)
    }

    func testCourseBriefMergesLeanWorkspaceMetadataWithApprovedPlan() throws {
        let defaults = try makeDefaults()
        let store = CourseExperienceStore(defaults: defaults, environment: [:])
        let workspaceID = "course-brief-\(UUID().uuidString.lowercased())"
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apps/Courses/\(workspaceID)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var approved = CourseBrief()
        approved.planID = "binary-search"
        approved.title = "Approved title"
        approved.startingPoint = "Understands halving."
        approved.focusGap = "Loop invariants."
        approved.chapters = [
            CourseChapter(id: "core", title: "Core", objective: "Approved objective", deliverables: ["lesson"]),
        ]
        let approvedData = try JSONEncoder().encode(approved)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".course", isDirectory: true),
            withIntermediateDirectories: true
        )
        try approvedData.write(to: root.appendingPathComponent(".course/approved-plan.json"))
        try write(
            """
            {
              "plan_id":"binary-search",
              "revision":1,
              "title":"Generated title",
              "summary":"Generated summary",
              "outcome":"Generated outcome",
              "estimated_duration":"30m",
              "chapters":[{"id":"core","title":"Core"}],
              "learning_path":[]
            }
            """,
            to: root.appendingPathComponent("course.json")
        )
        let course = LearningCourse(
            id: "binary-search",
            title: "Generated title",
            subtitle: "Generated summary",
            accentHex: "1F6FEB",
            progress: 0,
            lessonCount: 1,
            duration: "30m",
            status: .ready,
            workspaceID: workspaceID
        )

        let loaded = try XCTUnwrap(store.courseBrief(for: course))

        XCTAssertEqual(loaded.title, "Generated title")
        XCTAssertEqual(loaded.startingPoint, "Understands halving.")
        XCTAssertEqual(loaded.focusGap, "Loop invariants.")
        XCTAssertEqual(loaded.chapters.first?.objective, "Approved objective")
    }

    func testLearningCoursePersistsOwningAgentThread() throws {
        let course = LearningCourse(
            id: "swift-concurrency",
            title: "Swift Concurrency",
            subtitle: "Tasks to actors",
            accentHex: "1F6FEB",
            progress: 0,
            lessonCount: 4,
            duration: "Adaptive",
            status: .ready,
            workspaceID: "workspace-1",
            agentServerID: "local",
            agentThreadID: "thread-1",
            agentRuntimeKind: "claude",
            agentModelID: "claude-sonnet"
        )

        let decoded = try JSONDecoder().decode(
            LearningCourse.self,
            from: JSONEncoder().encode(course)
        )

        XCTAssertEqual(decoded.agentServerID, "local")
        XCTAssertEqual(decoded.agentThreadID, "thread-1")
        XCTAssertEqual(decoded.agentRuntimeKind, "claude")
        XCTAssertEqual(decoded.agentModelID, "claude-sonnet")
    }

    func testCourseAgentCatalogCombinesLitterRegistryWithRuntimeAvailability() {
        let runtimes = [
            AgentRuntimeInfo(kind: "codex", name: "codex", displayName: "Codex", available: true),
            AgentRuntimeInfo(kind: "claude", name: "claude", displayName: "Claude Code", available: false),
            AgentRuntimeInfo(kind: "future-agent", name: "future-agent", displayName: "Future Agent", available: true),
        ]

        let catalog = CourseAgentOption.catalog(
            from: runtimes,
            knownRuntimeIDs: ["codex", "claude", "opencode"]
        )

        XCTAssertEqual(catalog.map(\.id), ["codex", "claude", "opencode", "future-agent"])
        XCTAssertEqual(catalog.first(where: { $0.id == "claude" })?.title, "Claude Code")
        XCTAssertEqual(catalog.first(where: { $0.id == "claude" })?.available, false)
        XCTAssertEqual(catalog.first(where: { $0.id == "future-agent" })?.available, true)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "CourseExperienceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}
