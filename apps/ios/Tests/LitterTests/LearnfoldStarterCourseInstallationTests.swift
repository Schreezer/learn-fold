import NativeBlockEditorCore
import NativeEditorMCP
import XCTest
@testable import Litter

@MainActor
final class LearnfoldStarterCourseInstallationTests: XCTestCase {
    private struct Fixture {
        let defaults: UserDefaults
        let root: URL
        let suiteName: String

        @MainActor
        func store() -> CourseExperienceStore {
            CourseExperienceStore(defaults: defaults, environment: [:], coursesRootURL: root)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture() throws -> Fixture {
        let suiteName = "LearnfoldStarterCourseInstallationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "snappy.course.agentSetupComplete")
        defaults.set("codex", forKey: "snappy.course.selectedAgent")
        defaults.set("selected-server", forKey: "snappy.course.selectedAgentServer")
        defaults.set("selected-model", forKey: "snappy.course.selectedModel")
        defaults.set("high", forKey: "snappy.course.selectedReasoningEffort")
        return Fixture(
            defaults: defaults,
            root: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true),
            suiteName: suiteName
        )
    }

    private func repository(_ store: CourseExperienceStore) async throws -> CourseDocumentRepository {
        try await CourseDocumentRepository.open(
            workspaceID: LearnfoldStarterCourse.workspaceID,
            databaseURL: store.courseDatabaseURL(workspaceID: LearnfoldStarterCourse.workspaceID),
            rootTitle: LearnfoldStarterCourse.title
        )
    }

    func testInstallsReadyEditablePagesWithSelectedAgentAndPreservesExistingWork() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let existing = LearningCourse(
            id: "existing-course", title: "Existing course", subtitle: "Keep my work",
            accentHex: "123456", progress: 0.4, lessonCount: 3, duration: "1 hour",
            status: .ready, workspaceID: "existing-workspace", agentRuntimeKind: "hermes"
        )
        fixture.defaults.set(try JSONEncoder().encode([existing]), forKey: "snappy.course.savedCourses")
        let store = fixture.store()
        store.navigationPath = [.course(existing.id)]
        store.courseChatDraft = "Keep my question"
        await store.installStarterCourseIfNeeded()

        XCTAssertNil(store.starterCourseInstallationError)
        XCTAssertEqual(store.courses.first, existing)
        XCTAssertEqual(store.courses.count, 2)
        XCTAssertEqual(store.navigationPath, [.course(existing.id)])
        XCTAssertEqual(store.courseChatDraft, "Keep my question")
        let tutorial = try XCTUnwrap(store.course(withID: LearnfoldStarterCourse.workspaceID))
        XCTAssertEqual(tutorial.agentRuntimeKind, "codex")
        XCTAssertEqual(tutorial.agentServerID, "selected-server")
        XCTAssertEqual(tutorial.agentModelID, "selected-model")
        XCTAssertEqual(tutorial.agentReasoningEffortID, "high")
        XCTAssertNil(tutorial.agentThreadID)
        XCTAssertEqual(tutorial.lessonCount, LearnfoldStarterCourse.lessons.count)
        let brief = try XCTUnwrap(store.courseBrief(for: tutorial))
        XCTAssertNil(AppleCoursePlanValidator.issue(in: brief, requiresTypedHierarchy: true))

        let repository = try await repository(store)
        let outline = try await repository.outline()
        XCTAssertTrue(outline.isReadyForLearning)
        XCTAssertFalse(repository.allowsCloudSync)
        let approved = await repository.isLatestPlanApproved()
        XCTAssertTrue(approved)
        for lesson in LearnfoldStarterCourse.lessons {
            let page = try await repository.pageSnapshot(id: lesson.id)
            XCTAssertEqual(page.title, lesson.title)
            XCTAssertGreaterThan(page.document.root.children.count, 3)
            XCTAssertEqual(page.document.root.data["course_generation_status"]?.stringValue, "generated")
        }
        // Explicit queue paths must also respect the local practice boundary,
        // including when the CloudKit engine has no active account.
        try await CourseCloudSyncEngine().queueWorkspaceGeneration(repository: repository)
    }

    func testRelaunchPreservesSavedEditsAndDoesNotApproveARevisedPlan() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        await store.installStarterCourseIfNeeded()
        let tutorial = try XCTUnwrap(store.course(withID: LearnfoldStarterCourse.workspaceID))
        let repository = try await repository(store)
        let page = try await repository.pageSnapshot(id: LearnfoldStarterCourse.lessons[0].id)
        var edited = try AppFlowyMarkdownCodec().decode("# My practice page\n\nI added this note myself.")
        edited.root.data = page.document.root.data
        try await repository.stageUserEdit(pageID: page.id, document: edited)
        try await repository.flushPendingUserEdits()
        var revised = try XCTUnwrap(store.courseBrief(for: tutorial))
        revised.revision += 1
        revised.summary = "A new proposed practice plan that still needs review."
        try await repository.presentPlan(revised)

