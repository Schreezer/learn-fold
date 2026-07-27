import XCTest
import NativeBlockEditorCore
import NativeBlockEditorUI
import NativeEditorMCP
@testable import Litter

@MainActor
final class CourseExperienceStoreTests: XCTestCase {
    func testFreshStoreStartsWithEmptyCourseLibraryAndRequiresAgentSetup() throws {
        let defaults = try makeDefaults()
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: ["SNAPPY_RESET_ONBOARDING": "1"]
        )

        XCTAssertFalse(store.hasCompletedIntro)
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
        XCTAssertTrue(store.hasCompletedIntro)
    }

    func testCompletingIntroPersistsForFutureLaunches() throws {
        let defaults = try makeDefaults()
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: ["SNAPPY_RESET_ONBOARDING": "1"]
        )

        XCTAssertFalse(store.hasCompletedIntro)
        store.completeIntro()

        let relaunchedStore = CourseExperienceStore(defaults: defaults, environment: [:])
        XCTAssertTrue(relaunchedStore.hasCompletedIntro)
        XCTAssertFalse(relaunchedStore.setupComplete)
    }

    func testExistingConfiguredLearnerDoesNotSeeIntroAfterUpdate() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: "snappy.course.agentSetupComplete")
        defaults.set(CourseAgentProvider.codex, forKey: "snappy.course.selectedAgent")

        let store = CourseExperienceStore(defaults: defaults, environment: [:])

        XCTAssertTrue(store.hasCompletedIntro)
        XCTAssertTrue(store.setupComplete)
    }

    func testRecoverReadyCoursesRestoresGeneratedWorkspaceMissingFromDefaults() async throws {
        let defaults = try makeDefaults()
        let store = CourseExperienceStore(defaults: defaults, environment: [:])
        let coursesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CourseExperienceStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let workspaceID = UUID().uuidString.lowercased()
        let workspaceURL = coursesRoot.appendingPathComponent(workspaceID, isDirectory: true)
        let databaseURL = workspaceURL.appendingPathComponent(
            ".course/course-library.sqlite"
        )
        defer { try? FileManager.default.removeItem(at: coursesRoot) }

        var brief = CourseBrief()
        brief.planID = "recovered-swift"
        brief.revision = 1
        brief.title = "Recovered Swift"
        brief.summary = "A recovered course."
        brief.estimatedDuration = "1 hour"
        brief.chapters = [
            CourseChapter(
                id: "chapter-1",
                title: "Chapter 1",
                objective: "Learn recovery.",
                deliverables: ["Lesson 1"]
            ),
        ]
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(brief).write(
            to: databaseURL.deletingLastPathComponent()
                .appendingPathComponent("approved-plan.json")
        )

        let repository = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID,
            databaseURL: databaseURL,
            rootTitle: brief.title
        )
        let root = try await repository.rootPageSnapshot()
        let rootResult = await repository.callTool(
            named: NativeEditorMCPToolCatalog.updatePage,
            argumentsJSON: try jsonString([
                "page_id": root.id,
                "expected_revision": root.revision,
                "command": "update_properties",
                "properties": [
                    "course_node_id": brief.planID,
                    "course_role": "course",
                    "bootstrap_status": "ready_for_learning",
                ],
            ])
        )
        XCTAssertFalse(rootResult.isError)

        let chapterResult = await repository.callTool(
            named: NativeEditorMCPToolCatalog.createPages,
            argumentsJSON: try jsonString([
                "parent": ["page_id": root.id],
                "pages": [[
                    "properties": [
                        "title": "Chapter 1",
                        "course_node_id": "chapter-1",
                        "course_role": "chapter",
                        "generation_status": "pending_generation",
                    ],
                    "content": "# Chapter 1",
                ]],
            ])
        )
        XCTAssertFalse(chapterResult.isError)
        let outline = try await repository.outline()
        let chapterPageID = try XCTUnwrap(outline.learningPages.first?.pageID)
        let lessonResult = await repository.callTool(
            named: NativeEditorMCPToolCatalog.createPages,
            argumentsJSON: try jsonString([
                "parent": ["page_id": chapterPageID],
                "pages": [[
                    "properties": [
                        "title": "Lesson 1",
                        "course_node_id": "lesson-1",
                        "course_role": "lesson",
                        "generation_status": "generated",
                    ],
                    "content": "# Lesson 1\nGenerated.",
                ]],
            ])
        )
        XCTAssertFalse(lessonResult.isError)

        await store.recoverReadyCourses(in: coursesRoot)

        XCTAssertEqual(store.courses.count, 1)
        XCTAssertEqual(store.courses.first?.id, "recovered-swift")
        XCTAssertEqual(store.courses.first?.workspaceID, workspaceID)
        XCTAssertNotNil(defaults.data(forKey: "snappy.course.savedCourses"))
    }

    func testPrivateCloudComputeIsPreferredWhenBothAppleModesAreAvailable() throws {
        let defaults = try makeDefaults()
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: [
                "SNAPPY_RESET_ONBOARDING": "1",
                "SNAPPY_APPLE_ON_DEVICE_AVAILABLE": "1",
                "SNAPPY_APPLE_PRIVATE_CLOUD_AVAILABLE": "1",
            ]
        )

        XCTAssertEqual(store.preferredSetupAgentID, CourseAgentProvider.applePrivateCloud)
        XCTAssertTrue(
            store.agentOptions.first(where: {
                $0.id == CourseAgentProvider.applePrivateCloud
            })?.available == true
        )
    }

    func testCodexIsOnlySetupChoiceWhenAppleModelsAreUnavailable() throws {
        let defaults = try makeDefaults()
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: [
                "SNAPPY_RESET_ONBOARDING": "1",
                "SNAPPY_APPLE_ON_DEVICE_AVAILABLE": "0",
                "SNAPPY_APPLE_PRIVATE_CLOUD_AVAILABLE": "0",
            ]
        )

        XCTAssertEqual(store.preferredSetupAgentID, CourseAgentProvider.codex)
        XCTAssertEqual(
            store.agentOptions.filter(\.available).map(\.id),
            [CourseAgentProvider.codex]
        )
    }

    func testUnavailableSavedAppleDefaultReturnsLearnerToSetupPicker() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: "snappy.course.agentSetupComplete")
        defaults.set(
            CourseAgentProvider.applePrivateCloud,
            forKey: "snappy.course.selectedAgent"
        )

        let store = CourseExperienceStore(
            defaults: defaults,
            environment: [
                "SNAPPY_APPLE_ON_DEVICE_AVAILABLE": "0",
                "SNAPPY_APPLE_PRIVATE_CLOUD_AVAILABLE": "0",
            ]
        )

        XCTAssertFalse(store.setupComplete)
        XCTAssertNil(store.selectedAgentID)
        XCTAssertEqual(store.preferredSetupAgentID, CourseAgentProvider.codex)
    }

    func testThreadProviderPolicyLocksCodexAndAllowsAppleModeSwitching() {
        XCTAssertFalse(
            CourseAgentProvider.canContinueThread(
                from: CourseAgentProvider.codex,
                with: CourseAgentProvider.appleOnDevice
            )
        )
        XCTAssertFalse(
            CourseAgentProvider.canContinueThread(
                from: CourseAgentProvider.applePrivateCloud,
                with: CourseAgentProvider.codex
            )
        )
        XCTAssertTrue(
            CourseAgentProvider.canContinueThread(
                from: CourseAgentProvider.appleOnDevice,
                with: CourseAgentProvider.applePrivateCloud
            )
        )
    }

    func testAppleContextBudgetsCompactBeforeProviderLimits() {
        let onDevice = AppleCourseContextBudget.forProvider(
            CourseAgentProvider.appleOnDevice
        )
        let privateCloud = AppleCourseContextBudget.forProvider(
            CourseAgentProvider.applePrivateCloud
        )

        XCTAssertEqual(onDevice.triggerTokens, 6_500)
        XCTAssertEqual(onDevice.summaryTokenLimit, 1_500)
        XCTAssertEqual(onDevice.effectiveTrigger(contextSize: 4_096), 2_084)
        XCTAssertEqual(privateCloud.triggerTokens, 27_500)
        XCTAssertEqual(privateCloud.summaryTokenLimit, 1_500)
        XCTAssertEqual(privateCloud.effectiveTrigger(contextSize: 32_768), 27_500)
    }

    func testAppleProviderSwitchCompactionFallbackWorksInBothDirections() {
        XCTAssertEqual(
            CourseAgentProvider.compactionFallback(
                from: CourseAgentProvider.applePrivateCloud,
                to: CourseAgentProvider.appleOnDevice
            ),
            .localSummary
        )
        XCTAssertEqual(
            CourseAgentProvider.compactionFallback(
                from: CourseAgentProvider.appleOnDevice,
                to: CourseAgentProvider.applePrivateCloud
            ),
            .targetProvider(CourseAgentProvider.applePrivateCloud)
        )
        XCTAssertNil(
            CourseAgentProvider.compactionFallback(
                from: CourseAgentProvider.appleOnDevice,
                to: CourseAgentProvider.appleOnDevice
            )
        )
    }

    func testAppleContextBudgetIncludesIncomingPromptAndUsesConservativeEstimate() {
        let budget = AppleCourseContextBudget(
            triggerTokens: 10,
            summaryTokenLimit: 3
        )

        XCTAssertFalse(
            budget.shouldCompact(
                currentContext: String(repeating: "a", count: 20),
                incomingPrompt: "one two"
            )
        )
        XCTAssertTrue(
            budget.shouldCompact(
                currentContext: String(repeating: "a", count: 32),
                incomingPrompt: "one two"
            )
        )
        XCTAssertGreaterThanOrEqual(
            budget.estimatedTokens(in: String(repeating: "学", count: 12)),
            12
        )
    }

    func testPrivateCloudCancellationRetriesRemainBoundedForMutationFreeTurns() {
        XCTAssertTrue(
            AppleCoursePrivateCloudRetryPolicy.canRetryCancellation(
                retryCount: 0,
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertTrue(
            AppleCoursePrivateCloudRetryPolicy.canRetryCancellation(
                retryCount: 1,
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertFalse(
            AppleCoursePrivateCloudRetryPolicy.canRetryCancellation(
                retryCount: 2,
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: false
            )
        )
    }

    func testPrivateCloudCancellationNeverRetriesPossibleSideEffects() {
        XCTAssertFalse(
            AppleCoursePrivateCloudRetryPolicy.canRetryCancellation(
                retryCount: 0,
                taskWasCancelled: false,
                latestResponse: "Partial",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertFalse(
            AppleCoursePrivateCloudRetryPolicy.canRetryCancellation(
                retryCount: 0,
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: true,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertFalse(
            AppleCoursePrivateCloudRetryPolicy.canRetryCancellation(
                retryCount: 0,
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: true
            )
        )
        XCTAssertFalse(
            AppleCoursePrivateCloudRetryPolicy.canRetryCancellation(
                retryCount: 0,
                taskWasCancelled: true,
                latestResponse: "",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: false
            )
        )
    }

    func testPrivateCloudWatchdogOnlyCancelsMutationFreeHungAttempts() {
        XCTAssertEqual(
            AppleCoursePrivateCloudRetryPolicy.mutationFreeAttemptTimeout,
            .seconds(90)
        )
        XCTAssertTrue(
            AppleCoursePrivateCloudRetryPolicy.canCancelHungAttempt(
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertFalse(
            AppleCoursePrivateCloudRetryPolicy.canCancelHungAttempt(
                taskWasCancelled: false,
                latestResponse: "partial",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertFalse(
            AppleCoursePrivateCloudRetryPolicy.canCancelHungAttempt(
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: true,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertFalse(
            AppleCoursePrivateCloudRetryPolicy.canCancelHungAttempt(
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: true
            )
        )
    }

#if canImport(FoundationModels)
    func testAppleLiveSessionCallbacksRebindForApprovedTurn() throws {
        guard #available(iOS 26.0, *) else { return }

        var firstPlanCount = 0
        var firstMutationCount = 0
        var approvedPlanCount = 0
        var approvedMutationCount = 0
        let callbacks = AppleCourseLiveSessionCallbacks(
            onCoursePlan: { _ in firstPlanCount += 1 },
            onEditorMutationAttempt: { firstMutationCount += 1 }
        )
        var plan = CourseBrief()
        plan.title = "Swift Concurrency"

        try callbacks.presentCoursePlan(plan)
        callbacks.recordEditorMutationAttempt()
        callbacks.rebind(
            onCoursePlan: { _ in approvedPlanCount += 1 },
            onEditorMutationAttempt: { approvedMutationCount += 1 }
        )
        try callbacks.presentCoursePlan(plan)
        callbacks.recordEditorMutationAttempt()

        XCTAssertEqual(firstPlanCount, 1)
        XCTAssertEqual(firstMutationCount, 1)
        XCTAssertEqual(approvedPlanCount, 1)
        XCTAssertEqual(approvedMutationCount, 1)
    }
#endif

    func testApplePlanValidatorRejectsPlaceholderChapterExplosion() {
        var plan = CourseBrief(
            planID: "sky-course",
            revision: 1,
            title: "Why the Sky Is Blue",
            summary: "A visual introduction.",
            outcome: "Explain Rayleigh scattering.",
            startingPoint: "Basic science.",
            focusGap: "No optics background.",
            estimatedDuration: "30 minutes",
            chapters: [
                CourseChapter(
                    id: "light",
                    title: "Light and air",
                    objective: "Understand scattering.",
                    deliverables: ["Visual explanation"]
                ),
            ]
        )

        XCTAssertNil(AppleCoursePlanValidator.issue(in: plan))

        plan.chapters.append(
            contentsOf: (2...9).map {
                CourseChapter(
                    id: "placeholder-\($0)",
                    title: "",
                    objective: "",
                    deliverables: [""]
                )
            }
        )
        XCTAssertEqual(
            AppleCoursePlanValidator.issue(in: plan),
            "the plan must contain between 1 and 8 chapters"
        )
    }

    func testApplePlanValidatorRejectsFoundationModelSchemaFragments() {
        let malformed = CourseBrief(
            planID: ",revision:1,starting_point:",
            revision: 1,
            title: "}}",
            summary: ",title:",
            outcome: ",plan_id:",
            startingPoint: ",summary:",
            focusGap: ",outcome:",
            estimatedDuration: "}],estimated_duration:",
            chapters: [
                CourseChapter(
                    id: "actor-basics",
                    title: "Swift Actor Basics",
                    objective: "Understand actor reentrancy",
                    deliverables: ["Explain actor interleaving"]
                ),
            ]
        )

        XCTAssertNotNil(AppleCoursePlanValidator.issue(in: malformed))
    }

    func testAppleCourseSchemaPlacesScalarPlanFieldsBeforeChapterArray() {
        let keys = AppleCourseGenerationSchemaOrdering.orderedKeys(
            in: [
                "chapters": ["type": "array"],
                "summary": ["type": "string"],
                "title": ["type": "string"],
                "revision": ["type": "integer"],
                "plan_id": ["type": "string"],
            ]
        )

        XCTAssertEqual(keys, ["plan_id", "revision", "title", "summary", "chapters"])
    }

    func testAppleSetupDoesNotRequireCodexTransport() async throws {
        let defaults = try makeDefaults()
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: [
                "SNAPPY_RESET_ONBOARDING": "1",
                "SNAPPY_APPLE_ON_DEVICE_AVAILABLE": "1",
                "SNAPPY_APPLE_PRIVATE_CLOUD_AVAILABLE": "0",
            ]
        )

        await store.connectLocalAgent(
            appModel: AppModel(),
            agentID: CourseAgentProvider.appleOnDevice
        )

        XCTAssertTrue(store.setupComplete)
        XCTAssertEqual(store.selectedAgentID, CourseAgentProvider.appleOnDevice)
        XCTAssertEqual(store.connectionState, .connected)
    }

    func testActiveAppleCourseCanSwitchAppleModesButCannotBecomeCodex() async throws {
        let defaults = try makeDefaults()
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: [
                "SNAPPY_RESET_ONBOARDING": "1",
                "SNAPPY_APPLE_ON_DEVICE_AVAILABLE": "1",
                "SNAPPY_APPLE_PRIVATE_CLOUD_AVAILABLE": "1",
            ]
        )
        await store.connectLocalAgent(
            appModel: AppModel(),
            agentID: CourseAgentProvider.applePrivateCloud
        )
        store.beginNewCourse()

        XCTAssertTrue(
            store.switchCurrentAppleProvider(to: CourseAgentProvider.appleOnDevice)
        )
        XCTAssertEqual(store.activeAgentID, CourseAgentProvider.appleOnDevice)
        XCTAssertFalse(
            store.switchCurrentAppleProvider(to: CourseAgentProvider.codex)
        )
        XCTAssertEqual(store.activeAgentID, CourseAgentProvider.appleOnDevice)
    }

    func testAppleCourseResponseStreamsIntoLocalTimelineWithoutAppServerThread() async throws {
        let defaults = try makeDefaults()
        let runtime = TestAppleCourseAgentRuntime()
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: ["SNAPPY_RESET_ONBOARDING": "1"],
            appleRuntime: runtime
        )
        let appModel = AppModel()
        await store.connectLocalAgent(
            appModel: appModel,
            agentID: CourseAgentProvider.appleOnDevice
        )
        store.beginNewCourse()

        store.sendMessage(
            "Explain actor isolation.",
            appModel: appModel,
            appState: AppState()
        )
        for _ in 0..<100 where store.isAgentRequestPending {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNil(store.agentThreadKey)
        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages.first?.text, "Explain actor isolation.")
        XCTAssertEqual(store.messages.last?.text, "A streamed Apple response.")
        XCTAssertEqual(runtime.lastProviderID, CourseAgentProvider.appleOnDevice)
    }

    func testHydratingAppleCourseDoesNotMaskUnavailableProvider() async throws {
        let defaults = try makeDefaults()
        let runtime = TestAppleCourseAgentRuntime()
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: ["SNAPPY_RESET_ONBOARDING": "1"],
            appleRuntime: runtime
        )
        let appModel = AppModel()
        await store.connectLocalAgent(
            appModel: appModel,
            agentID: CourseAgentProvider.appleOnDevice
        )
        store.beginNewCourse()
        runtime.currentAvailability = AppleCourseAgentAvailability(
            onDevice: .init(available: false, reason: "Model is unavailable for testing."),
            privateCloud: .init(available: false, reason: "Cloud is unavailable for testing.")
        )

        await store.refreshAgentReadiness(appModel: appModel)
        await store.hydrateCourseThread(appModel: appModel, appState: AppState())

        XCTAssertEqual(
            store.connectionState,
            .failed("Model is unavailable for testing.")
        )
    }

    func testAppleMutationApprovalMustMatchLatestPresentedPlanRevision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-course-approval-\(UUID().uuidString)", isDirectory: true)
        let metadata = root.appendingPathComponent(".course", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)

        var presented = CourseBrief()
        presented.planID = "actor-reentrancy"
        presented.revision = 2
        var approved = presented
        approved.revision = 1
        try JSONEncoder().encode(presented).write(
            to: metadata.appendingPathComponent(AppleCourseApprovalPolicy.presentedPlanFilename)
        )
        try JSONEncoder().encode(approved).write(
            to: metadata.appendingPathComponent(AppleCourseApprovalPolicy.approvedPlanFilename)
        )

        XCTAssertFalse(
            AppleCourseApprovalPolicy.isLatestPlanApproved(courseDirectory: root)
        )

        approved.revision = 2
        try JSONEncoder().encode(approved).write(
            to: metadata.appendingPathComponent(AppleCourseApprovalPolicy.approvedPlanFilename)
        )
        XCTAssertTrue(
            AppleCourseApprovalPolicy.isLatestPlanApproved(courseDirectory: root)
        )
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

    func testCourseAgentPublishesRevisionSafeNativeEditorTools() throws {
        let tools = try CourseAgentTools.documentToolSpecs()
        let names = Set(tools.map(\.name))

        XCTAssertTrue(names.contains("native-editor-fetch"))
        XCTAssertTrue(names.contains("native-editor-create-pages"))
        XCTAssertTrue(names.contains("native-editor-update-page"))
        let updateTool = try XCTUnwrap(tools.first(where: { $0.name == "native-editor-update-page" }))
        let schemaData = Data(updateTool.inputSchemaJson.utf8)
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: schemaData) as? [String: Any])
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertTrue(required.contains("expected_revision"))
    }

    func testCourseMCPToolsRequireWorkspaceAndPreserveApprovalAnnotations() throws {
        let tools = try CourseAgentTools.mcpToolDefinitions()
        let presentPlan = try XCTUnwrap(tools.first(where: {
            $0.name == CourseAgentTools.presentPlan
        }))
        let updatePage = try XCTUnwrap(tools.first(where: {
            $0.name == "native-editor-update-page"
        }))
        let fetch = try XCTUnwrap(tools.first(where: {
            $0.name == "native-editor-fetch"
        }))

        let planRequired = try XCTUnwrap(presentPlan.inputSchema["required"] as? [String])
        let updateRequired = try XCTUnwrap(updatePage.inputSchema["required"] as? [String])
        XCTAssertTrue(planRequired.contains(CourseAgentTools.workspaceIDArgument))
        XCTAssertTrue(updateRequired.contains(CourseAgentTools.workspaceIDArgument))
        XCTAssertTrue(presentPlan.readOnly)
        XCTAssertTrue(fetch.readOnly)
        XCTAssertFalse(updatePage.readOnly)
        XCTAssertTrue(updatePage.destructive)
    }

    func testCourseMCPConfigIsThreadScopedAndDirectForCodeModeOnlyModels() throws {
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:54321/mcp"))
        let json = try CourseExperienceStore.courseMCPConfigJSON(endpoint: endpoint)
        let config = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        XCTAssertEqual(
            config["mcp_servers.\(CourseAgentTools.mcpServerName).url"] as? String,
            endpoint.absoluteString
        )
        XCTAssertEqual(
            config["features.code_mode.direct_only_tool_namespaces"] as? [String],
            [CourseAgentTools.mcpDirectNamespace]
        )
        XCTAssertEqual(
            config["mcp_servers.\(CourseAgentTools.mcpServerName).default_tools_approval_mode"] as? String,
            "approve"
        )
    }

    func testCoursePlanHydrationAcceptsCompletedLearnfoldMCPCall() {
        let arguments = """
        {"workspace_id":"selection-qa","plan_id":"swift","revision":1}
        """
        let content = HydratedConversationItemContent.mcpToolCall(
            HydratedMcpToolCallData(
                server: CourseAgentTools.mcpServerName,
                tool: CourseAgentTools.presentPlan,
                status: .completed,
                durationMs: 12,
                argumentsJson: arguments,
                contentSummary: nil,
                structuredContentJson: nil,
                rawOutputJson: nil,
                errorMessage: nil,
                progressMessages: [],
                computerUse: nil
            )
        )

        XCTAssertEqual(
            CourseExperienceStore.completedCoursePlanArgumentsJSON(from: content),
            arguments
        )
    }

    func testCourseMCPProtocolListsNativeCourseTools() async throws {
        let request = JSONValue.object([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": .object([:]),
        ])
        let response = await CourseMCPProtocol.handleJSONRPC(
            body: try JSONEncoder().encode(request)
        )
        XCTAssertEqual(response.statusCode, 200)
        let body = try XCTUnwrap(response.body)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: body)
        let tools = try XCTUnwrap(
            decoded.objectValue?["result"]?.objectValue?["tools"]?.arrayValue
        )
        let names = Set(tools.compactMap { $0.objectValue?["name"]?.stringValue })

        XCTAssertTrue(names.contains(CourseAgentTools.presentPlan))
        XCTAssertTrue(names.contains("native-editor-fetch"))
        XCTAssertTrue(names.contains("native-editor-update-page"))
    }

    func testCourseMCPServerServesToolsOverLoopbackHTTP() async throws {
        let endpoint = try CourseMCPServer.shared.start()
        XCTAssertEqual(endpoint.host, "127.0.0.1")

        let message = JSONValue.object([
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/list",
            "params": .object([:]),
        ])
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(message)

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        let tools = try XCTUnwrap(
            decoded.objectValue?["result"]?.objectValue?["tools"]?.arrayValue
        )
        XCTAssertTrue(tools.contains {
            $0.objectValue?["name"]?.stringValue == CourseAgentTools.presentPlan
        })
    }

    func testCourseMCPRejectsPageMutationBeforePlanApproval() async throws {
        let workspaceID = "mcp-approval-\(UUID().uuidString)"
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apps/Courses/\(workspaceID)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = JSONValue.object([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "native-editor-create-pages",
                "arguments": [
                    CourseAgentTools.workspaceIDArgument: .string(workspaceID)
                ],
            ],
        ])
        let response = await CourseMCPProtocol.handleJSONRPC(
            body: try JSONEncoder().encode(request)
        )
        let body = try XCTUnwrap(response.body)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: body)
        let result = try XCTUnwrap(decoded.objectValue?["result"]?.objectValue)

        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertTrue(
            result["content"]?.arrayValue?.first?
                .objectValue?["text"]?.stringValue?
                .contains("has not been approved") == true
        )
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

    func testCourseChatKeepsOptimisticMessageUntilLiveItemsAreVisible() {
        let learner = CourseChatMessage(role: .learner, text: "Why does await yield?")

        XCTAssertEqual(
            CourseChatTimelinePolicy.localMessages(
                [learner],
                hasLiveThread: false
            ).map(\.id),
            [learner.id]
        )
    }

    func testSelectionDiscussionRoundTripsItsAnchorAndThread() throws {
        let reference = try XCTUnwrap(CourseTextReference(
            id: UUID(uuidString: "F217B8AC-2718-4EF0-A079-6710F99D6D12")!,
            courseID: "swift-course",
            pageID: "lesson-1",
            pageTitle: "Actor reentrancy",
            blockID: "block-await",
            pathIndices: [2, 0],
            rangeLocation: 12,
            rangeLength: 19,
            selectedText: "await can interleave"
        ))
        var discussion = CourseSelectionDiscussion(reference: reference)
        discussion.serverID = "local"
        discussion.threadID = UUID().uuidString
        discussion.hasSubmittedQuestion = true

        let decoded = try JSONDecoder().decode(
            CourseSelectionDiscussion.self,
            from: JSONEncoder().encode(discussion)
        )

        XCTAssertEqual(decoded, discussion)
        XCTAssertEqual(decoded.reference, reference)
        XCTAssertTrue(decoded.matches(reference))
    }

    func testSelectionAnchorRecoversAfterTextMovesWithinStableBlock() throws {
        var originalBlock = BlockNode.paragraph("Before await can interleave after")
        originalBlock.data["block_id"] = .string("stable-await")
        let original = BlockDocument(
            root: BlockNode(type: "page", children: [originalBlock])
        )
        let selection = NativeBlockEditorSelection(
            blockID: "stable-await",
            path: [0],
            range: NSRange(location: 7, length: 20),
            text: "await can interleave"
        )
        let reference = try XCTUnwrap(CourseSelectionAnchorResolver.reference(
            courseID: "swift",
            pageID: "lesson",
            pageTitle: "Reentrancy",
            selection: selection,
            document: original
        ))
        let discussion = CourseSelectionDiscussion(reference: reference)

        var movedBlock = BlockNode.paragraph("New prefix: Before await can interleave after")
        movedBlock.data["block_id"] = .string("stable-await")
        let moved = BlockDocument(
            root: BlockNode(type: "page", children: [movedBlock])
        )
        let annotation = try XCTUnwrap(
            CourseSelectionAnchorResolver.annotation(for: discussion, document: moved)
        )

        XCTAssertEqual(annotation.blockID, "stable-await")
        XCTAssertEqual(annotation.path, BlockPath([0]))
        XCTAssertEqual(annotation.range.location, 19)
        XCTAssertEqual(annotation.range.length, 20)
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

    func testCourseAgentHydrationTimeoutDoesNotWarnWhileTurnIsStillActive() {
        XCTAssertFalse(CourseAgentHydrationPolicy.shouldSurfaceTimeoutError(
            summaryHasActiveTurn: true,
            threadHasActiveTurn: false
        ))
        XCTAssertFalse(CourseAgentHydrationPolicy.shouldSurfaceTimeoutError(
            summaryHasActiveTurn: false,
            threadHasActiveTurn: true
        ))
        XCTAssertTrue(CourseAgentHydrationPolicy.shouldSurfaceTimeoutError(
            summaryHasActiveTurn: false,
            threadHasActiveTurn: false
        ))
    }

    func testCourseChatScrollPolicyStopsFollowingWhenReaderDragsAway() {
        let autoFollow = CourseChatScrollPolicy.updatedAutoFollow(
            currentValue: true,
            distanceFromBottom: 120,
            userIsDragging: true,
            isAgentWorking: true
        )

        XCTAssertFalse(autoFollow)
        XCTAssertFalse(CourseChatScrollPolicy.shouldFollow(
            autoFollowEnabled: autoFollow,
            userIsDragging: true
        ))
    }

    func testCourseChatScrollPolicyRestoresFollowingOnlyNearBottom() {
        XCTAssertFalse(CourseChatScrollPolicy.updatedAutoFollow(
            currentValue: false,
            distanceFromBottom: 120,
            userIsDragging: false,
            isAgentWorking: true
        ))
        XCTAssertTrue(CourseChatScrollPolicy.updatedAutoFollow(
            currentValue: false,
            distanceFromBottom: CourseChatScrollPolicy.nearBottomDistance,
            userIsDragging: false,
            isAgentWorking: true
        ))
    }

    func testCourseChatAuthPolicySeparatesTransportFromAccountReadiness() {
        XCTAssertTrue(CourseChatAuthPolicy.needsSignIn(
            isCodex: true,
            requiresOpenAIAuth: true,
            hasAccount: false,
            explicitlyRequired: false
        ))
        XCTAssertFalse(CourseChatAuthPolicy.isReady(
            isCodex: true,
            transportConnected: true,
            requiresOpenAIAuth: true,
            hasAccount: false
        ))
        XCTAssertTrue(CourseChatAuthPolicy.isReady(
            isCodex: true,
            transportConnected: true,
            requiresOpenAIAuth: false,
            hasAccount: false
        ))
        XCTAssertTrue(CourseChatAuthPolicy.isReady(
            isCodex: true,
            transportConnected: true,
            requiresOpenAIAuth: true,
            hasAccount: true
        ))
    }

    func testCourseChatRecoveryRestoresSubmittedSourcesWithoutDuplicates() {
        let submittedDocument = CourseSource(name: "notes.pdf", detail: "PDF", kind: .document)
        let submittedLink = CourseSource(name: "https://example.com", detail: "EXAMPLE.COM", kind: .link)
        let newerPhoto = CourseSource(name: "diagram", detail: "PHOTO", kind: .image)

        let recovered = CourseExperienceStore.recoveredSources(
            submitted: [submittedDocument, submittedLink],
            current: [submittedLink, newerPhoto]
        )

        XCTAssertEqual(recovered.map(\.id), [submittedDocument.id, submittedLink.id, newerPhoto.id])
    }

    func testCourseChatLinkSourcesBecomeModelVisibleInput() {
        let link = CourseSource(
            name: "https://developer.apple.com/swift/",
            detail: "DEVELOPER.APPLE.COM",
            kind: .link
        )

        XCTAssertEqual(
            CourseExperienceStore.agentMessageText(text: "Summarize this", sources: [link]),
            "Summarize this\n\nLinked sources:\n- https://developer.apple.com/swift/"
        )
        XCTAssertEqual(
            CourseExperienceStore.agentMessageText(text: "", sources: [link]),
            "Use these linked sources:\n- https://developer.apple.com/swift/"
        )
    }

    func testCourseChatRejectsLegacySyntheticThreadIDs() {
        XCTAssertFalse(CourseExperienceStore.isValidAppServerThreadID("selection-qa-thread"))
        XCTAssertFalse(CourseExperienceStore.isValidAppServerThreadID(""))
        XCTAssertTrue(CourseExperienceStore.isValidAppServerThreadID("019f7e41-81cf-7f22-b5a7-3c00009cec20"))
        XCTAssertTrue(CourseExperienceStore.isValidAppServerThreadID("urn:uuid:019f7e41-81cf-7f22-b5a7-3c00009cec20"))
    }

    func testCourseChatFailureCopyExplainsRecoveryWithoutRPCInternals() {
        XCTAssertEqual(
            CourseExperienceStore.agentFailureMessage(turnWasAccepted: false, submissionRestored: true),
            "Codex couldn’t send that yet. Your message and sources are still here—try again."
        )
        XCTAssertEqual(
            CourseExperienceStore.agentFailureMessage(turnWasAccepted: true, submissionRestored: false),
            "Codex started this request, but the reply did not finish loading. Reopen the chat to check the thread."
        )
    }

    func testAppleCourseFailureCopyNeverLeaksToolSchemaDiagnostics() {
        let frameworkError = NSError(
            domain: "FoundationModels",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    #"AppleDynamicCourseTool(parameters: {"$defs":{"page":{"properties":{}}}})"#,
            ]
        )

        XCTAssertEqual(
            CourseExperienceStore.appleAgentFailureMessage(frameworkError),
            "Apple’s model couldn’t complete this request. Please try again."
        )
        XCTAssertEqual(
            CourseExperienceStore.appleAgentFailureMessage(
                AppleCourseAgentError.toolFailed("Each page needs a title. Please try again.")
            ),
            "Each page needs a title. Please try again."
        )
    }

    func testAppleCourseFailureCopyExplainsPendingModelAssets() {
        let frameworkError = NSError(
            domain: "FoundationModels",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "The assets required for the session are unavailable."
            ]
        )

        XCTAssertEqual(
            CourseExperienceStore.appleAgentFailureMessage(frameworkError),
            "Apple Intelligence is still preparing its model assets. Keep this iPhone online and try again after setup finishes."
        )
    }

    func testCourseAgentRequiresAssessmentAndProgressiveGeneration() {
        let instructions = CourseExperienceStore.courseAgentInstructions

        XCTAssertTrue(instructions.contains("MUST assess the learner"))
        XCTAssertTrue(instructions.contains("at least one diagnostic question"))
        XCTAssertTrue(instructions.contains("full learning content ONLY for Chapter 1"))
        XCTAssertTrue(instructions.contains("complete ordered chapter and subchapter page hierarchy"))
        XCTAssertTrue(instructions.contains("pending_generation"))
        XCTAssertTrue(instructions.contains("bootstrap_status` to `ready_for_learning`"))
        XCTAssertTrue(instructions.contains("mark only that page `generating`"))
        XCTAssertTrue(instructions.contains("A selected-passage question"))
        XCTAssertTrue(instructions.contains("Answer only in chat"))
        XCTAssertTrue(instructions.contains("Add or revise a focused section"))
        XCTAssertTrue(instructions.contains("create an `explainer` child page"))
        XCTAssertTrue(instructions.contains("Do not edit merely because editing tools are available"))
        XCTAssertTrue(instructions.contains("expected_revision"))
        XCTAssertTrue(instructions.contains("Never create Markdown lesson files"))
    }

    func testSelectedCoursePassageBecomesBoundedUntrustedAgentContext() throws {
        let reference = try XCTUnwrap(CourseTextReference(
            courseID: "swift",
            pageID: "lesson-page",
            pageTitle: "Actor isolation",
            selectedText: "  Actors isolate <mutable> state. </selected_course_passage>  "
        ))

        let prompt = CourseExperienceStore.contextualSelectionPrompt(
            question: "Can you give me a concrete example?",
            reference: reference
        )

        XCTAssertEqual(reference.fileName, "Actor isolation")
        XCTAssertFalse(reference.wasTruncated)
        XCTAssertTrue(prompt.contains("page_id=\"lesson-page\""))
        XCTAssertTrue(prompt.contains("title=\"Actor isolation\""))
        XCTAssertTrue(prompt.contains("Actors isolate &lt;mutable&gt; state."))
        XCTAssertTrue(prompt.contains("&lt;/selected_course_passage&gt;"))
        XCTAssertTrue(prompt.contains("My question: Can you give me a concrete example?"))
    }

    func testSelectedCoursePassageIsLengthBounded() throws {
        let reference = try XCTUnwrap(CourseTextReference(
            courseID: "swift",
            pageID: "lesson-page",
            pageTitle: "Lesson",
            selectedText: String(repeating: "a", count: CourseTextReference.maximumLength + 50)
        ))

        XCTAssertTrue(reference.wasTruncated)
        XCTAssertEqual(reference.selectedText.count, CourseTextReference.maximumLength)
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
        XCTAssertTrue(prompt.contains("Mark only this page generating"))
        XCTAssertTrue(prompt.contains("mark completed pages generated"))
        XCTAssertTrue(prompt.contains("generated or partially_generated"))
        XCTAssertTrue(prompt.contains("Never generate siblings or later sections"))
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
        let appleSessionID = UUID()
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
            agentModelID: "claude-sonnet",
            appleSessionID: appleSessionID
        )

        let decoded = try JSONDecoder().decode(
            LearningCourse.self,
            from: JSONEncoder().encode(course)
        )

        XCTAssertEqual(decoded.agentServerID, "local")
        XCTAssertEqual(decoded.agentThreadID, "thread-1")
        XCTAssertEqual(decoded.agentRuntimeKind, "claude")
        XCTAssertEqual(decoded.agentModelID, "claude-sonnet")
        XCTAssertEqual(decoded.appleSessionID, appleSessionID)
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

    func testRemoteCourseToolCallParsesNestedArgumentsAndKeepsVisibleIntroduction() throws {
        let response = """
        I have enough context to propose the course.
        ```json
        {"learnfold_tool_call":{"name":"present_course_plan","arguments":{"workspace_id":"workspace-1","plan_id":"swift-actors","revision":1,"title":"Swift Actors","chapters":[{"id":"one","title":"Foundations","objective":"Understand { isolation }","deliverables":[]}]}}}
        ```
        """

        let call = try XCTUnwrap(CourseExperienceStore.remoteCourseToolCall(from: response))
        XCTAssertEqual(call.name, "present_course_plan")
        XCTAssertEqual(
            call.visibleText,
            "I have enough context to propose the course."
        )
        let arguments = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(call.argumentsJSON.data(using: .utf8))
            ) as? [String: Any]
        )
        XCTAssertEqual(arguments["workspace_id"] as? String, "workspace-1")
        XCTAssertEqual(arguments["plan_id"] as? String, "swift-actors")
    }

    func testRemoteCourseToolCallRejectsMalformedEnvelope() {
        XCTAssertNil(
            CourseExperienceStore.remoteCourseToolCall(
                from: #"{"learnfold_tool_call":{"name":"native-editor-fetch"}}"#
            )
        )
        XCTAssertNil(
            CourseExperienceStore.remoteCourseToolCall(
                from: #"{"tool_call":{"name":"native-editor-fetch","arguments":{}}}"#
            )
        )
    }

    func testSelectedRemoteCourseServerPersistsAcrossStoreLaunches() throws {
        let defaults = try makeDefaults()
        defaults.set("personal-claw", forKey: "snappy.course.selectedAgentServer")

        let store = CourseExperienceStore(defaults: defaults, environment: [:])

        XCTAssertEqual(store.selectedAgentServerID, "personal-claw")
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "CourseExperienceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}

@MainActor
private final class TestAppleCourseAgentRuntime: AppleCourseAgentRuntime {
    var lastProviderID: String?
    var currentAvailability = AppleCourseAgentAvailability(
        onDevice: .init(available: true, reason: "Available for testing."),
        privateCloud: .init(available: true, reason: "Available for testing.")
    )

    func availability() -> AppleCourseAgentAvailability {
        currentAvailability
    }

    func restoredMessages(
        sessionID: UUID,
        workspaceID: String
    ) async -> [AppleCourseAgentStoredMessage] {
        []
    }

    func send(
        sessionID: UUID,
        providerID: String,
        workspaceID: String,
        prompt: String,
        onPartialResponse: @escaping @MainActor (String) -> Void,
        onCoursePlan: @escaping @MainActor (CourseBrief) throws -> Void
    ) async throws {
        lastProviderID = providerID
        onPartialResponse("A streamed")
        await Task.yield()
        onPartialResponse("A streamed Apple response.")
    }

    func cancel(sessionID: UUID) {}

    func remove(sessionID: UUID, workspaceID: String) {}
}

final class CourseChatTimelinePolicyTests: XCTestCase {
    func testSelectionPromptProjectsOnlyLearnerQuestion() throws {
        let prompt = """
        I selected the following passage from the native course page `Lesson`.

        <selected_course_passage page_id="lesson" title="Lesson">
        await can interleave work
        </selected_course_passage>

        My question: Can you show me a timeline?
        """

        XCTAssertEqual(
            CourseChatTimelinePolicy.selectionQuestion(from: prompt),
            "Can you show me a timeline?"
        )
    }

    func testCompletedCourseMCPCallIsHiddenFromLearnerTimeline() {
        let item = mcpItem(
            server: CourseAgentTools.mcpServerName,
            tool: CourseAgentTools.presentPlan,
            status: .completed
        )

        XCTAssertTrue(CourseChatTimelinePolicy.projectLiveItems([item]).isEmpty)
    }

    func testRunningCourseMCPCallIsHiddenFromLearnerTimeline() {
        let item = mcpItem(
            server: CourseAgentTools.mcpServerName,
            tool: "native-editor-update-page",
            status: .inProgress
        )

        XCTAssertTrue(CourseChatTimelinePolicy.projectLiveItems([item]).isEmpty)
    }

    func testFailedCoursePlanCallBecomesConciseLearnerFacingError() throws {
        let item = mcpItem(
            server: CourseAgentTools.mcpServerName,
            tool: CourseAgentTools.presentPlan,
            status: .failed,
            argumentsJSON: #"{"title":"Internal plan payload"}"#,
            rawOutputJSON: #"{"debug":"private result"}"#
        )

        let projected = try XCTUnwrap(
            CourseChatTimelinePolicy.projectLiveItems([item]).first
        )
        guard case .error(let error) = projected.content else {
            return XCTFail("Expected a learner-facing error")
        }

        XCTAssertEqual(projected.id, item.id)
        XCTAssertEqual(error.title, "Course action failed")
        XCTAssertEqual(
            error.message,
            "The course plan couldn’t be prepared. Please try again."
        )
        XCTAssertNil(error.details)
        XCTAssertFalse(error.message.contains("Internal plan payload"))
        XCTAssertFalse(error.message.contains("private result"))
    }

    func testNonCourseMCPCallRemainsUnchanged() {
        let item = mcpItem(
            server: "github",
            tool: "search_issues",
            status: .completed
        )

        XCTAssertEqual(
            CourseChatTimelinePolicy.projectLiveItems([item]),
            [item]
        )
    }

    func testCourseDynamicToolNamespaceIsAlsoHidden() {
        let item = ConversationItem(
            id: "dynamic-course-tool",
            content: .dynamicToolCall(
                ConversationDynamicToolCallData(
                    namespace: CourseAgentTools.mcpDirectNamespace,
                    tool: "native-editor-fetch-page",
                    status: .completed,
                    durationMs: 12,
                    success: true,
                    argumentsJSON: #"{"page_id":"internal"}"#,
                    contentSummary: "internal result",
                    display: nil
                )
            )
        )

        XCTAssertTrue(CourseChatTimelinePolicy.projectLiveItems([item]).isEmpty)
    }

    func testLegacyCourseDynamicToolWithoutNamespaceIsHidden() {
        let item = ConversationItem(
            id: "legacy-dynamic-course-tool",
            content: .dynamicToolCall(
                ConversationDynamicToolCallData(
                    namespace: nil,
                    tool: CourseAgentTools.presentPlan,
                    status: .completed,
                    durationMs: 12,
                    success: true,
                    argumentsJSON: #"{"title":"Internal plan payload"}"#,
                    contentSummary: "internal result",
                    display: nil
                )
            )
        )

        XCTAssertTrue(CourseChatTimelinePolicy.projectLiveItems([item]).isEmpty)
    }

    func testOrdinaryConversationItemsRemainInOrder() {
        let user = ConversationItem(
            id: "user",
            content: .user(
                ConversationUserMessageData(text: "Build a course", images: [])
            )
        )
        let assistant = ConversationItem(
            id: "assistant",
            content: .assistant(
                ConversationAssistantMessageData(
                    text: "I’ll prepare a plan.",
                    agentNickname: nil,
                    agentRole: nil,
                    phase: nil
                )
            )
        )

        XCTAssertEqual(
            CourseChatTimelinePolicy.projectLiveItems([user, assistant]),
            [user, assistant]
        )
    }

    func testRemoteHermesBootstrapProjectsOnlyLearnerMessage() throws {
        let item = ConversationItem(
            id: "remote-bootstrap",
            content: .user(
                ConversationUserMessageData(
                    text: """
                    Internal instructions.

                    Learnfold remote native-tool protocol:
                    - Use the envelope.

                    Learner message:
                    Build me a Swift course.
                    """,
                    images: []
                )
            )
        )

        let projected = try XCTUnwrap(
            CourseChatTimelinePolicy.projectLiveItems([item]).first
        )
        guard case .user(let data) = projected.content else {
            return XCTFail("Expected a projected learner message")
        }
        XCTAssertEqual(data.text, "Build me a Swift course.")
    }

    func testRemoteHermesToolEnvelopesAreHidden() {
        let call = ConversationItem(
            id: "remote-call",
            content: .assistant(
                ConversationAssistantMessageData(
                    text: #"{"learnfold_tool_call":{"name":"native-editor-fetch","arguments":{}}}"#,
                    agentNickname: nil,
                    agentRole: nil,
                    phase: nil
                )
            )
        )
        let result = ConversationItem(
            id: "remote-result",
            content: .user(
                ConversationUserMessageData(
                    text: #"{"learnfold_tool_result":{"name":"native-editor-fetch","success":true}}"#,
                    images: []
                )
            )
        )

        XCTAssertTrue(CourseChatTimelinePolicy.projectLiveItems([call, result]).isEmpty)
    }

    private func mcpItem(
        server: String,
        tool: String,
        status: AppOperationStatus,
        argumentsJSON: String? = nil,
        rawOutputJSON: String? = nil
    ) -> ConversationItem {
        ConversationItem(
            id: "mcp-\(server)-\(tool)",
            content: .mcpToolCall(
                ConversationMcpToolCallData(
                    server: server,
                    tool: tool,
                    status: status,
                    durationMs: 50,
                    argumentsJSON: argumentsJSON,
                    contentSummary: "tool result",
                    structuredContentJSON: nil,
                    rawOutputJSON: rawOutputJSON,
                    errorMessage: "internal failure detail",
                    progressMessages: ["internal progress"],
                    computerUse: nil
                )
            )
        )
    }
}
