import XCTest
import NativeBlockEditorCore
import NativeBlockEditorUI
import NativeEditorMCP
@testable import Litter

#if canImport(FoundationModels)
import FoundationModels
#endif

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
        let encodedBrief = try JSONEncoder().encode(brief)
        try encodedBrief.write(
            to: databaseURL.deletingLastPathComponent()
                .appendingPathComponent(AppleCourseApprovalPolicy.presentedPlanFilename)
        )
        try encodedBrief.write(
            to: databaseURL.deletingLastPathComponent()
                .appendingPathComponent(AppleCourseApprovalPolicy.approvedPlanFilename)
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

    func testColdHermesReadyWorkspaceReconcilesMetadataBeforePendingIdentityClears() async throws {
        let defaults = try makeDefaults()
        let workspaceID = "ready-hermes-\(UUID().uuidString.lowercased())"
        let threadID = UUID().uuidString.lowercased()
        var brief = CourseBrief()
        brief.planID = "ready-hermes-plan"
        brief.revision = 2
        brief.title = "Recovered Hermes Course"
        brief.summary = "Recovered after the ready database committed."
        brief.estimatedDuration = "45 minutes"
        let identity = PendingHermesCourseIdentity(
            workspaceID: workspaceID,
            serverID: "server-hermes",
            threadID: threadID,
            runtimeID: "hermes",
            modelID: "hermes-model",
            brief: brief,
            showsBrief: false,
            expectedTurnID: nil,
            terminalError: nil
        )
        defaults.set(
            try JSONEncoder().encode(identity),
            forKey: CourseExperienceStore.pendingHermesCourseKey
        )
        let store = CourseExperienceStore(defaults: defaults)
        let databaseURL = store.courseDatabaseURL(workspaceID: workspaceID)
        let workspaceURL = databaseURL.deletingLastPathComponent().deletingLastPathComponent()
        let coursesRoot = workspaceURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encodedBrief = try JSONEncoder().encode(brief)
        try encodedBrief.write(
            to: databaseURL.deletingLastPathComponent()
                .appendingPathComponent(AppleCourseApprovalPolicy.presentedPlanFilename)
        )
        try encodedBrief.write(
            to: databaseURL.deletingLastPathComponent()
                .appendingPathComponent(AppleCourseApprovalPolicy.approvedPlanFilename)
        )
        let repository = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID,
            databaseURL: databaseURL,
            rootTitle: brief.title
        )
        try await store.markCourseReadyForLearning(repository: repository, brief: brief)
        let root = try await repository.rootPageSnapshot()
        let generatedPage = await repository.callTool(
            named: NativeEditorMCPToolCatalog.createPages,
            argumentsJSON: try jsonString([
                "parent": ["page_id": root.id],
                "pages": [[
                    "properties": [
                        "title": "Recovered lesson",
                        "course_node_id": "recovered-lesson",
                        "course_role": "lesson",
                        "generation_status": "generated",
                    ],
                    "content": "# Recovered lesson\nReady.",
                ]],
            ])
        )
        XCTAssertFalse(generatedPage.isError)

        await store.recoverReadyCourses(in: coursesRoot)

        let recovered = try XCTUnwrap(store.courses.first(where: {
            $0.workspaceID == workspaceID
        }))
        XCTAssertEqual(recovered.agentServerID, "server-hermes")
        XCTAssertEqual(recovered.agentThreadID, threadID)
        XCTAssertEqual(recovered.agentRuntimeKind, "hermes")
        XCTAssertEqual(recovered.agentModelID, "hermes-model")
        XCTAssertEqual(store.navigationPath, [.course(recovered.id)])
        XCTAssertNil(defaults.data(forKey: CourseExperienceStore.pendingHermesCourseKey))

        // Simulate a second crash after persistCourses but before pending
        // identity cleanup. The known workspace must still reconcile.
        defaults.set(
            try JSONEncoder().encode(identity),
            forKey: CourseExperienceStore.pendingHermesCourseKey
        )
        let relaunched = CourseExperienceStore(defaults: defaults)
        await relaunched.recoverReadyCourses(in: coursesRoot)
        XCTAssertEqual(relaunched.navigationPath, [.course(recovered.id)])
        XCTAssertNil(defaults.data(forKey: CourseExperienceStore.pendingHermesCourseKey))

        relaunched.beginNewCourse()
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.path))
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

        XCTAssertEqual(onDevice.triggerTokens, 2_850)
        XCTAssertEqual(onDevice.summaryTokenLimit, 512)
        XCTAssertEqual(onDevice.responseReserveTokens, 640)
        XCTAssertEqual(onDevice.toolOutputReserveTokens, 384)
        XCTAssertEqual(onDevice.effectiveTrigger(contextSize: 4_096), 2_850)
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
            summaryTokenLimit: 3,
            responseReserveTokens: 2,
            toolOutputReserveTokens: 1
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

    func testOnDeviceToolModeCarriesOnlyTheCurrentWorkflowSchema() {
        XCTAssertEqual(
            AppleCourseToolMode.forTurn(
                providerID: CourseAgentProvider.appleOnDevice,
                hasApprovedPlan: false,
                learnerPrompt: "Teach me Swift actors."
            ),
            .planning
        )
        XCTAssertEqual(
            AppleCourseToolMode.forTurn(
                providerID: CourseAgentProvider.appleOnDevice,
                hasApprovedPlan: true,
                learnerPrompt: "Add an example to the current lesson."
            ),
            .appendingLesson
        )
        XCTAssertEqual(
            AppleCourseToolMode.forTurn(
                providerID: CourseAgentProvider.appleOnDevice,
                hasApprovedPlan: true,
                learnerPrompt: "I approve course plan actor-basics, revision 1. Go ahead."
            ),
            .generatingLesson
        )
        XCTAssertEqual(
            AppleCourseToolMode.forTurn(
                providerID: CourseAgentProvider.appleOnDevice,
                hasApprovedPlan: true,
                learnerPrompt: "Revise the plan to use fewer chapters."
            ),
            .planning
        )
        XCTAssertEqual(
            AppleCourseToolMode.forTurn(
                providerID: CourseAgentProvider.applePrivateCloud,
                hasApprovedPlan: true,
                learnerPrompt: "Add an example."
            ),
            .full
        )
    }

    func testGeneratedLessonValidatorRejectsNonActorAndTruncatedSwift() {
        XCTAssertNotNil(
            AppleCourseGeneratedLessonValidator.swiftCodeIssue(
                "struct Counter { var value = 0 }"
            )
        )
        XCTAssertNotNil(
            AppleCourseGeneratedLessonValidator.swiftCodeIssue(
                "actor Counter { func increment() { print("
            )
        )
        XCTAssertNil(
            AppleCourseGeneratedLessonValidator.swiftCodeIssue(
                """
                actor Counter {
                    private var value = 0

                    func increment() -> Int {
                        value += 1
                        return value
                    }
                }
                """
            )
        )
        XCTAssertEqual(
            AppleCourseGeneratedLessonValidator.validatedSwiftCode(
                "struct Counter { var value = 0 }"
            ),
            AppleCourseGeneratedLessonValidator.safeActorExample
        )
    }

    func testPrivateCloudCancellationRetriesRemainBoundedForMutationFreeTurns() {
        XCTAssertTrue(
            AppleCourseGenerationRetryPolicy.canRetryCancellation(
                retryCount: 0,
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertTrue(
            AppleCourseGenerationRetryPolicy.canRetryCancellation(
                retryCount: 1,
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertFalse(
            AppleCourseGenerationRetryPolicy.canRetryCancellation(
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
            AppleCourseGenerationRetryPolicy.canRetryCancellation(
                retryCount: 0,
                taskWasCancelled: false,
                latestResponse: "Partial",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertFalse(
            AppleCourseGenerationRetryPolicy.canRetryCancellation(
                retryCount: 0,
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: true,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertFalse(
            AppleCourseGenerationRetryPolicy.canRetryCancellation(
                retryCount: 0,
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: true
            )
        )
        XCTAssertFalse(
            AppleCourseGenerationRetryPolicy.canRetryCancellation(
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
            AppleCourseGenerationRetryPolicy.mutationFreeAttemptTimeout,
            .seconds(90)
        )
        XCTAssertTrue(
            AppleCourseGenerationRetryPolicy.canCancelHungAttempt(
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertFalse(
            AppleCourseGenerationRetryPolicy.canCancelHungAttempt(
                taskWasCancelled: false,
                latestResponse: "partial",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertFalse(
            AppleCourseGenerationRetryPolicy.canCancelHungAttempt(
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: true,
                didAttemptEditorMutation: false
            )
        )
        XCTAssertFalse(
            AppleCourseGenerationRetryPolicy.canCancelHungAttempt(
                taskWasCancelled: false,
                latestResponse: "",
                didPresentCoursePlan: false,
                didAttemptEditorMutation: true
            )
        )
    }

#if canImport(FoundationModels)
    func testAppleOnDeviceRuntimeLiveSmoke() async throws {
        guard #available(iOS 26.4, *) else {
            throw XCTSkip("Exact Foundation Models context APIs require iOS 26.4 or later.")
        }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw XCTSkip("Apple On-Device is unavailable: \(model.availability)")
        }

        let prompt = """
        Make a one-chapter beginner course plan about Swift actors and present it for my approval.
        """
        let promptTokens = try await model.tokenCount(for: prompt)
        XCTAssertGreaterThan(model.contextSize, promptTokens)

        let runtime = SystemAppleCourseAgentRuntime()
        let sessionID = UUID()
        let workspaceID = "local-model-e2e-swift-actors-\(sessionID.uuidString.lowercased())"
        let store = CourseExperienceStore(
            defaults: try makeDefaults(),
            environment: ["SNAPPY_SKIP_AGENT_SETUP": "1"],
            appleRuntime: runtime
        )
        let courseDirectory = store.courseDatabaseURL(workspaceID: workspaceID)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coursesRoot = courseDirectory.deletingLastPathComponent()
        if let priorLiveSmokeDirectories = try? FileManager.default.contentsOfDirectory(
            at: coursesRoot,
            includingPropertiesForKeys: nil
        ) {
            for priorDirectory in priorLiveSmokeDirectories where
                priorDirectory.lastPathComponent.hasPrefix("local-model-e2e-swift-actors-")
            {
                try? FileManager.default.removeItem(at: priorDirectory)
            }
        }
        try? FileManager.default.removeItem(at: courseDirectory)
        var latestResponse = ""
        var presentedPlans: [CourseBrief] = []
        defer {
            runtime.remove(sessionID: sessionID, workspaceID: workspaceID)
        }

        try await runtime.send(
            sessionID: sessionID,
            providerID: CourseAgentProvider.appleOnDevice,
            workspaceID: workspaceID,
            prompt: prompt,
            onPartialResponse: { latestResponse = $0 },
            onCoursePlan: { plan in
                presentedPlans.append(plan)
            }
        )

        XCTAssertEqual(presentedPlans.count, 1)
        XCTAssertEqual(presentedPlans.first?.chapters.count, 1)
        XCTAssertFalse(latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let plan = try XCTUnwrap(presentedPlans.first)
        let metadataDirectory = courseDirectory.appendingPathComponent(".course", isDirectory: true)
        try FileManager.default.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true
        )
        let planData = try JSONEncoder().encode(plan)
        try planData.write(
            to: metadataDirectory.appendingPathComponent(
                AppleCourseApprovalPolicy.presentedPlanFilename
            ),
            options: .atomic
        )
        try planData.write(
            to: metadataDirectory.appendingPathComponent(
                AppleCourseApprovalPolicy.approvedPlanFilename
            ),
            options: .atomic
        )
        XCTAssertTrue(
            AppleCourseApprovalPolicy.isLatestPlanApproved(courseDirectory: courseDirectory)
        )

        _ = try await store.prepareApprovedCourseShell(
            brief: plan,
            workspaceID: workspaceID
        )
        latestResponse = ""
        let firstChapter = try XCTUnwrap(plan.chapters.first)
        try await runtime.send(
            sessionID: sessionID,
            providerID: CourseAgentProvider.appleOnDevice,
            workspaceID: workspaceID,
            prompt: """
            I approve course plan \(plan.planID), revision \(plan.revision). Learnfold has already \
            created the learner context pages, the chapter folder, and one pending lesson page for \
            \(firstChapter.title). Use learnfold_generate_lesson exactly once, replacing the current \
            lesson content with a concise but complete beginner lesson of at most 120 words containing \
            an explanation, one small compiling Swift example, and one short exercise. Mark it \
            generated. Do not recreate the course structure.
            """,
            onPartialResponse: { latestResponse = $0 },
            onCoursePlan: { _ in
                XCTFail("An approved course turn must use only the editor tool schema.")
            }
        )
        XCTAssertFalse(latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let repository = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID,
            databaseURL: store.courseDatabaseURL(workspaceID: workspaceID),
            rootTitle: plan.title
        )
        var outline = try await repository.outline()
        let lessonNodeID = "\(firstChapter.id)-lesson-1"
        let generatedLessonNode = try XCTUnwrap(
            flattenCourseNodes(outline.learningPages).first(where: { $0.id == lessonNodeID })
        )
        XCTAssertEqual(generatedLessonNode.status, .generated)
        let lessonPageID = try XCTUnwrap(generatedLessonNode.pageID)
        let generatedLesson = try await repository.pageSnapshot(id: lessonPageID)
        let generatedMarkdown = AppFlowyMarkdownCodec().encode(generatedLesson.document)
        XCTAssertTrue(generatedMarkdown.contains("actor"))
        XCTAssertTrue(generatedMarkdown.contains("```swift"))
        let generatedCode = generatedMarkdown
            .components(separatedBy: "```swift")
            .dropFirst()
            .first?
            .components(separatedBy: "```")
            .first ?? ""
        XCTAssertNil(AppleCourseGeneratedLessonValidator.swiftCodeIssue(generatedCode))

        let editMarker = "Prefer one actor per independently mutable subsystem."
        latestResponse = ""
        try await runtime.send(
            sessionID: sessionID,
            providerID: CourseAgentProvider.appleOnDevice,
            workspaceID: workspaceID,
            prompt: """
            Edit the generated lesson for \(firstChapter.title). Fetch it immediately, then append \
            a section titled "Actor Design Rule" containing exactly this sentence: "\(editMarker)" \
            Use learnfold_append_lesson_section exactly once, appending the new section to the current \
            lesson without marking generation status again. Do not change any other page.
            """,
            onPartialResponse: { latestResponse = $0 },
            onCoursePlan: { _ in
                XCTFail("Editing an approved course must not present another plan.")
            }
        )
        XCTAssertFalse(latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let editedLesson = try await repository.pageSnapshot(id: lessonPageID)
        let editedMarkdown = AppFlowyMarkdownCodec().encode(editedLesson.document)
        XCTAssertGreaterThan(editedLesson.revision, generatedLesson.revision)
        XCTAssertTrue(editedMarkdown.contains("Actor Design Rule"))
        XCTAssertTrue(editedMarkdown.contains(editMarker))
        try await store.markCourseReadyForLearning(repository: repository, brief: plan)

        outline = try await repository.outline()
        XCTAssertTrue(outline.isReadyForLearning)
        let relaunchedStore = CourseExperienceStore(
            defaults: try makeDefaults(),
            environment: ["SNAPPY_SKIP_AGENT_SETUP": "1"]
        )
        await relaunchedStore.recoverReadyCourses(
            in: courseDirectory.deletingLastPathComponent()
        )
        XCTAssertTrue(relaunchedStore.courses.contains { $0.workspaceID == workspaceID })

        let messages = await runtime.restoredMessages(
            sessionID: sessionID,
            workspaceID: workspaceID
        )
        XCTAssertEqual(
            messages.map(\.role),
            [.learner, .agent, .learner, .agent, .learner, .agent]
        )
    }

    func testAppleLiveSessionCallbacksRebindForApprovedTurn() async throws {
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

        try await callbacks.presentCoursePlan(plan)
        callbacks.recordEditorMutationAttempt()
        callbacks.rebind(
            onCoursePlan: { _ in approvedPlanCount += 1 },
            onEditorMutationAttempt: { approvedMutationCount += 1 }
        )
        try await callbacks.presentCoursePlan(plan)
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

    func testCourseMCPReturnsActionableErrorThenAcceptsCorrectedPlan() async throws {
        let workspaceID = "mcp-plan-validation-\(UUID().uuidString)"
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apps/Courses/\(workspaceID)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let invalidRequest = JSONValue.object([
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": [
                "name": .string(CourseAgentTools.presentPlan),
                "arguments": [
                    CourseAgentTools.workspaceIDArgument: .string(workspaceID),
                    "plan_id": "swift-concurrency",
                    "revision": 1,
                    "title": "Swift Concurrency",
                ],
            ],
        ])
        let invalidResponse = await CourseMCPProtocol.handleJSONRPC(
            body: try JSONEncoder().encode(invalidRequest)
        )
        let invalidBody = try XCTUnwrap(invalidResponse.body)
        let invalidJSON = try JSONDecoder().decode(JSONValue.self, from: invalidBody)
        let invalidResult = try XCTUnwrap(
            invalidJSON.objectValue?["result"]?.objectValue
        )
        let invalidMessage = try XCTUnwrap(
            invalidResult["structuredContent"]?.objectValue?["error"]?.stringValue
        )

        XCTAssertEqual(invalidResult["isError"]?.boolValue, true)
        XCTAssertTrue(invalidMessage.contains("required field 'summary' is missing"))
        XCTAssertTrue(invalidMessage.contains("call present_course_plan again"))
        XCTAssertTrue(invalidMessage.contains("Do not ask the learner to approve"))

        let correctedRequest = JSONValue.object([
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": [
                "name": .string(CourseAgentTools.presentPlan),
                "arguments": [
                    CourseAgentTools.workspaceIDArgument: .string(workspaceID),
                    "plan_id": "swift-concurrency",
                    "revision": 1,
                    "title": "Swift Concurrency",
                    "summary": "Learn concurrency by building a small app.",
                    "outcome": "Use tasks, actors, and cancellation safely.",
                    "starting_point": "Comfortable with basic Swift.",
                    "focus_gap": "Reasoning about isolation and cancellation.",
                    "estimated_duration": "3h 30m",
                    "chapters": .array([
                        [
                            "id": "tasks",
                            "title": "Tasks",
                            "objective": "Understand structured task lifetimes.",
                            "deliverables": ["lesson", "exercise"],
                        ]
                    ]),
                ],
            ],
        ])
        let correctedResponse = await CourseMCPProtocol.handleJSONRPC(
            body: try JSONEncoder().encode(correctedRequest)
        )
        let correctedBody = try XCTUnwrap(correctedResponse.body)
        let correctedJSON = try JSONDecoder().decode(JSONValue.self, from: correctedBody)
        let correctedResult = try XCTUnwrap(
            correctedJSON.objectValue?["result"]?.objectValue
        )

        XCTAssertEqual(correctedResult["isError"]?.boolValue, false)
        XCTAssertEqual(
            correctedResult["structuredContent"]?.objectValue?["plan_id"]?.stringValue,
            "swift-concurrency"
        )
    }

    func testCourseMCPPlanErrorIdentifiesInvalidNestedField() async throws {
        let workspaceID = "mcp-plan-nested-\(UUID().uuidString)"
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apps/Courses/\(workspaceID)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = JSONValue.object([
            "jsonrpc": "2.0",
            "id": 6,
            "method": "tools/call",
            "params": [
                "name": .string(CourseAgentTools.presentPlan),
                "arguments": [
                    CourseAgentTools.workspaceIDArgument: .string(workspaceID),
                    "plan_id": "swift-concurrency",
                    "revision": 1,
                    "title": "Swift Concurrency",
                    "summary": "Learn concurrency by building a small app.",
                    "outcome": "Use tasks safely.",
                    "starting_point": "Comfortable with basic Swift.",
                    "focus_gap": "Reasoning about isolation.",
                    "estimated_duration": "3h 30m",
                    "chapters": .array([
                        [
                            "id": "tasks",
                            "title": "Tasks",
                            "objective": "Understand structured task lifetimes.",
                            "deliverables": "lesson",
                        ]
                    ]),
                ],
            ],
        ])
        let response = await CourseMCPProtocol.handleJSONRPC(
            body: try JSONEncoder().encode(request)
        )
        let body = try XCTUnwrap(response.body)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: body)
        let result = try XCTUnwrap(decoded.objectValue?["result"]?.objectValue)
        let message = try XCTUnwrap(
            result["structuredContent"]?.objectValue?["error"]?.stringValue
        )

        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertTrue(message.contains("field 'chapters[0].deliverables' has the wrong type"))
        XCTAssertTrue(message.contains("call present_course_plan again"))
    }

    func testCourseMCPRejectsSemanticallyEmptyPlanContent() async throws {
        let workspaceID = "mcp-plan-semantic-\(UUID().uuidString)"
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apps/Courses/\(workspaceID)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = JSONValue.object([
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": [
                "name": .string(CourseAgentTools.presentPlan),
                "arguments": [
                    CourseAgentTools.workspaceIDArgument: .string(workspaceID),
                    "plan_id": "swift-concurrency",
                    "revision": 1,
                    "title": "Swift Concurrency",
                    "summary": "Learn concurrency by building a small app.",
                    "outcome": "Use tasks safely.",
                    "starting_point": "Comfortable with basic Swift.",
                    "focus_gap": "Reasoning about isolation.",
                    "estimated_duration": "3h 30m",
                    "chapters": .array([
                        [
                            "id": "tasks",
                            "title": "Tasks",
                            "objective": "Understand structured task lifetimes.",
                            "deliverables": ["   "],
                        ]
                    ]),
                ],
            ],
        ])
        let response = await CourseMCPProtocol.handleJSONRPC(
            body: try JSONEncoder().encode(request)
        )
        let body = try XCTUnwrap(response.body)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: body)
        let result = try XCTUnwrap(decoded.objectValue?["result"]?.objectValue)
        let message = try XCTUnwrap(
            result["structuredContent"]?.objectValue?["error"]?.stringValue
        )

        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertTrue(
            message.contains("field 'chapters[0].deliverables[0]' must be a non-empty string")
        )
        XCTAssertTrue(message.contains("call present_course_plan again"))
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

    func testCourseChatPartialLiveSnapshotCannotEraseLocalTranscript() {
        let firstLearner = CourseChatMessage(role: .learner, text: "Explain actors.")
        let firstAgent = CourseChatMessage(role: .agent, text: "Actors protect isolated state.")
        let latestLearner = CourseChatMessage(role: .learner, text: "What about reentrancy?")
        let partialLiveItems = [
            ConversationItem(
                id: "remote-latest-user",
                content: .user(
                    ConversationUserMessageData(
                        text: "What about reentrancy?",
                        images: []
                    )
                )
            )
        ]

        let merged = CourseChatTimelinePolicy.mergedConversationItems(
            localMessages: [firstLearner, firstAgent, latestLearner],
            liveItems: partialLiveItems
        )

        XCTAssertEqual(messageTexts(in: merged), [
            "Explain actors.",
            "Actors protect isolated state.",
            "What about reentrancy?",
        ])
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(
            merged.last?.id,
            "course-local-\(latestLearner.id.uuidString.lowercased())"
        )
    }

    func testCourseChatCanonicalItemsReplaceMatchingFallbacksWithStableIDs() {
        let learner = CourseChatMessage(role: .learner, text: "Why does await yield?")
        let agent = CourseChatMessage(role: .agent, text: "It suspends the current task.")
        let liveItems = [
            ConversationItem(
                id: "remote-user",
                content: .user(
                    ConversationUserMessageData(text: learner.text, images: [])
                )
            ),
            ConversationItem(
                id: "remote-agent",
                content: .assistant(
                    ConversationAssistantMessageData(
                        text: "It suspends the current task. More detail follows.",
                        agentNickname: nil,
                        agentRole: nil,
                        phase: nil
                    )
                )
            ),
        ]

        let merged = CourseChatTimelinePolicy.mergedConversationItems(
            localMessages: [learner, agent],
            liveItems: liveItems
        )

        XCTAssertEqual(merged.map(\.id), [
            "course-local-\(learner.id.uuidString.lowercased())",
            "course-local-\(agent.id.uuidString.lowercased())",
        ])
        XCTAssertEqual(messageTexts(in: merged), [
            "Why does await yield?",
            "It suspends the current task. More detail follows.",
        ])
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
        XCTAssertFalse(CourseChatTimelinePolicy.isAgentWorking(
            requestPending: false,
            threadHasActiveTurn: true,
            usesDurableHermesLifecycle: true,
            durableHermesRecoveryPending: false
        ))
        XCTAssertTrue(CourseChatTimelinePolicy.isAgentWorking(
            requestPending: false,
            threadHasActiveTurn: false,
            usesDurableHermesLifecycle: true,
            durableHermesRecoveryPending: true
        ))
    }

    func testCourseChatRunRegistryScopesMainAndSelectionIndependently() throws {
        var registry = CourseChatRunRegistry()
        let discussionID = UUID()
        let mainToken = try XCTUnwrap(registry.begin(.main))
        let discussionToken = try XCTUnwrap(registry.begin(.selection(discussionID)))

        XCTAssertEqual(registry.phase(for: .main), .submitting)
        XCTAssertEqual(registry.phase(for: .selection(discussionID)), .submitting)
        XCTAssertTrue(registry.transition(.main, token: mainToken, to: .running))
        XCTAssertTrue(registry.finish(.selection(discussionID), token: discussionToken))

        XCTAssertEqual(registry.phase(for: .main), .running)
        XCTAssertEqual(registry.phase(for: .selection(discussionID)), .idle)
        XCTAssertTrue(registry.hasActiveRun)
    }

    func testCourseChatRunRegistryRejectsStaleCompletionAfterRetry() throws {
        var registry = CourseChatRunRegistry()
        let firstToken = try XCTUnwrap(registry.begin(.main))
        XCTAssertTrue(registry.transition(
            .main,
            token: firstToken,
            to: .failed("Network failed")
        ))
        let retryToken = try XCTUnwrap(registry.begin(.main))

        XCTAssertFalse(registry.finish(.main, token: firstToken))
        XCTAssertEqual(registry.token(for: .main), retryToken)
        XCTAssertEqual(registry.phase(for: .main), .submitting)
    }

    func testCourseChatRunRegistryStopFailureIsTerminalNotPending() throws {
        var registry = CourseChatRunRegistry()
        _ = try XCTUnwrap(registry.begin(.main))
        let stopToken = registry.beginStopping(.main)

        XCTAssertTrue(registry.transition(
            .main,
            token: stopToken,
            to: .failed("Interrupt failed")
        ))
        XCTAssertFalse(registry.phase(for: .main).isWorking)
        XCTAssertFalse(registry.hasActiveRun)
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

    func testRemoteHermesIdlePolicyUsesAuthoritativeTurnsWhenSnapshotIsMissingOrStale() {
        XCTAssertTrue(RemoteHermesThreadIdlePolicy.isIdle(
            localHasActiveTurn: nil,
            authoritativeTurns: []
        ))
        XCTAssertTrue(RemoteHermesThreadIdlePolicy.isIdle(
            localHasActiveTurn: true,
            authoritativeTurns: [
                AppTurnState(turnId: "done", status: .completed, errorMessage: nil)
            ]
        ))
        XCTAssertFalse(RemoteHermesThreadIdlePolicy.isIdle(
            localHasActiveTurn: nil,
            authoritativeTurns: [
                AppTurnState(turnId: "running", status: .inProgress, errorMessage: nil)
            ]
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
        XCTAssertTrue(instructions.contains("complete ordered chapter, subchapter, and lesson page hierarchy"))
        XCTAssertTrue(instructions.contains("must exist as its own clearly titled native page"))
        XCTAssertTrue(instructions.contains("pending_generation"))
        XCTAssertTrue(instructions.contains("Folder status is a strict roll-up"))
        XCTAssertTrue(instructions.contains("Never leave a folder `pending_generation` when all of its children are generated"))
        XCTAssertTrue(instructions.contains("bootstrap_status` to `ready_for_learning`"))
        XCTAssertTrue(instructions.contains("mark only that page `generating`"))
        XCTAssertTrue(instructions.contains("A selected-passage question"))
        XCTAssertTrue(instructions.contains("Answer only in chat"))
        XCTAssertTrue(instructions.contains("Add or revise a focused section"))
        XCTAssertTrue(instructions.contains("Create an `explainer` child page"))
        XCTAssertTrue(instructions.contains("Do not edit merely because editing tools are available"))
        XCTAssertTrue(instructions.contains("expected_revision"))
        XCTAssertTrue(instructions.contains("Never create Markdown lesson files"))
    }

    func testAppleInstructionsRequireVisiblePendingHierarchyAndFolderRollup() {
        let instructions = SystemAppleCourseAgentRuntime.courseHierarchyInstructions

        XCTAssertTrue(instructions.contains("own clearly titled native page"))
        XCTAssertTrue(instructions.contains("pending_generation when every child is pending"))
        XCTAssertTrue(instructions.contains("partially_generated when child states are mixed"))
        XCTAssertTrue(instructions.contains("never leave a folder pending_generation"))
    }

    func testAppleCourseShellCreatesEveryPlannedLessonTitleBeforeGeneration() async throws {
        let defaults = try makeDefaults()
        let coursesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleCourseShellTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: coursesRoot) }
        let workspaceID = UUID().uuidString.lowercased()
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: ["SNAPPY_SKIP_AGENT_SETUP": "1"],
            coursesRootURL: coursesRoot
        )
        var plan = CourseBrief()
        plan.planID = "visible-apple-outline"
        plan.revision = 1
        plan.title = "Visible Apple Outline"
        plan.chapters = [
            CourseChapter(
                id: "foundations",
                title: "Foundations",
                objective: "Build the foundation.",
                deliverables: ["Core idea", "Guided exercise"]
            ),
            CourseChapter(
                id: "application",
                title: "Application",
                objective: "Apply the idea.",
                deliverables: ["Worked example", "Independent practice"]
            ),
        ]
        let metadataDirectory = store.courseDatabaseURL(workspaceID: workspaceID)
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true
        )
        let planData = try JSONEncoder().encode(plan)
        try planData.write(
            to: metadataDirectory.appendingPathComponent(
                AppleCourseApprovalPolicy.presentedPlanFilename
            )
        )
        try planData.write(
            to: metadataDirectory.appendingPathComponent(
                AppleCourseApprovalPolicy.approvedPlanFilename
            )
        )

        let target = try await store.prepareApprovedCourseShell(
            brief: plan,
            workspaceID: workspaceID
        )
        let repository = try await store.documentRepository(
            for: LearningCourse(
                id: plan.planID,
                title: plan.title,
                subtitle: "",
                accentHex: "000000",
                progress: 0,
                lessonCount: 4,
                duration: "Adaptive",
                status: .ready,
                workspaceID: workspaceID
            )
        )
        let outline = try await repository.outline()

        XCTAssertEqual(target.nodeID, "foundations-lesson-1")
        XCTAssertEqual(outline.learningPages.map(\.status), [.pendingGeneration, .pendingGeneration])
        XCTAssertEqual(
            outline.learningPages[0].children.map(\.title),
            ["1.1 · Core idea", "1.2 · Guided exercise"]
        )
        XCTAssertEqual(
            outline.learningPages[1].children.map(\.title),
            ["2.1 · Worked example", "2.2 · Independent practice"]
        )
        XCTAssertTrue(
            outline.learningPages
                .flatMap(\.children)
                .allSatisfy { $0.status == .pendingGeneration }
        )

        let laterLesson = outline.learningPages[1].children[1]
        try await store.persistAppleGenerationTarget(
            for: laterLesson,
            workspaceID: workspaceID
        )
        let persistedTargetData = try Data(contentsOf: metadataDirectory.appendingPathComponent(
            AppleCourseApprovalPolicy.lessonTargetFilename
        ))
        let persistedTarget = try JSONDecoder().decode(
            PreparedCourseLessonTarget.self,
            from: persistedTargetData
        )
        XCTAssertEqual(persistedTarget.nodeID, "application-lesson-2")
        XCTAssertEqual(persistedTarget.pageID, laterLesson.pageID)
        XCTAssertNotEqual(persistedTarget.pageID, target.pageID)
    }

    @MainActor
    func testGenerationControlsUseTitledLeafPagesAndDoNotOfferAppleFolderGeneration() {
        let pendingLesson = CourseLearningNode(
            id: "lesson-2",
            title: "1.2 · Guided exercise",
            kind: .markdown,
            status: .pendingGeneration,
            pageID: "page-lesson-2"
        )
        let pendingChapter = CourseLearningNode(
            id: "chapter-1",
            title: "Foundations",
            kind: .folder,
            status: .pendingGeneration,
            pageID: "page-chapter-1",
            children: [pendingLesson]
        )
        let legacyEmptyChapter = CourseLearningNode(
            id: "legacy-chapter",
            title: "Legacy chapter",
            kind: .folder,
            status: .pendingGeneration,
            pageID: "page-legacy-chapter"
        )

        XCTAssertTrue(CourseExperienceStore.allowsDirectGeneration(
            of: pendingLesson,
            runtimeID: CourseAgentProvider.appleOnDevice
        ))
        XCTAssertFalse(CourseExperienceStore.allowsDirectGeneration(
            of: pendingChapter,
            runtimeID: CourseAgentProvider.appleOnDevice
        ))
        XCTAssertTrue(CourseExperienceStore.allowsDirectGeneration(
            of: pendingChapter,
            runtimeID: CourseAgentProvider.codex
        ))
        XCTAssertFalse(CourseExperienceStore.allowsDirectGeneration(
            of: legacyEmptyChapter,
            runtimeID: CourseAgentProvider.applePrivateCloud
        ))
        XCTAssertTrue(CourseExperienceStore.allowsDirectGeneration(
            of: legacyEmptyChapter,
            runtimeID: CourseAgentProvider.codex
        ))
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
        XCTAssertTrue(prompt.contains("titled native page for every planned child"))
        XCTAssertTrue(prompt.contains("never leave a folder pending_generation when all of its children are generated"))
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

    func testPersistedCourseThreadIsImmediatelyRestorableAfterRelaunch() throws {
        let threadID = UUID().uuidString.lowercased()
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
            agentServerID: "personal-claw",
            agentThreadID: threadID,
            agentRuntimeKind: "hermes"
        )

        XCTAssertEqual(
            CourseExperienceStore.persistedAgentThreadKey(for: course),
            ThreadKey(serverId: "personal-claw", threadId: threadID)
        )
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

    func testRemoteCourseToolCallRequiresOneBareAllowlistedEnvelope() throws {
        let response = """
        {"learnfold_tool_call":{"name":"present_course_plan","arguments":{"workspace_id":"workspace-1","plan_id":"swift-actors","revision":1,"title":"Swift Actors","chapters":[{"id":"one","title":"Foundations","objective":"Understand { isolation }","deliverables":[]}]}}}
        """

        let call = try XCTUnwrap(CourseExperienceStore.remoteCourseToolCall(from: response))
        XCTAssertEqual(call.name, "present_course_plan")
        XCTAssertEqual(call.visibleText, "")
        let arguments = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(call.argumentsJSON.data(using: .utf8))
            ) as? [String: Any]
        )
        XCTAssertEqual(arguments["workspace_id"] as? String, "workspace-1")
        XCTAssertEqual(arguments["plan_id"] as? String, "swift-actors")

        XCTAssertNil(CourseExperienceStore.remoteCourseToolCall(from: "Introduction\n\(response)"))
        XCTAssertNil(CourseExperienceStore.remoteCourseToolCall(from: "```json\n\(response)\n```"))
        XCTAssertTrue(
            CourseExperienceStore.looksLikeMalformedRemoteCourseToolEnvelope(
                "Introduction\n\(response)"
            )
        )
        XCTAssertTrue(
            CourseExperienceStore.looksLikeMalformedRemoteCourseToolEnvelope(
                "```json\n\(response)\n```"
            )
        )

        let updateWithFencedMarkdown = ##"{"learnfold_tool_call":{"name":"native-editor-update-page","arguments":{"workspace_id":"workspace-1","page_id":"page-1","command":"replace_content","new_str":"# Example\n```swift\nprint(\"blue\")\n```"}}}"##
        let updateCall = try XCTUnwrap(
            CourseExperienceStore.remoteCourseToolCall(from: updateWithFencedMarkdown)
        )
        XCTAssertEqual(updateCall.name, "native-editor-update-page")
        XCTAssertTrue(updateCall.argumentsJSON.contains("```swift"))

        XCTAssertNil(CourseExperienceStore.remoteCourseToolCall(
            from: #"{"learnfold_tool_call":{"name":"shell_command","arguments":{}}}"#
        ))
        XCTAssertNil(CourseExperienceStore.remoteCourseToolCall(
            from: #"{"learnfold_tool_call":{"name":"present_course_plan","arguments":{}},"extra":true}"#
        ))
    }

    func testRemoteCourseToolCallRejectsMalformedEnvelope() {
        let missingArguments = #"{"learnfold_tool_call":{"name":"native-editor-fetch"}}"#
        XCTAssertNil(CourseExperienceStore.remoteCourseToolCall(from: missingArguments))
        XCTAssertTrue(
            CourseExperienceStore.looksLikeMalformedRemoteCourseToolEnvelope(missingArguments)
        )
        let missingClosingBrace = #"{"learnfold_tool_call":{"name":"native-editor-update-page","arguments":{"workspace_id":"workspace-1","page_id":"page-1","command":"update_content","expected_revision":1,"content_updates":[],"properties":{"generation_status":"generated"}}}"#
        XCTAssertNil(CourseExperienceStore.remoteCourseToolCall(from: missingClosingBrace))
        XCTAssertTrue(
            CourseExperienceStore.looksLikeMalformedRemoteCourseToolEnvelope(missingClosingBrace)
        )
        XCTAssertNil(
            CourseExperienceStore.remoteCourseToolCall(
                from: #"{"tool_call":{"name":"native-editor-fetch","arguments":{}}}"#
            )
        )
        XCTAssertFalse(
            CourseExperienceStore.looksLikeMalformedRemoteCourseToolEnvelope(
                #"{"tool_call":{"name":"native-editor-fetch","arguments":{}}}"#
            )
        )
        XCTAssertFalse(
            CourseExperienceStore.looksLikeMalformedRemoteCourseToolEnvelope(
                "Hermes finished the lesson without requesting another tool."
            )
        )
    }

    func testRemoteHermesToolResultCorrelatesLocalResultToWorkspaceAndSourceTurn() throws {
        let call = RemoteCourseToolCall(
            name: "native-editor-fetch",
            argumentsJSON: #"{"workspace_id":"workspace-1","page_id":"page-1"}"#,
            visibleText: ""
        )
        let prompt = try CourseExperienceStore.remoteHermesToolResultPrompt(
            call: call,
            result: AppPlatformDynamicToolResult(
                success: true,
                output: #"{"object":"page","id":"page-1","revision":7}"#
            ),
            workspaceID: "workspace-1",
            sourceTurnID: "turn-tool-call",
            callID: "call-native-fetch"
        )
        let envelope = try XCTUnwrap(prompt.split(separator: "\n").first)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        )
        let result = try XCTUnwrap(root["learnfold_tool_result"] as? [String: Any])

        XCTAssertEqual(result["name"] as? String, "native-editor-fetch")
        XCTAssertEqual(result["workspace_id"] as? String, "workspace-1")
        XCTAssertEqual(result["source_turn_id"] as? String, "turn-tool-call")
        XCTAssertEqual(result["call_id"] as? String, "call-native-fetch")
        XCTAssertEqual(result["executed_on"] as? String, "mobile_device")
        XCTAssertEqual(result["success"] as? Bool, true)
        XCTAssertEqual(
            result["output"] as? String,
            #"{"object":"page","id":"page-1","revision":7}"#
        )
    }

    func testRemoteHermesPresentedPlanResultPausesForLearnerApproval() throws {
        let prompt = try CourseExperienceStore.remoteHermesToolResultPrompt(
            call: RemoteCourseToolCall(
                name: CourseAgentTools.presentPlan,
                argumentsJSON: #"{"workspace_id":"workspace-1"}"#,
                visibleText: ""
            ),
            result: AppPlatformDynamicToolResult(
                success: true,
                output: "Learnfold displayed the plan."
            ),
            workspaceID: "workspace-1",
            sourceTurnID: "turn-plan",
            callID: "call-present-plan"
        )
        let envelope = try XCTUnwrap(prompt.split(separator: "\n").first)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        )
        let result = try XCTUnwrap(root["learnfold_tool_result"] as? [String: Any])

        XCTAssertEqual(result["approval_status"] as? String, "pending")
        XCTAssertTrue(prompt.contains("Do not call another course tool"))
    }

    func testRemoteHermesDeveloperInstructionsFitBridgeLimitAndPersistDeviceBoundary() throws {
        let instructions = try CourseExperienceStore.remoteHermesDeveloperInstructions(
            workspaceID: "workspace-contract"
        )

        XCTAssertLessThanOrEqual(instructions.lengthOfBytes(using: .utf8), 60 * 1024)
        for required in [
            "learnfold_tool_call",
            "executed_on",
            "mobile_device",
            "workspace_id",
            "workspace-contract",
            "Available Learnfold tools",
            "untrusted data",
            "Never use VPS filesystem",
        ] {
            XCTAssertTrue(instructions.contains(required), "Missing \(required)")
        }
    }

    func testOversizedHermesMutationReceiptNeverReportsCommittedWorkAsFailed() throws {
        let oversized = String(repeating: "x", count: 61 * 1024)
        let mutationPrompt = try CourseExperienceStore.remoteHermesToolResultPrompt(
            call: RemoteCourseToolCall(
                name: NativeEditorMCPToolCatalog.updatePage,
                argumentsJSON: #"{"workspace_id":"workspace-1"}"#,
                visibleText: ""
            ),
            result: AppPlatformDynamicToolResult(success: true, output: oversized),
            workspaceID: "workspace-1",
            sourceTurnID: "turn-mutation",
            callID: "call-mutation"
        )
        let mutationEnvelope = try XCTUnwrap(mutationPrompt.split(separator: "\n").first)
        let mutationRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(mutationEnvelope.utf8)) as? [String: Any]
        )
        let mutationResult = try XCTUnwrap(
            mutationRoot["learnfold_tool_result"] as? [String: Any]
        )
        XCTAssertEqual(mutationResult["success"] as? Bool, true)
        XCTAssertTrue((mutationResult["output"] as? String)?.contains("Do not retry") == true)

        let readPrompt = try CourseExperienceStore.remoteHermesToolResultPrompt(
            call: RemoteCourseToolCall(
                name: NativeEditorMCPToolCatalog.fetch,
                argumentsJSON: #"{"workspace_id":"workspace-1"}"#,
                visibleText: ""
            ),
            result: AppPlatformDynamicToolResult(success: true, output: oversized),
            workspaceID: "workspace-1",
            sourceTurnID: "turn-read",
            callID: "call-read"
        )
        let readEnvelope = try XCTUnwrap(readPrompt.split(separator: "\n").first)
        let readRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(readEnvelope.utf8)) as? [String: Any]
        )
        let readResult = try XCTUnwrap(readRoot["learnfold_tool_result"] as? [String: Any])
        XCTAssertEqual(readResult["success"] as? Bool, false)
        XCTAssertTrue((readResult["output"] as? String)?.contains("narrower read") == true)
    }

    func testHermesCourseTurnsUseSupportedSandboxAndRejectRichAttachmentsUpFront() {
        XCTAssertEqual(
            CourseExperienceStore.courseTurnSandboxPolicy(runtimeID: "hermes"),
            TurnSandboxPolicy.dangerFullAccess.ffiValue
        )
        XCTAssertEqual(
            CourseExperienceStore.courseTurnSandboxPolicy(runtimeID: "codex"),
            TurnSandboxPolicy.workspaceWrite.ffiValue
        )
        let image = CourseSource(
            name: "diagram.png",
            detail: "image",
            kind: .image,
            runtimePath: "/tmp/diagram.png",
            image: nil
        )
        XCTAssertNotNil(
            CourseExperienceStore.unsupportedHermesSourceMessage(
                runtimeID: "hermes",
                sources: [image]
            )
        )
        XCTAssertNil(
            CourseExperienceStore.unsupportedHermesSourceMessage(
                runtimeID: "codex",
                sources: [image]
            )
        )
        XCTAssertNil(
            CourseExperienceStore.unsupportedHermesSourceMessage(
                runtimeID: "hermes",
                sources: [
                    CourseSource(
                        name: "https://example.com/course",
                        detail: "link",
                        kind: .link,
                        runtimePath: nil,
                        image: nil
                    )
                ]
            )
        )
    }

    func testRemoteHermesToolJournalPersistsExactExecutionAndResultTurnIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = RemoteHermesToolJournal(
            fileURL: directory.appendingPathComponent("remote-hermes-tool-journal.json")
        )
        var entry = RemoteHermesToolJournalEntry(
            id: "call-1",
            workspaceID: "workspace-1",
            threadID: "thread-1",
            sourceTurnID: "turn-tool-call",
            toolName: "native-editor-patch",
            argumentsJSON: #"{"workspace_id":"workspace-1","page_id":"page-1"}"#,
            selectionDiscussionID: nil,
            phase: .executing,
            success: nil,
            output: nil,
            resultTurnID: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try journal.save(entry)

        XCTAssertEqual(try journal.pendingEntry(), entry)
        entry.phase = .executed
        entry.success = true
        entry.output = #"{"revision":8}"#
        entry.updatedAt = Date(timeIntervalSince1970: 2)
        try journal.save(entry)

        entry.phase = .resultSubmitting
        entry.updatedAt = Date(timeIntervalSince1970: 3)
        try journal.save(entry)
        XCTAssertEqual(try journal.pendingEntry()?.phase, .resultSubmitting)

        entry.phase = .resultSubmitted
        entry.resultTurnID = "turn-result-accepted"
        entry.updatedAt = Date(timeIntervalSince1970: 4)
        try journal.save(entry)

        let reloaded = try XCTUnwrap(
            RemoteHermesToolJournal(
                fileURL: directory.appendingPathComponent("remote-hermes-tool-journal.json")
            ).pendingEntry()
        )
        XCTAssertEqual(reloaded.id, "call-1")
        XCTAssertEqual(reloaded.sourceTurnID, "turn-tool-call")
        XCTAssertEqual(reloaded.resultTurnID, "turn-result-accepted")
        XCTAssertEqual(reloaded.success, true)
        XCTAssertEqual(reloaded.output, #"{"revision":8}"#)

        entry.phase = .completed
        entry.updatedAt = Date(timeIntervalSince1970: 5)
        try journal.save(entry)
        XCTAssertNil(try journal.pendingEntry())
    }

    func testRemoteHermesToolJournalSelectsOldestPendingEntryPerThread() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = RemoteHermesToolJournal(
            fileURL: directory.appendingPathComponent("remote-hermes-tool-journal.json")
        )
        for (id, threadID, timestamp) in [
            ("a-first", "thread-a", 1.0),
            ("b-later", "thread-b", 2.0),
            ("a-second", "thread-a", 3.0),
        ] {
            try journal.save(RemoteHermesToolJournalEntry(
                id: id,
                workspaceID: "workspace-1",
                threadID: threadID,
                sourceTurnID: "turn-\(id)",
                toolName: CourseAgentTools.presentPlan,
                argumentsJSON: #"{"workspace_id":"workspace-1"}"#,
                selectionDiscussionID: nil,
                phase: .executing,
                success: nil,
                output: nil,
                resultTurnID: nil,
                updatedAt: Date(timeIntervalSince1970: timestamp)
            ))
        }

        XCTAssertEqual(
            try journal.pendingEntry(workspaceID: "workspace-1", threadID: "thread-a")?.id,
            "a-first"
        )
        XCTAssertEqual(
            try journal.pendingEntry(workspaceID: "workspace-1", threadID: "thread-b")?.id,
            "b-later"
        )
    }

    func testHermesAbandonTargetsOnlyTheSelectedWorkspaceThread() {
        let accepted = [
            PendingHermesAcceptedTurn(
                workspaceID: "workspace-1",
                serverID: "server",
                threadID: "thread-a",
                expectedTurnID: "accepted-a",
                selectionDiscussionID: nil,
                terminalError: nil
            ),
            PendingHermesAcceptedTurn(
                workspaceID: "workspace-1",
                serverID: "server",
                threadID: "thread-b",
                expectedTurnID: "accepted-b",
                selectionDiscussionID: UUID(),
                terminalError: nil
            ),
        ]
        let entries = [
            RemoteHermesToolJournalEntry(
                id: "entry-a",
                workspaceID: "workspace-1",
                threadID: "thread-a",
                sourceTurnID: "source-a",
                toolName: "native-editor-fetch",
                argumentsJSON: "{}",
                selectionDiscussionID: nil,
                phase: .resultSubmitted,
                success: true,
                output: "a",
                resultTurnID: "result-a",
                updatedAt: Date()
            ),
            RemoteHermesToolJournalEntry(
                id: "entry-b",
                workspaceID: "workspace-1",
                threadID: "thread-b",
                sourceTurnID: "source-b",
                toolName: "native-editor-fetch",
                argumentsJSON: "{}",
                selectionDiscussionID: UUID(),
                phase: .resultSubmitted,
                success: true,
                output: "b",
                resultTurnID: "result-b",
                updatedAt: Date()
            ),
        ]

        XCTAssertEqual(
            CourseExperienceStore.hermesTurnIDsForAbandon(
                acceptedTurns: accepted,
                journalEntries: entries,
                workspaceID: "workspace-1",
                threadID: "thread-b"
            ),
            Set(["accepted-b", "result-b"])
        )
    }

    func testSavedCourseAndSelectionRecoveryCannotOfferWorkspaceDeletion() throws {
        let defaults = try makeDefaults()
        let store = CourseExperienceStore(defaults: defaults)
        XCTAssertFalse(store.canDeletePendingHermesDraft(selectionDiscussionID: UUID()))
    }

    @MainActor
    func testColdStoreRestoresExactHermesWorkspaceAndThreadForEveryPendingJournalPhase() throws {
        for phase in [
            RemoteHermesToolJournalEntry.Phase.executing,
            .executed,
            .resultSubmitting,
            .resultSubmitted,
        ] {
            let suite = "CourseExperienceStore.pending-hermes.\(phase.rawValue).\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let workspaceID = "pending-\(phase.rawValue)-\(UUID().uuidString.lowercased())"
            let coursesRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("HermesLegacyMigration-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: coursesRoot) }
            let threadID = UUID().uuidString.lowercased()
            var plan = CourseBrief()
            plan.planID = "pending-plan"
            plan.revision = 3
            plan.title = "Pending Hermes course"
            let identity = PendingHermesCourseIdentity(
                workspaceID: workspaceID,
                serverID: "server-hermes",
                threadID: threadID,
                runtimeID: "hermes",
                modelID: "hermes-model",
                brief: plan,
                showsBrief: true,
                expectedTurnID: "turn-accepted-\(phase.rawValue)",
                terminalError: nil
            )
            let submissionJournal = RemoteHermesSubmissionJournal(
                fileURL: coursesRoot
                    .appendingPathComponent(workspaceID, isDirectory: true)
                    .appendingPathComponent(".course/remote-hermes-submissions.json")
            )
            let expectedTurnID = phase == .resultSubmitted
                ? "turn-result-\(phase.rawValue)"
                : nil
            try submissionJournal.save(PendingHermesAcceptedTurn(
                workspaceID: workspaceID,
                serverID: "server-hermes",
                threadID: threadID,
                expectedTurnID: expectedTurnID,
                selectionDiscussionID: nil,
                terminalError: nil,
                courseIdentity: identity,
                toolLifecycleOwned: true
            ))
            let toolJournal = RemoteHermesToolJournal(
                fileURL: coursesRoot
                    .appendingPathComponent(workspaceID, isDirectory: true)
                    .appendingPathComponent(".course/remote-hermes-tool-journal.json")
            )
            try toolJournal.save(RemoteHermesToolJournalEntry(
                id: "call-\(phase.rawValue)",
                workspaceID: workspaceID,
                threadID: threadID,
                sourceTurnID: "turn-tool-\(phase.rawValue)",
                toolName: CourseAgentTools.presentPlan,
                argumentsJSON: "{\"workspace_id\":\"\(workspaceID)\"}",
                selectionDiscussionID: nil,
                phase: phase,
                success: phase == .executing ? nil : true,
                output: phase == .executing ? nil : "durable-result",
                resultTurnID: expectedTurnID,
                updatedAt: Date()
            ))

            XCTAssertNil(defaults.data(forKey: CourseExperienceStore.pendingHermesCourseKey))
            XCTAssertNil(defaults.data(forKey: CourseExperienceStore.pendingHermesTurnsKey))

            let store = CourseExperienceStore(
                defaults: defaults,
                coursesRootURL: coursesRoot
            )
            XCTAssertEqual(store.agentThreadKey, ThreadKey(serverId: "server-hermes", threadId: threadID))
            XCTAssertEqual(store.activeAgentID, "hermes")
            XCTAssertEqual(store.brief, plan)
            XCTAssertTrue(store.showsBrief)
            XCTAssertEqual(store.navigationPath, [.newCourse])
            XCTAssertTrue(store.hasPendingHermesRecovery())
            XCTAssertTrue(
                store.courseDatabaseURL(workspaceID: workspaceID).path.contains(workspaceID)
            )
            XCTAssertNil(defaults.data(forKey: CourseExperienceStore.pendingHermesTurnsKey))
        }
    }

    @MainActor
    func testPresentedHermesPlanRefreshesJournalOnlyIdentityAcrossDeliveryPhases() throws {
        for phase in [
            RemoteHermesToolJournalEntry.Phase.executed,
            .resultSubmitting,
            .resultSubmitted,
        ] {
            let suite = "CourseExperienceStore.plan-transition.\(phase.rawValue).\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let coursesRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("HermesPlanTransition-\(UUID().uuidString)", isDirectory: true)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: coursesRoot)
            }
            let workspaceID = UUID().uuidString.lowercased()
            let threadID = UUID().uuidString.lowercased()
            let key = ThreadKey(serverId: "server-hermes", threadId: threadID)
            let resultTurnID = phase == .resultSubmitted ? "turn-result-plan" : nil
            let initialIdentity = PendingHermesCourseIdentity(
                workspaceID: workspaceID,
                serverID: key.serverId,
                threadID: key.threadId,
                runtimeID: "hermes",
                modelID: "learnfoldflawless",
                brief: CourseBrief(),
                showsBrief: false,
                expectedTurnID: resultTurnID,
                terminalError: nil
            )
            let submissionJournal = RemoteHermesSubmissionJournal(
                fileURL: coursesRoot
                    .appendingPathComponent(workspaceID, isDirectory: true)
                    .appendingPathComponent(".course/remote-hermes-submissions.json")
            )
            try submissionJournal.save(PendingHermesAcceptedTurn(
                workspaceID: workspaceID,
                serverID: key.serverId,
                threadID: key.threadId,
                expectedTurnID: resultTurnID,
                selectionDiscussionID: nil,
                terminalError: nil,
                courseIdentity: initialIdentity,
                toolLifecycleOwned: true
            ))
            var presentedPlan = CourseBrief()
            presentedPlan.planID = "durable-presented-plan"
            presentedPlan.revision = 7
            presentedPlan.title = "Durable Presented Plan"
            let toolJournal = RemoteHermesToolJournal(
                fileURL: coursesRoot
                    .appendingPathComponent(workspaceID, isDirectory: true)
                    .appendingPathComponent(".course/remote-hermes-tool-journal.json")
            )
            try toolJournal.save(RemoteHermesToolJournalEntry(
                id: "call-plan-\(phase.rawValue)",
                workspaceID: workspaceID,
                threadID: threadID,
                sourceTurnID: "turn-plan-tool",
                toolName: CourseAgentTools.presentPlan,
                argumentsJSON: String(decoding: try JSONEncoder().encode(presentedPlan), as: UTF8.self),
                selectionDiscussionID: nil,
                phase: phase,
                success: true,
                output: "plan displayed",
                resultTurnID: resultTurnID,
                updatedAt: Date()
            ))

            let liveStore = CourseExperienceStore(
                defaults: defaults,
                environment: [:],
                coursesRootURL: coursesRoot
            )
            XCTAssertEqual(liveStore.brief, CourseBrief())
            XCTAssertFalse(liveStore.showsBrief)
            try liveStore.persistPresentedHermesPlanRecoveryState(
                presentedPlan,
                key: key,
                workspaceID: workspaceID
            )

            defaults.removeObject(forKey: CourseExperienceStore.pendingHermesCourseKey)
            defaults.removeObject(forKey: CourseExperienceStore.pendingHermesTurnsKey)
            let coldStore = CourseExperienceStore(
                defaults: defaults,
                environment: [:],
                coursesRootURL: coursesRoot
            )
            XCTAssertEqual(coldStore.agentThreadKey, key)
            XCTAssertEqual(coldStore.navigationPath, [.newCourse])
            XCTAssertEqual(coldStore.brief, presentedPlan)
            XCTAssertTrue(coldStore.showsBrief)
            XCTAssertTrue(coldStore.hasPendingHermesRecovery())
            let durableIdentity = try XCTUnwrap(submissionJournal.load().last?.courseIdentity)
            XCTAssertEqual(durableIdentity.brief, presentedPlan)
            XCTAssertTrue(durableIdentity.showsBrief)
        }
    }

    @MainActor
    func testColdStoreRestoresPreAcceptHermesSubmissionIntentFromWorkspaceJournal() throws {
        let suite = "CourseExperienceStore.preaccept-disk.\(UUID().uuidString)"
        let writerDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        writerDefaults.removePersistentDomain(forName: suite)
        let coursesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesPreAccept-\(UUID().uuidString)", isDirectory: true)
        defer {
            writerDefaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: coursesRoot)
        }
        let workspaceID = UUID().uuidString.lowercased()
        let threadID = UUID().uuidString.lowercased()
        let identity = PendingHermesCourseIdentity(
            workspaceID: workspaceID,
            serverID: "server-hermes",
            threadID: threadID,
            runtimeID: "hermes",
            modelID: "learnfoldflawless",
            brief: CourseBrief(),
            showsBrief: false,
            expectedTurnID: nil,
            terminalError: nil
        )
        let journal = RemoteHermesSubmissionJournal(
            fileURL: coursesRoot
                .appendingPathComponent(workspaceID, isDirectory: true)
                .appendingPathComponent(".course/remote-hermes-submissions.json")
        )
        let intent = PendingHermesAcceptedTurn(
            workspaceID: workspaceID,
            serverID: "server-hermes",
            threadID: threadID,
            expectedTurnID: nil,
            selectionDiscussionID: nil,
            terminalError: nil,
            submissionIntentID: "intent-durable",
            previousTurnID: "turn-baseline",
            submittedText: "internal envelope",
            learnerText: "Build the lesson",
            linkedSources: [PendingHermesLinkedSource(name: "Source", detail: "https://example.com")],
            optimisticMessageID: UUID(),
            courseIdentity: identity
        )
        try journal.save(intent)

        let freshDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertNil(freshDefaults.data(forKey: CourseExperienceStore.pendingHermesCourseKey))
        XCTAssertNil(freshDefaults.data(forKey: CourseExperienceStore.pendingHermesTurnsKey))
        let store = CourseExperienceStore(
            defaults: freshDefaults,
            environment: [:],
            coursesRootURL: coursesRoot
        )

        XCTAssertEqual(store.agentThreadKey, ThreadKey(serverId: "server-hermes", threadId: threadID))
        XCTAssertEqual(store.navigationPath, [.newCourse])
        XCTAssertEqual(store.activeAgentID, "hermes")
        XCTAssertEqual(store.brief, identity.brief)
        XCTAssertEqual(store.showsBrief, identity.showsBrief)
        XCTAssertTrue(store.hasPendingHermesRecovery())
        XCTAssertEqual(try journal.load(), [intent])
    }

    @MainActor
    func testColdStoreRestoresAcceptedHermesTurnFromWorkspaceJournal() throws {
        let suite = "CourseExperienceStore.accepted-disk.\(UUID().uuidString)"
        let writerDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        writerDefaults.removePersistentDomain(forName: suite)
        let coursesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesAccepted-\(UUID().uuidString)", isDirectory: true)
        defer {
            writerDefaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: coursesRoot)
        }
        let workspaceID = UUID().uuidString.lowercased()
        let threadID = UUID().uuidString.lowercased()
        let acceptedTurnID = "turn-accepted-on-server"
        var acceptedBrief = CourseBrief()
        acceptedBrief.planID = "accepted-durable-plan"
        acceptedBrief.title = "Accepted durable course"
        let identity = PendingHermesCourseIdentity(
            workspaceID: workspaceID,
            serverID: "server-hermes",
            threadID: threadID,
            runtimeID: "hermes",
            modelID: "learnfoldflawless",
            brief: acceptedBrief,
            showsBrief: true,
            expectedTurnID: acceptedTurnID,
            terminalError: nil
        )
        let journal = RemoteHermesSubmissionJournal(
            fileURL: coursesRoot
                .appendingPathComponent(workspaceID, isDirectory: true)
                .appendingPathComponent(".course/remote-hermes-submissions.json")
        )
        let accepted = PendingHermesAcceptedTurn(
            workspaceID: workspaceID,
            serverID: "server-hermes",
            threadID: threadID,
            expectedTurnID: acceptedTurnID,
            selectionDiscussionID: nil,
            terminalError: nil,
            submissionIntentID: "intent-preserved",
            previousTurnID: "turn-baseline",
            submittedText: "internal envelope",
            learnerText: "Build the lesson",
            linkedSources: nil,
            optimisticMessageID: UUID(),
            courseIdentity: identity
        )
        try journal.save(accepted)

        let freshDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertNil(freshDefaults.data(forKey: CourseExperienceStore.pendingHermesCourseKey))
        XCTAssertNil(freshDefaults.data(forKey: CourseExperienceStore.pendingHermesTurnsKey))
        let store = CourseExperienceStore(
            defaults: freshDefaults,
            environment: [:],
            coursesRootURL: coursesRoot
        )

        XCTAssertEqual(store.agentThreadKey, ThreadKey(serverId: "server-hermes", threadId: threadID))
        XCTAssertEqual(store.navigationPath, [.newCourse])
        XCTAssertEqual(store.activeAgentID, "hermes")
        XCTAssertEqual(store.brief, acceptedBrief)
        XCTAssertTrue(store.showsBrief)
        XCTAssertTrue(store.hasPendingHermesRecovery())
        XCTAssertEqual(try journal.load().first?.expectedTurnID, acceptedTurnID)
        XCTAssertEqual(try journal.load().first?.learnerText, "Build the lesson")
    }

    @MainActor
    func testCorruptHermesJournalFailsClosedBeforeBeginningAnotherCourse() throws {
        let defaults = try makeDefaults()
        let workspaceID = "corrupt-journal-\(UUID().uuidString.lowercased())"
        let threadID = UUID().uuidString.lowercased()
        let identity = PendingHermesCourseIdentity(
            workspaceID: workspaceID,
            serverID: "server-hermes",
            threadID: threadID,
            runtimeID: "hermes",
            modelID: nil,
            brief: CourseBrief(),
            showsBrief: false,
            expectedTurnID: nil,
            terminalError: nil
        )
        defaults.set(
            try JSONEncoder().encode(identity),
            forKey: CourseExperienceStore.pendingHermesCourseKey
        )
        let store = CourseExperienceStore(defaults: defaults)
        let journalURL = store.courseDatabaseURL(workspaceID: workspaceID)
            .deletingLastPathComponent()
            .appendingPathComponent("remote-hermes-tool-journal.json")
        defer {
            try? FileManager.default.removeItem(
                at: journalURL.deletingLastPathComponent().deletingLastPathComponent()
            )
        }
        try FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: journalURL)

        store.beginNewCourse()

        XCTAssertEqual(store.agentThreadKey?.threadId, threadID)
        XCTAssertTrue(store.agentError?.contains("recovery data") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    @MainActor
    func testTerminalHermesProtocolErrorBlocksBeginningAnotherCourse() async throws {
        let defaults = try makeDefaults()
        let workspaceID = "terminal-hermes-\(UUID().uuidString.lowercased())"
        let threadID = UUID().uuidString.lowercased()
        let coursesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: coursesRoot) }
        let workspaceRoot = coursesRoot.appendingPathComponent(workspaceID, isDirectory: true)
        let journal = RemoteHermesSubmissionJournal(
            fileURL: workspaceRoot
                .appendingPathComponent(".course", isDirectory: true)
                .appendingPathComponent("remote-hermes-submissions.json")
        )
        try journal.save(PendingHermesAcceptedTurn(
            workspaceID: workspaceID,
            serverID: "server-hermes",
            threadID: threadID,
            expectedTurnID: nil,
            selectionDiscussionID: nil,
            terminalError: "Hermes returned malformed native-tool JSON.",
            courseIdentity: PendingHermesCourseIdentity(
                workspaceID: workspaceID,
                serverID: "server-hermes",
                threadID: threadID,
                runtimeID: "hermes",
                modelID: "learnfoldflawless",
                brief: CourseBrief(),
                showsBrief: false,
                expectedTurnID: nil,
                terminalError: "Hermes returned malformed native-tool JSON."
            )
        ))
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: [:],
            coursesRootURL: coursesRoot
        )

        store.beginNewCourse()

        XCTAssertEqual(store.agentThreadKey?.threadId, threadID)
        XCTAssertEqual(store.navigationPath, [.newCourse])
        XCTAssertTrue(store.agentError?.contains("malformed native-tool JSON") == true)
        XCTAssertEqual(try journal.load().first?.terminalError, "Hermes returned malformed native-tool JSON.")

        store.agentError = nil
        await store.retryPendingHermesRecovery(
            selectionDiscussionID: nil,
            appModel: AppModel(),
            appState: AppState()
        )

        XCTAssertTrue(store.agentError?.contains("malformed native-tool JSON") == true)
        XCTAssertTrue(store.hasPendingHermesRecovery())
        XCTAssertEqual(try journal.load().first?.terminalError, "Hermes returned malformed native-tool JSON.")
    }

    func testRemoteHermesRequiresARealAcceptedServerTurnReceipt() throws {
        XCTAssertEqual(
            try CourseExperienceStore.acceptedRemoteHermesTurnID(
                AppTurnSubmissionReceipt(kind: .started, turnId: "turn-started")
            ),
            "turn-started"
        )
        XCTAssertEqual(
            try CourseExperienceStore.acceptedRemoteHermesTurnID(
                AppTurnSubmissionReceipt(kind: .steered, turnId: "turn-steered")
            ),
            "turn-steered"
        )
        XCTAssertThrowsError(
            try CourseExperienceStore.acceptedRemoteHermesTurnID(
                AppTurnSubmissionReceipt(kind: .queued, turnId: nil)
            )
        )
    }

    func testHermesSubmissionIntentReconcilesExactlyOneTurnAfterAuthoritativeBaseline() throws {
        XCTAssertEqual(
            try CourseExperienceStore.acceptedTurnAfterSubmissionBaseline(
                turnIDsDescending: ["turn-new", "turn-baseline"],
                previousTurnID: "turn-baseline"
            ),
            "turn-new"
        )
        XCTAssertNil(
            try CourseExperienceStore.acceptedTurnAfterSubmissionBaseline(
                turnIDsDescending: ["turn-baseline"],
                previousTurnID: "turn-baseline"
            )
        )
        XCTAssertThrowsError(
            try CourseExperienceStore.acceptedTurnAfterSubmissionBaseline(
                turnIDsDescending: ["turn-new-2", "turn-new-1", "turn-baseline"],
                previousTurnID: "turn-baseline"
            )
        )
    }

    func testRemoteHermesUsesAuthoritativeListedTurnWhenLocalSnapshotIsCold() {
        let listedItems = [
            HydratedConversationItem(
                id: "agent-listed",
                content: .assistant(
                    HydratedAssistantMessageData(
                        text: "  authoritative recovered response  ",
                        agentNickname: nil,
                        agentRole: nil,
                        phase: nil
                    )
                ),
                sourceTurnId: "turn-recovered",
                sourceTurnIndex: 0,
                timestamp: 1,
                isFromUserTurnBoundary: false
            ),
        ]

        XCTAssertEqual(
            CourseExperienceStore.remoteHermesAssistantText(
                in: listedItems,
                turnID: "turn-recovered"
            ),
            "authoritative recovered response"
        )
        XCTAssertNil(CourseExperienceStore.remoteHermesAssistantText(
            in: listedItems,
            turnID: "turn-other"
        ))
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

    private func flattenCourseNodes(_ nodes: [CourseLearningNode]) -> [CourseLearningNode] {
        nodes.flatMap { [$0] + flattenCourseNodes($0.children) }
    }

    private func messageTexts(in items: [ConversationItem]) -> [String] {
        items.compactMap { item in
            switch item.content {
            case .user(let data): data.text
            case .assistant(let data): data.text
            default: nil
            }
        }
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
        onCoursePlan: @escaping @MainActor (CourseBrief) async throws -> Void
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