        let relaunched = fixture.store()
        await relaunched.installStarterCourseIfNeeded()
        XCTAssertEqual(relaunched.courses.count, 1)
        let reopened = try await self.repository(relaunched)
        let persisted = try await reopened.pageSnapshot(id: page.id)
        XCTAssertEqual(AppFlowyMarkdownCodec().encode(persisted.document), AppFlowyMarkdownCodec().encode(edited))
        XCTAssertEqual(persisted.document.root.data, edited.root.data)
        let approved = await reopened.isLatestPlanApproved()
        XCTAssertFalse(approved)
        let presented = AppleCourseApprovalPolicy.presentedPlan(
            courseDirectory: try XCTUnwrap(relaunched.courseDirectory(for: tutorial))
        )
        XCTAssertEqual(presented, revised)
    }

    func testNativeToolsCanEditPracticeTextAndCreateAnExplainerWithDurableReadback() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        await store.installStarterCourseIfNeeded()
        let repository = try await repository(store)
        let practice = try await repository.pageSnapshot(id: LearnfoldStarterCourse.lessons[4].id)
        let oldText = "I read a recipe twice. Then I close it and describe the steps in order. I open the recipe again to see what I left out."
        let newText = "I read a bread recipe, close it, and describe the steps from memory. Then I check the recipe for anything I missed."
        let update = await repository.callTool(
            named: NativeEditorMCPToolCatalog.updatePage,
            argumentsJSON: try jsonString([
                "page_id": practice.id,
                "expected_revision": practice.revision,
                "command": "update_content",
                "content_updates": [["old_str": oldText, "new_str": newText]],
            ])
        )
        XCTAssertFalse(update.isError, "\(update.value)")
        let create = await repository.callTool(
            named: NativeEditorMCPToolCatalog.createPages,
            argumentsJSON: try jsonString([
                "parent": ["page_id": LearnfoldStarterCourse.lessons[6].id],
                "pages": [[
                    "properties": [
                        "title": "My practice explainer",
                        "course_node_id": "my-practice-explainer",
                        "course_role": "explainer",
                        "generation_status": "generated",
                    ],
                    "content": "# My practice explainer\n\nRecall means describing what you remember before checking the source.",
                ]],
            ])
        )
        XCTAssertFalse(create.isError, "\(create.value)")

        let createdWorkspace = try await repository.workspaceSnapshot()
        let createdExplainer = try XCTUnwrap(createdWorkspace.children(of: LearnfoldStarterCourse.lessons[6].id)
            .first { $0.title == "My practice explainer" })
        let sourcePage = try await repository.pageSnapshot(id: LearnfoldStarterCourse.lessons[6].id)
        let link = await repository.callTool(
            named: NativeEditorMCPToolCatalog.updatePage,
            argumentsJSON: try jsonString([
                "page_id": sourcePage.id,
                "expected_revision": sourcePage.revision,
                "command": "update_content",
                "content_updates": [[
                    "old_str": "# Ask for another page",
                    "new_str": "# Ask for another page\n\n[My practice explainer](native-editor://page/\(createdExplainer.id))",
                ]],
            ])
        )
        XCTAssertFalse(link.isError, "\(link.value)")

        let reopened = try await self.repository(store)
        let saved = try await reopened.pageSnapshot(id: practice.id)
        let markdown = AppFlowyMarkdownCodec().encode(saved.document)
        XCTAssertTrue(markdown.contains(newText))
        XCTAssertFalse(markdown.contains(oldText))
        XCTAssertTrue(markdown.contains("## Practice section"))
        XCTAssertTrue(markdown.contains("## End of practice"))
        XCTAssertTrue(markdown.contains("Everything outside the practice section is part of the tutorial."))
        let workspace = try await reopened.workspaceSnapshot()
        let explainer = try XCTUnwrap(workspace.children(of: LearnfoldStarterCourse.lessons[6].id)
            .first { $0.title == "My practice explainer" })
        XCTAssertEqual(explainer.document.root.data["course_role"]?.stringValue, "explainer")
        let created = try await reopened.pageSnapshot(id: explainer.id)
        XCTAssertTrue(AppFlowyMarkdownCodec().encode(created.document).contains("Recall means describing"))
        let parent = try await reopened.pageSnapshot(id: LearnfoldStarterCourse.lessons[6].id)
        XCTAssertTrue(AppFlowyMarkdownCodec().encode(parent.document).contains(explainer.id))
    }

    private func jsonString(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    func testConcurrentInstallCallsAddOneCourse() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { await store.installStarterCourseIfNeeded() }
            }
        }
        XCTAssertNil(store.starterCourseInstallationError)
        XCTAssertEqual(store.courses.filter { $0.workspaceID == LearnfoldStarterCourse.workspaceID }.count, 1)
        XCTAssertTrue(fixture.defaults.bool(forKey: CourseExperienceStore.starterCourseInstalledKey))
    }

    func testStorageFailureCanRetryWithoutLosingExistingCourseIndex() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        try Data("not a directory".utf8).write(to: fixture.root)
        let store = fixture.store()
        await store.installStarterCourseIfNeeded()
        XCTAssertNotNil(store.starterCourseInstallationError)
        XCTAssertFalse(fixture.defaults.bool(forKey: CourseExperienceStore.starterCourseInstalledKey))
        XCTAssertTrue(store.courses.isEmpty)

        try FileManager.default.removeItem(at: fixture.root)
        await store.installStarterCourseIfNeeded()
        XCTAssertNil(store.starterCourseInstallationError)
        XCTAssertEqual(store.courses.count, 1)
    }

    func testRemovalDoesNotReinstallEvenIfDefaultsMarkerIsLost() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        await store.installStarterCourseIfNeeded()
        let tutorial = try XCTUnwrap(store.course(withID: LearnfoldStarterCourse.workspaceID))
        try FileManager.default.removeItem(at: try XCTUnwrap(store.courseDirectory(for: tutorial)))
        fixture.defaults.set(try JSONEncoder().encode([LearningCourse]()), forKey: "snappy.course.savedCourses")
        fixture.defaults.removeObject(forKey: CourseExperienceStore.starterCourseInstalledKey)

        let relaunched = fixture.store()
        await relaunched.installStarterCourseIfNeeded()
        XCTAssertTrue(relaunched.courses.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: relaunched.courseDatabaseURL(workspaceID: LearnfoldStarterCourse.workspaceID).path
        ))
    }

    func testInterruptedIndexCommitRecoversRecordedAgentWithoutReapprovingPages() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        await store.installStarterCourseIfNeeded()
        let original = try XCTUnwrap(store.course(withID: LearnfoldStarterCourse.workspaceID))
        let repository = try await repository(store)
        var revised = try XCTUnwrap(store.courseBrief(for: original))
        revised.revision += 1
        revised.summary = "A learner proposal awaiting explicit approval."
        try await repository.presentPlan(revised)
        fixture.defaults.set(try JSONEncoder().encode([LearningCourse]()), forKey: "snappy.course.savedCourses")
        fixture.defaults.removeObject(forKey: CourseExperienceStore.starterCourseInstalledKey)
        try FileManager.default.removeItem(at: store.courseControlDirectory(
            workspaceID: LearnfoldStarterCourse.workspaceID
        ).appendingPathComponent("starter-course-installed.v1"))
        fixture.defaults.set("different-model", forKey: "snappy.course.selectedModel")

        let relaunched = fixture.store()
        await relaunched.recoverReadyCourses()
        XCTAssertTrue(relaunched.courses.isEmpty, "Generic recovery must leave starter ownership to its install receipt.")
        await relaunched.installStarterCourseIfNeeded()
        XCTAssertEqual(relaunched.courses, [original])
        XCTAssertNil(relaunched.starterCourseInstallationError)
        let approved = await repository.isLatestPlanApproved()
        XCTAssertFalse(approved)
    }

    func testUnknownExistingWorkspaceIsPreservedWithoutGrantingApproval() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        let repository = try await repository(store)
        let original = try await repository.workspaceSnapshot()
        await store.installStarterCourseIfNeeded()
        XCTAssertNotNil(store.starterCourseInstallationError)
        XCTAssertTrue(store.courses.isEmpty)
        let latest = try await repository.workspaceSnapshot()
        XCTAssertEqual(latest.rootPageID, original.rootPageID)
        XCTAssertEqual(Set(latest.pages.keys), Set(original.pages.keys))
        for (id, page) in original.pages {
            let preserved = try XCTUnwrap(latest.pages[id])
            XCTAssertEqual(preserved.title, page.title)
            XCTAssertEqual(preserved.parentID, page.parentID)
            XCTAssertEqual(preserved.document.root.data, page.document.root.data)
            XCTAssertEqual(AppFlowyMarkdownCodec().encode(preserved.document), AppFlowyMarkdownCodec().encode(page.document))
        }
        let approved = await repository.isLatestPlanApproved()
        XCTAssertFalse(approved)
    }

    func testWaitsForAgentSetup() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(false, forKey: "snappy.course.agentSetupComplete")
        let store = fixture.store()
        await store.installStarterCourseIfNeeded()
        XCTAssertTrue(store.courses.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }
}
