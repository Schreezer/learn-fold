import NativeBlockEditorCore
import NativeEditorMCP
import XCTest
@testable import Litter

final class CourseDocumentRepositoryTests: XCTestCase {
    func testCoursePageLinkResolverAcceptsOnlyNativeEditorPageLinks() throws {
        let pageID = "763e4ff6-b27c-445e-916b-34a237f34bc3"

        XCTAssertEqual(
            CoursePageLinkResolver.pageID(
                from: try XCTUnwrap(URL(string: "native-editor://page/\(pageID)"))
            ),
            pageID
        )
        XCTAssertNil(
            CoursePageLinkResolver.pageID(
                from: try XCTUnwrap(URL(string: "https://example.com/page/\(pageID)"))
            )
        )
        XCTAssertNil(
            CoursePageLinkResolver.pageID(
                from: try XCTUnwrap(URL(string: "native-editor://page/\(pageID)/extra"))
            )
        )
    }

    func testRegistryReturnsOneRepositoryActorToConcurrentOpeners() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDocumentRegistryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent(".course/course-library.sqlite")
        let workspaceID = UUID().uuidString

        let repositories = try await withThrowingTaskGroup(
            of: CourseDocumentRepository.self,
            returning: [CourseDocumentRepository].self
        ) { group in
            for _ in 0 ..< 24 {
                group.addTask {
                    try await CourseDocumentRegistry.shared.repository(
                        workspaceID: workspaceID,
                        databaseURL: databaseURL,
                        rootTitle: "Concurrent course"
                    )
                }
            }
            var values: [CourseDocumentRepository] = []
            for try await repository in group {
                values.append(repository)
            }
            return values
        }

        let identities = Set(repositories.map(ObjectIdentifier.init))
        XCTAssertEqual(identities.count, 1)
    }

    func testRemoteDynamicMutationIsRejectedUntilLatestPlanIsApproved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDocumentApprovalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspaceID = UUID().uuidString
        let threadID = "hermes-thread-\(UUID().uuidString)"
        _ = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID,
            databaseURL: directory.appendingPathComponent(".course/course-library.sqlite"),
            rootTitle: "Approval-gated course"
        )
        await CourseDocumentRegistry.shared.register(
            threadID: threadID,
            workspaceID: workspaceID
        )

        let result = await Task.detached {
            CourseDocumentToolRouter.shared.handleDynamicTool(
                invocation: AppPlatformDynamicToolInvocation(
                    threadId: threadID,
                    tool: NativeEditorMCPToolCatalog.updatePage,
                    argumentsJson: "{}"
                )
            )
        }.value

        XCTAssertEqual(result?.success, false)
        XCTAssertTrue(result?.output.contains("course_plan_not_approved") == true)
    }

    func testRemoteDynamicCourseBashUsesRegisteredWorkspaceAndRejectsWrongScope() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCourseBashTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspaceID = "remote-bash-\(UUID().uuidString.lowercased())"
        let threadID = "remote-thread-\(UUID().uuidString.lowercased())"
        let repository = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID,
            databaseURL: directory.appendingPathComponent(".course/course-library.sqlite"),
            rootTitle: "Remote Bash"
        )
        await CourseDocumentRegistry.shared.register(threadID: threadID, workspaceID: workspaceID)
        var plan = CourseBrief()
        plan.planID = "remote-bash-plan"
        plan.revision = 1
        plan.title = "Remote Bash"
        try await repository.approvePlan(plan)

        let arguments = #"{"workspace_id":"\#(workspaceID)","script":"printf remote-ok > result.txt && cat result.txt"}"#
        let result = await Task.detached {
            CourseDocumentToolRouter.shared.handleDynamicTool(
                invocation: AppPlatformDynamicToolInvocation(
                    threadId: threadID,
                    tool: CourseAgentTools.courseBash,
                    argumentsJson: arguments
                )
            )
        }.value

        XCTAssertEqual(result?.success, true, result?.output ?? "missing result")
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("result.txt"), encoding: .utf8),
            "remote-ok"
        )
        let wrongThread = await Task.detached {
            CourseDocumentToolRouter.shared.handleDynamicTool(
                invocation: AppPlatformDynamicToolInvocation(
                    threadId: "unregistered-thread",
                    tool: CourseAgentTools.courseBash,
                    argumentsJson: arguments
                )
            )
        }.value
        XCTAssertNil(wrongThread)

        let wrongWorkspace = await Task.detached {
            CourseDocumentToolRouter.shared.handleDynamicTool(
                invocation: AppPlatformDynamicToolInvocation(
                    threadId: threadID,
                    tool: CourseAgentTools.courseBash,
                    argumentsJson: #"{"workspace_id":"different","script":"touch escaped"}"#
                )
            )
        }.value
        XCTAssertEqual(wrongWorkspace?.success, false)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("escaped").path
        ))
    }

    func testRemotePlanRevisionPersistsBeforeSuccessAndRevokesOlderBashApproval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCoursePlanTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspaceID = "remote-plan-\(UUID().uuidString.lowercased())"
        let threadID = "remote-thread-\(UUID().uuidString.lowercased())"
        let repository = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID,
            databaseURL: directory.appendingPathComponent(".course/course-library.sqlite"),
            rootTitle: "Remote Plan"
        )
        await CourseDocumentRegistry.shared.register(threadID: threadID, workspaceID: workspaceID)

        var revisionOne = CourseBrief()
        revisionOne.planID = "remote-plan"
        revisionOne.revision = 1
        revisionOne.title = "Remote Plan"
        revisionOne.summary = "First revision"
        revisionOne.outcome = "Learn safely"
        revisionOne.startingPoint = "Beginner"
        revisionOne.focusGap = "Practice"
        revisionOne.estimatedDuration = "1h"
        revisionOne.chapters = [
            CourseChapter(id: "one", title: "One", objective: "Learn", deliverables: ["Lesson"]),
        ]
        try await repository.presentPlan(revisionOne)
        try await repository.approvePlan(revisionOne)
        let revisionOneIsApproved = await repository.isLatestPlanApproved()
        XCTAssertTrue(revisionOneIsApproved)

        var revisionTwo = revisionOne
        revisionTwo.revision = 2
        revisionTwo.summary = "Second visible revision"
        let arguments = String(decoding: try JSONEncoder().encode(revisionTwo), as: UTF8.self)
        let presentation = await Task.detached {
            CourseDocumentToolRouter.shared.handleDynamicTool(
                invocation: AppPlatformDynamicToolInvocation(
                    threadId: threadID,
                    tool: CourseAgentTools.presentPlan,
                    argumentsJson: arguments
                )
            )
        }.value

        XCTAssertEqual(presentation?.success, true, presentation?.output ?? "missing result")
        let revisionTwoIsApproved = await repository.isLatestPlanApproved()
        XCTAssertFalse(revisionTwoIsApproved)

        let bashArguments = #"{"workspace_id":"\#(workspaceID)","script":"printf forbidden > stale-approval.txt"}"#
        let bash = await Task.detached {
            CourseDocumentToolRouter.shared.handleDynamicTool(
                invocation: AppPlatformDynamicToolInvocation(
                    threadId: threadID,
                    tool: CourseAgentTools.courseBash,
                    argumentsJson: bashArguments
                )
            )
        }.value
        XCTAssertEqual(bash?.success, false)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("stale-approval.txt").path
        ))
    }

    func testConcurrentRemoteCourseBashIsRejectedWithoutQueuing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCourseBashFlight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspaceID = "remote-flight-\(UUID().uuidString.lowercased())"
        let threadID = "remote-flight-thread-\(UUID().uuidString.lowercased())"
        let repository = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID,
            databaseURL: directory.appendingPathComponent(".course/course-library.sqlite"),
            rootTitle: "Remote Flight"
        )
        await CourseDocumentRegistry.shared.register(threadID: threadID, workspaceID: workspaceID)
        var plan = CourseBrief()
        plan.planID = "remote-flight-plan"
        plan.revision = 1
        plan.title = "Remote Flight"
        try await repository.approvePlan(plan)
        let first = Task.detached {
            CourseDocumentToolRouter.shared.handleDynamicTool(
                invocation: AppPlatformDynamicToolInvocation(
                    threadId: threadID,
                    tool: CourseAgentTools.courseBash,
                    argumentsJson: #"{"workspace_id":"\#(workspaceID)","script":"sleep 2"}"#
                )
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        let started = ContinuousClock.now
        let second = await Task.detached {
            CourseDocumentToolRouter.shared.handleDynamicTool(
                invocation: AppPlatformDynamicToolInvocation(
                    threadId: threadID,
                    tool: CourseAgentTools.courseBash,
                    argumentsJson: #"{"workspace_id":"\#(workspaceID)","script":"printf second"}"#
                )
            )
        }.value
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(second?.success, false)
        XCTAssertTrue(second?.output.contains("already running") == true)
        XCTAssertLessThan(elapsed, .seconds(1))
        _ = await first.value
    }

    func testApprovalCommitsOnlyTheExactPresentedPlanRevision() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDocumentPlanIdentityTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try await CourseDocumentRepository.open(
            workspaceID: UUID().uuidString,
            databaseURL: directory.appendingPathComponent(".course/course-library.sqlite"),
            rootTitle: "Approval identity"
        )
        var revisionOne = CourseBrief()
        revisionOne.planID = "swift-concurrency"
        revisionOne.revision = 1
        try await repository.presentPlan(revisionOne)

        var changedContent = revisionOne
        changedContent.title = "Changed without a revision bump"
        do {
            try await repository.approvePlan(changedContent)
            XCTFail("Changed content must not be approved under a reused plan identity")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("plan changed"))
        }

        var revisionTwo = revisionOne
        revisionTwo.revision = 2
        do {
            try await repository.approvePlan(revisionTwo)
            XCTFail("A revision that was never presented must not be approved")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("plan changed"))
        }
        var latestPlanIsApproved = await repository.isLatestPlanApproved()
        XCTAssertFalse(latestPlanIsApproved)

        try await repository.approvePlan(revisionOne)
        latestPlanIsApproved = await repository.isLatestPlanApproved()
        XCTAssertTrue(latestPlanIsApproved)
        try await repository.presentPlan(changedContent)
        latestPlanIsApproved = await repository.isLatestPlanApproved()
        XCTAssertFalse(latestPlanIsApproved)
        try await repository.presentPlan(revisionTwo)
        latestPlanIsApproved = await repository.isLatestPlanApproved()
        XCTAssertFalse(latestPlanIsApproved)
    }

    func testInterruptedPlanRecoveryPreservesANewerPresentedPlan() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDocumentPlanRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try await CourseDocumentRepository.open(
            workspaceID: UUID().uuidString,
            databaseURL: directory.appendingPathComponent(".course/course-library.sqlite"),
            rootTitle: "Recovery identity"
        )
        var oldPlan = CourseBrief()
        oldPlan.planID = "old-hermes-plan"
        oldPlan.revision = 1
        var newerPlan = CourseBrief()
        newerPlan.planID = "newer-device-plan"
        newerPlan.revision = 2
        newerPlan.title = "Plan currently under review"
        try await repository.presentPlan(newerPlan)

        do {
            try await repository.presentPlanForRecoveryIfUnchanged(oldPlan)
            XCTFail("Recovery must not overwrite a different plan already under review")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("preserved"))
        }
        try await repository.approvePlan(newerPlan)
        let newerPlanRemainsCurrent = await repository.isLatestPlanApproved()
        XCTAssertTrue(newerPlanRemainsCurrent)
    }

    func testWritablePlanMirrorsCannotForgeMutationApproval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDocumentApprovalForgeryTests-\(UUID().uuidString)", isDirectory: true)
        let protectedWorkspace = AppleCourseApprovalPolicy
            .protectedMetadataDirectory(courseDirectory: directory)
            .deletingLastPathComponent()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: protectedWorkspace)
        }
        let repository = try await CourseDocumentRepository.open(
            workspaceID: UUID().uuidString,
            databaseURL: directory.appendingPathComponent(".course/course-library.sqlite"),
            rootTitle: "Protected approval"
        )
        var plan = CourseBrief()
        plan.planID = "protected-approval"
        plan.revision = 1
        plan.title = "Protected approval"
        let mirrorDirectory = directory.appendingPathComponent(".course", isDirectory: true)
        try FileManager.default.createDirectory(at: mirrorDirectory, withIntermediateDirectories: true)
        let planData = try JSONEncoder().encode(plan)
        try planData.write(
            to: mirrorDirectory.appendingPathComponent(
                AppleCourseApprovalPolicy.presentedPlanFilename
            )
        )
        try planData.write(
            to: mirrorDirectory.appendingPathComponent(
                AppleCourseApprovalPolicy.approvedPlanFilename
            )
        )

        let root = try await repository.rootPageSnapshot()
        let forgedMutation = await repository.callTool(
            named: NativeEditorMCPToolCatalog.updatePage,
            argumentsJSON: try jsonString([
                "page_id": root.id,
                "expected_revision": root.revision,
                "command": "update_properties",
                "properties": ["title": "Forged"],
            ])
        )
        XCTAssertTrue(forgedMutation.isError)

        try await repository.presentPlan(plan)
        try await repository.approvePlan(plan)
        let authorizedMutation = await repository.callTool(
            named: NativeEditorMCPToolCatalog.updatePage,
            argumentsJSON: try jsonString([
                "page_id": root.id,
                "expected_revision": root.revision,
                "command": "update_properties",
                "properties": ["title": "Authorized"],
            ])
        )
        XCTAssertFalse(authorizedMutation.isError)
    }

    func testOpeningLegacyCourseImportsMarkdownHierarchyOnceIntoNativePages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDocumentMigrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("# Existing course", to: directory.appendingPathComponent("index.md"))
        try write("# Profile\nAlready knows variables.", to: directory.appendingPathComponent("context/learner-profile.md"))
        try write("# Variables\nA complete existing lesson.", to: directory.appendingPathComponent("chapters/01-foundations/variables.md"))
        try write(
            """
            {
              "plan_id": "swift-course",
              "title": "Swift Course",
              "learning_path": [{
                "id": "chapter-1",
                "title": "Foundations",
                "kind": "folder",
                "status": "partially_generated",
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
            """,
            to: directory.appendingPathComponent("course.json")
        )

        let repository = try await CourseDocumentRepository.open(
            workspaceID: "legacy-swift",
            databaseURL: directory.appendingPathComponent(".course/course-library.sqlite"),
            rootTitle: "Fallback title"
        )
        let outline = try await repository.outline()

        XCTAssertEqual(outline.bootstrapStatus, "ready_for_learning")
        XCTAssertEqual(outline.allPages.first?.id, "context-learner-profile")
        XCTAssertEqual(outline.learningPages.first?.id, "chapter-1")
        XCTAssertEqual(outline.learningPages.first?.children.first?.id, "variables")
        let lessonPageID = try XCTUnwrap(outline.learningPages.first?.children.first?.pageID)
        let lesson = try await repository.pageSnapshot(id: lessonPageID)
        XCTAssertTrue(AppFlowyMarkdownCodec().encode(lesson.document).contains("A complete existing lesson."))

        let reopened = try await CourseDocumentRepository.open(
            workspaceID: "legacy-swift",
            databaseURL: directory.appendingPathComponent(".course/course-library.sqlite"),
            rootTitle: "Ignored after migration"
        )
        let reopenedOutline = try await reopened.outline()
        XCTAssertEqual(reopenedOutline.allPages.count, outline.allPages.count)
    }

    func testLearnerEditFlushesBeforeAgentToolAndRejectsStaleRevision() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = try await repository.rootPageSnapshot()
        var learnerDocument = root.document
        learnerDocument.root.children.append(.paragraph("A note written by the learner."))
        try await repository.stageUserEdit(
            pageID: root.id,
            document: learnerDocument
        )

        let staleAgentUpdate = try jsonString([
            "page_id": root.id,
            "expected_revision": root.revision,
            "command": "update_properties",
            "properties": ["title": "Agent title"],
        ])
        let result = await repository.callTool(
            named: NativeEditorMCPToolCatalog.updatePage,
            argumentsJSON: staleAgentUpdate
        )

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.value.objectValue?["code"]?.stringValue, "conflict")
        let saved = try await repository.rootPageSnapshot()
        XCTAssertGreaterThan(saved.revision, root.revision)
        XCTAssertTrue(AppFlowyMarkdownCodec().encode(saved.document).contains("A note written by the learner."))
    }

    func testDelayedLearnerStageMergesAgainstCapturedPreAgentBase() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = try await repository.rootPageSnapshot()
        var learnerDraft = base.document
        learnerDraft.root.children.append(.paragraph("Delayed learner edit"))
        learnerDraft.ensureStableBlockIDs()

        let agentRequest = try jsonString([
            "page_id": base.id,
            "expected_revision": base.revision,
            "command": "insert_content",
            "content": "Agent edit that landed first",
            "position": ["type": "end"],
        ])
        let agentResult = await repository.callTool(
            named: NativeEditorMCPToolCatalog.updatePage,
            argumentsJSON: agentRequest
        )
        XCTAssertFalse(agentResult.isError)

        // This models the UI task being delayed until after the agent commit.
        // The captured pre-agent base must still force a three-way merge even
        // though the tool invalidated the repository's snapshot cache.
        try await repository.stageUserEdit(
            pageID: base.id,
            document: learnerDraft,
            capturedBaseDocument: base.document,
            capturedBaseRevision: base.revision
        )
        _ = try await repository.flushPendingUserEdits()

        let saved = try await repository.rootPageSnapshot()
        let markdown = AppFlowyMarkdownCodec().encode(saved.document)
        XCTAssertTrue(markdown.contains("Delayed learner edit"))
        XCTAssertTrue(markdown.contains("Agent edit that landed first"))
    }

    func testRapidLearnerEditsAdvanceRepositoryRevisionWithoutAStaleUIToken() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = try await repository.rootPageSnapshot()
        var first = root.document
        first.root.children.append(.paragraph("First edit"))
        first.ensureStableBlockIDs()
        try await repository.stageUserEdit(pageID: root.id, document: first)
        let firstFlush = try await repository.flushPendingUserEdits()
        let firstSaved = try XCTUnwrap(firstFlush.last)

        var second = firstSaved.document
        second.root.children[second.root.children.count - 1].delta = .content("Second edit")
        try await repository.stageUserEdit(pageID: root.id, document: second)
        let secondFlush = try await repository.flushPendingUserEdits()
        let secondSaved = try XCTUnwrap(secondFlush.last)

        XCTAssertGreaterThan(firstSaved.revision, root.revision)
        XCTAssertGreaterThan(secondSaved.revision, firstSaved.revision)
        XCTAssertTrue(AppFlowyMarkdownCodec().encode(secondSaved.document).contains("Second edit"))
    }

    @MainActor
    func testEditorModelCanBackspaceContinuouslyAcrossAutosaveBoundaries() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try await repository.rootPageSnapshot()
        let model = CoursePageEditorModel(pageID: root.id, repository: repository)
        await model.load()

        let original = "Why actor isolation matters"
        for remainingLength in stride(from: original.count, through: 3, by: -1) {
            var document = model.document
            document.root.children[0].delta = .content(String(original.prefix(remainingLength)))
            model.userChangedDocument(document)
            if remainingLength.isMultiple(of: 5) {
                try await Task.sleep(for: .milliseconds(90))
            }
        }
        await model.flush()

        XCTAssertNil(model.errorMessage)
        let saved = try await repository.pageSnapshot(id: root.id)
        XCTAssertEqual(saved.document.root.children[0].delta?.plainText, "Why")
    }

    @MainActor
    func testExternalAgentChangeCannotReplaceAnUnstagedVisibleEdit() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try await repository.rootPageSnapshot()
        let model = CoursePageEditorModel(
            pageID: root.id,
            repository: repository,
            stagingDelay: .milliseconds(250)
        )
        await model.load()

        var learnerDraft = model.document
        learnerDraft.root.children.append(.paragraph("Visible learner edit"))
        learnerDraft.ensureStableBlockIDs()
        model.userChangedDocument(learnerDraft)

        let agentRequest = try jsonString([
            "page_id": root.id,
            "expected_revision": root.revision,
            "command": "insert_content",
            "content": "Concurrent agent edit",
            "position": ["type": "end"],
        ])
        let agentResult = await repository.callTool(
            named: NativeEditorMCPToolCatalog.updatePage,
            argumentsJSON: agentRequest
        )
        XCTAssertFalse(agentResult.isError)

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(AppFlowyMarkdownCodec().encode(model.document).contains("Visible learner edit"))

        await model.flush()
        let finalMarkdown = AppFlowyMarkdownCodec().encode(model.document)
        XCTAssertTrue(finalMarkdown.contains("Visible learner edit"))
        XCTAssertTrue(finalMarkdown.contains("Concurrent agent edit"))
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testFlushIncludesAnEditThatArrivesWhileItIsSuspended() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try await repository.rootPageSnapshot()
        let model = CoursePageEditorModel(
            pageID: root.id,
            repository: repository,
            stagingDelay: .milliseconds(200)
        )
        await model.load()

        var first = model.document
        first.root.children.append(.paragraph("First queued edit"))
        first.ensureStableBlockIDs()
        model.userChangedDocument(first)

        let flushTask = Task { await model.flush() }
        try await Task.sleep(for: .milliseconds(50))

        var newest = model.document
        newest.root.children.append(.paragraph("Newest edit during flush"))
        newest.ensureStableBlockIDs()
        model.userChangedDocument(newest)
        await flushTask.value

        let visibleMarkdown = AppFlowyMarkdownCodec().encode(model.document)
        XCTAssertTrue(visibleMarkdown.contains("Newest edit during flush"))
        let saved = try await repository.pageSnapshot(id: root.id)
        XCTAssertTrue(AppFlowyMarkdownCodec().encode(saved.document).contains("Newest edit during flush"))
        XCTAssertNil(model.errorMessage)
    }

    func testHundredsOfKeystrokesCoalesceToTheNewestCrashSafeDraft() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = try await repository.rootPageSnapshot()
        for index in 0 ..< 250 {
            var draft = root.document
            draft.root.children.append(.paragraph("Keystroke \(index)"))
            draft.ensureStableBlockIDs()
            try await repository.stageUserEdit(pageID: root.id, document: draft)
        }

        let journalURL = directory.appendingPathComponent(".course/pending-user-edits.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        let flush = try await repository.flushPendingUserEdits()
        let saved = try XCTUnwrap(flush.last)
        XCTAssertTrue(AppFlowyMarkdownCodec().encode(saved.document).contains("Keystroke 249"))
        XCTAssertFalse(AppFlowyMarkdownCodec().encode(saved.document).contains("Keystroke 248"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testConcurrentFlushCallersShareOneSerializedSave() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = try await repository.rootPageSnapshot()
        var draft = root.document
        draft.root.children.append(.paragraph("Saved once"))
        draft.ensureStableBlockIDs()
        try await repository.stageUserEdit(pageID: root.id, document: draft)

        async let first = repository.flushPendingUserEdits()
        async let second = repository.flushPendingUserEdits()
        _ = try await (first, second)

        let saved = try await repository.rootPageSnapshot()
        XCTAssertEqual(saved.revision, root.revision + 1)
        XCTAssertTrue(AppFlowyMarkdownCodec().encode(saved.document).contains("Saved once"))
    }

    func testUnflushedDraftRecoversAfterRepositoryRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDocumentDraftRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent(".course/course-library.sqlite")

        let pageID = try await stageDraftWithoutFlushing(databaseURL: databaseURL)
        let journalURL = directory.appendingPathComponent(".course/pending-user-edits.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        let reopened = try await CourseDocumentRepository.open(
            workspaceID: UUID().uuidString,
            databaseURL: databaseURL,
            rootTitle: "Ignored after recovery"
        )
        let recovered = try await reopened.pageSnapshot(id: pageID)
        XCTAssertTrue(AppFlowyMarkdownCodec().encode(recovered.document).contains("Survives termination"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testJournalWriteFailureStillAutosavesTheInMemoryDraft() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent(".course/course-library.sqlite")
        let root = try await repository.rootPageSnapshot()
        let journalURL = directory.appendingPathComponent(".course/pending-user-edits.json")
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)

        var draft = root.document
        draft.root.children.append(.paragraph("Saved after journal failure"))
        draft.ensureStableBlockIDs()
        do {
            try await repository.stageUserEdit(pageID: root.id, document: draft)
            XCTFail("Expected the journal write to fail while its path is a directory")
        } catch {
            // The repository must retain the draft and schedule a prompt SQLite save.
        }

        try await Task.sleep(for: .milliseconds(500))
        let external = try await NativeEditorMCPService.open(databaseURL: databaseURL)
        let saved = try await external.pageSnapshot(id: root.id)
        XCTAssertTrue(AppFlowyMarkdownCodec().encode(saved.document).contains("Saved after journal failure"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testUnreadableDraftJournalBlocksOpenAndRemainsPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDocumentCorruptDraftTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent(".course/course-library.sqlite")
        let repository = try await CourseDocumentRepository.open(
            workspaceID: UUID().uuidString,
            databaseURL: databaseURL,
            rootTitle: "Recovery course"
        )
        _ = try await repository.rootPageSnapshot()

        let journalURL = directory.appendingPathComponent(".course/pending-user-edits.json")
        let corruptBytes = Data("not valid draft json".utf8)
        try corruptBytes.write(to: journalURL, options: .atomic)

        do {
            _ = try await CourseDocumentRepository.open(
                workspaceID: UUID().uuidString,
                databaseURL: databaseURL,
                rootTitle: "Must not silently open"
            )
            XCTFail("Expected unreadable recovery data to block opening")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("preserved"))
        }
        XCTAssertEqual(try Data(contentsOf: journalURL), corruptBytes)
    }

    func testExternalWriterAndLearnerDraftMergeIndependentBlocks() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent(".course/course-library.sqlite")

        let root = try await repository.rootPageSnapshot()
        var learner = root.document
        learner.root.children.append(.paragraph("Learner note"))
        learner.ensureStableBlockIDs()
        try await repository.stageUserEdit(pageID: root.id, document: learner)

        let external = try await NativeEditorMCPService.open(databaseURL: databaseURL)
        var agent = root.document
        agent.root.children.append(.paragraph("Agent explainer"))
        agent.ensureStableBlockIDs()
        _ = try await external.saveDocument(agent, pageID: root.id, expectedRevision: root.revision)

        _ = try await repository.flushPendingUserEdits()
        let merged = try await repository.rootPageSnapshot()
        let markdown = AppFlowyMarkdownCodec().encode(merged.document)
        XCTAssertTrue(markdown.contains("Learner note"))
        XCTAssertTrue(markdown.contains("Agent explainer"))
    }

    func testSameBlockCollisionKeepsLearnerEditAndRetainsAgentVersionInHistory() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent(".course/course-library.sqlite")

        let root = try await repository.rootPageSnapshot()
        var seeded = root.document
        seeded.root.children.append(.paragraph("Shared paragraph"))
        seeded.ensureStableBlockIDs()
        try await repository.stageUserEdit(pageID: root.id, document: seeded)
        let baseFlush = try await repository.flushPendingUserEdits()
        let base = try XCTUnwrap(baseFlush.last)

        var learner = base.document
        learner.root.children[learner.root.children.count - 1].delta = .content("Learner version")
        try await repository.stageUserEdit(pageID: root.id, document: learner)

        let external = try await NativeEditorMCPService.open(databaseURL: databaseURL)
        var agent = base.document
        agent.root.children[agent.root.children.count - 1].delta = .content("Agent version")
        _ = try await external.saveDocument(agent, pageID: root.id, expectedRevision: base.revision)

        _ = try await repository.flushPendingUserEdits()
        let saved = try await repository.rootPageSnapshot()
        XCTAssertTrue(AppFlowyMarkdownCodec().encode(saved.document).contains("Learner version"))

        let library = try SQLiteLibraryStore(url: databaseURL)
        let history = try await library.history(for: root.id)
        var historicalDocuments: [BlockDocument] = []
        for entry in history {
            historicalDocuments.append(try await library.document(forHistoryEntry: entry.id))
        }
        XCTAssertTrue(historicalDocuments.contains {
            AppFlowyMarkdownCodec().encode($0).contains("Agent version")
        })
    }

    func testLearnerBlockDeletionWinsConcurrentAgentEditWithoutDestroyingHistory() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent(".course/course-library.sqlite")

        let root = try await repository.rootPageSnapshot()
        var seeded = root.document
        seeded.root.children.append(.paragraph("Delete this paragraph"))
        seeded.ensureStableBlockIDs()
        try await repository.stageUserEdit(pageID: root.id, document: seeded)
        let seedFlush = try await repository.flushPendingUserEdits()
        let base = try XCTUnwrap(seedFlush.last)

        var learner = base.document
        learner.root.children.removeLast()
        try await repository.stageUserEdit(pageID: root.id, document: learner)

        let external = try await NativeEditorMCPService.open(databaseURL: databaseURL)
        var agent = base.document
        agent.root.children[agent.root.children.count - 1].delta = .content("Agent edited deleted paragraph")
        _ = try await external.saveDocument(agent, pageID: root.id, expectedRevision: base.revision)

        _ = try await repository.flushPendingUserEdits()
        let saved = try await repository.rootPageSnapshot()
        let savedMarkdown = AppFlowyMarkdownCodec().encode(saved.document)
        XCTAssertFalse(savedMarkdown.contains("Delete this paragraph"))
        XCTAssertFalse(savedMarkdown.contains("Agent edited deleted paragraph"))

        let library = try SQLiteLibraryStore(url: databaseURL)
        let history = try await library.history(for: root.id)
        var historicalDocuments: [BlockDocument] = []
        for entry in history {
            historicalDocuments.append(try await library.document(forHistoryEntry: entry.id))
        }
        XCTAssertTrue(historicalDocuments.contains {
            AppFlowyMarkdownCodec().encode($0).contains("Agent edited deleted paragraph")
        })
    }

    @MainActor
    func testAsyncAgentMutationPublishesOnlyAfterBackgroundCommitCompletes() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try await repository.rootPageSnapshot()
        let changes = await repository.changes()
        let committed = expectation(description: "async native page commit published")
        let observer = Task {
            for await change in changes where change.replacesDocument {
                committed.fulfill()
                return
            }
        }
        defer { observer.cancel() }

        let request = try jsonString([
            "parent": ["page_id": root.id],
            "pages": [[
                "properties": ["title": "Async lesson"],
                "content": "# Async lesson\nCommitted in the background.",
            ]],
            "allow_async": true,
        ])
        let queued = await repository.callTool(
            named: NativeEditorMCPToolCatalog.createPages,
            argumentsJSON: request
        )
        XCTAssertFalse(queued.isError)
        XCTAssertEqual(queued.value.objectValue?["status"]?.stringValue, "succeeded")

        await fulfillment(of: [committed], timeout: 3)
        let workspace = try await repository.workspaceSnapshot()
        XCTAssertTrue(workspace.pages.values.contains { $0.title == "Async lesson" })
    }

    @MainActor
    func testAsyncMutationKeepsOldPlanLeaseUntilCommitBeforeNewPlanPresentation() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try await repository.rootPageSnapshot()
        let request = try jsonString([
            "parent": ["page_id": root.id],
            "pages": (0..<40).map { index in
                [
                    "properties": ["title": "Leased async lesson \(index)"],
                    "content": "# Leased async lesson \(index)\nCommitted under revision one.",
                ]
            },
            "allow_async": true,
        ])

        let mutation = Task {
            await repository.callTool(
                named: NativeEditorMCPToolCatalog.createPages,
                argumentsJSON: request
            )
        }
        await Task.yield()
        var replacement = CourseBrief()
        replacement.planID = "replacement-plan"
        replacement.revision = 2
        let presentation = Task {
            try await repository.presentPlan(replacement)
        }

        let mutationResult = await mutation.value
        XCTAssertFalse(mutationResult.isError)
        XCTAssertEqual(mutationResult.value.objectValue?["status"]?.stringValue, "succeeded")
        try await presentation.value
        let latestPlanIsApproved = await repository.isLatestPlanApproved()
        XCTAssertFalse(latestPlanIsApproved)
        let workspace = try await repository.workspaceSnapshot()
        XCTAssertEqual(
            workspace.pages.values.filter { $0.title.hasPrefix("Leased async lesson") }.count,
            40
        )
    }

    func testCourseOutlineUsesNativePageMetadataAndFiltersContextFromLearnTab() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = try await repository.rootPageSnapshot()
        let rootUpdate = try jsonString([
            "page_id": root.id,
            "expected_revision": root.revision,
            "command": "update_properties",
            "properties": [
                "course_node_id": "swift-course",
                "course_role": "course",
                "bootstrap_status": "ready_for_learning",
            ],
        ])
        let rootResult = await repository.callTool(
            named: NativeEditorMCPToolCatalog.updatePage,
            argumentsJSON: rootUpdate
        )
        XCTAssertFalse(rootResult.isError)

        let createPages = try jsonString([
            "parent": ["page_id": root.id],
            "pages": [
                [
                    "properties": [
                        "title": "Learner profile",
                        "course_node_id": "learner-profile",
                        "course_role": "context",
                        "generation_status": "generated",
                    ],
                    "content": "# Learner profile\nEvidence and goals.",
                ],
                [
                    "properties": [
                        "title": "Chapter 1 · Foundations",
                        "course_node_id": "chapter-1",
                        "course_role": "chapter",
                        "generation_status": "generated",
                    ],
                    "content": "# Foundations\nThe first generated chapter.",
                ],
                [
                    "properties": [
                        "title": "Chapter 2 · Concurrency",
                        "course_node_id": "chapter-2",
                        "course_role": "chapter",
                        "generation_status": "pending_generation",
                    ],
                    "content": "# Concurrency\nPlanned for later.",
                ],
            ],
        ])
        let createResult = await repository.callTool(
            named: NativeEditorMCPToolCatalog.createPages,
            argumentsJSON: createPages
        )
        XCTAssertFalse(createResult.isError)

        let outline = try await repository.outline()
        XCTAssertEqual(outline.bootstrapStatus, "ready_for_learning")
        XCTAssertEqual(outline.allPages.count, 3)
        XCTAssertEqual(outline.learningPages.map(\.id), ["chapter-1", "chapter-2"])
        XCTAssertEqual(outline.learningPages.map(\.status), [.generated, .pendingGeneration])
        XCTAssertTrue(outline.isReadyForLearning)
        XCTAssertTrue(outline.learningPages.allSatisfy { $0.pageID != nil })
    }

    func testCourseOutlineMarksPendingChapterGeneratedWhenAllChildrenAreGenerated() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = try await repository.rootPageSnapshot()
        let rootResult = await repository.callTool(
            named: NativeEditorMCPToolCatalog.updatePage,
            argumentsJSON: try jsonString([
                "page_id": root.id,
                "expected_revision": root.revision,
                "command": "update_properties",
                "properties": [
                    "course_node_id": "swift-course",
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

        let chapterOutline = try await repository.outline()
        let chapter = try XCTUnwrap(chapterOutline.learningPages.first)
        let lessonResult = await repository.callTool(
            named: NativeEditorMCPToolCatalog.createPages,
            argumentsJSON: try jsonString([
                "parent": ["page_id": try XCTUnwrap(chapter.pageID)],
                "pages": [[
                    "properties": [
                        "title": "Lesson 1",
                        "course_node_id": "lesson-1",
                        "course_role": "lesson",
                        "generation_status": "generated",
                    ],
                    "content": "# Lesson 1\nGenerated content.",
                ]],
            ])
        )
        XCTAssertFalse(lessonResult.isError)

        let outline = try await repository.outline()
        XCTAssertEqual(outline.learningPages.first?.status, .generated)
        XCTAssertEqual(outline.learningPages.first?.children.first?.status, .generated)
        XCTAssertTrue(outline.isReadyForLearning)
    }

    func testCourseOutlineKeepsTitledPendingChildrenGeneratableAndRollsUpMixedFolders() async throws {
        let (repository, directory) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = try await repository.rootPageSnapshot()
        let chapterResult = await repository.callTool(
            named: NativeEditorMCPToolCatalog.createPages,
            argumentsJSON: try jsonString([
                "parent": ["page_id": root.id],
                "pages": [
                    [
                        "properties": [
                            "title": "All pending",
                            "course_node_id": "all-pending",
                            "course_role": "chapter",
                            "generation_status": "generated",
                        ],
                        "content": "# All pending",
                    ],
                    [
                        "properties": [
                            "title": "Mixed progress",
                            "course_node_id": "mixed-progress",
                            "course_role": "chapter",
                            "generation_status": "pending_generation",
                        ],
                        "content": "# Mixed progress",
                    ],
                ],
            ])
        )
        XCTAssertFalse(chapterResult.isError)

        var outline = try await repository.outline()
        let allPendingPageID = try XCTUnwrap(
            outline.learningPages.first(where: { $0.id == "all-pending" })?.pageID
        )
        let mixedPageID = try XCTUnwrap(
            outline.learningPages.first(where: { $0.id == "mixed-progress" })?.pageID
        )

        for (parentPageID, pages) in [
            (
                allPendingPageID,
                [
                    ("pending-1", "1.1 · Planned title", "pending_generation"),
                    ("pending-2", "1.2 · Another planned title", "pending_generation"),
                ]
            ),
            (
                mixedPageID,
                [
                    ("mixed-1", "2.1 · Ready lesson", "generated"),
                    ("mixed-2", "2.2 · Pending lesson", "pending_generation"),
                ]
            ),
        ] {
            let result = await repository.callTool(
                named: NativeEditorMCPToolCatalog.createPages,
                argumentsJSON: try jsonString([
                    "parent": ["page_id": parentPageID],
                    "pages": pages.map { id, title, status in
                        [
                            "properties": [
                                "title": title,
                                "course_node_id": id,
                                "course_role": "lesson",
                                "generation_status": status,
                            ],
                            "content": "# \(title)",
                        ]
                    },
                ])
            )
            XCTAssertFalse(result.isError)
        }

        outline = try await repository.outline()
        let allPending = try XCTUnwrap(
            outline.learningPages.first(where: { $0.id == "all-pending" })
        )
        XCTAssertEqual(allPending.status, .pendingGeneration)
        XCTAssertEqual(
            allPending.children.map(\.title),
            ["1.1 · Planned title", "1.2 · Another planned title"]
        )
        XCTAssertTrue(allPending.children.allSatisfy { $0.status == .pendingGeneration })

        let mixed = try XCTUnwrap(
            outline.learningPages.first(where: { $0.id == "mixed-progress" })
        )
        XCTAssertEqual(mixed.status, .partiallyGenerated)
        XCTAssertEqual(mixed.children.map(\.status), [.generated, .pendingGeneration])
    }

    private func makeRepository() async throws -> (CourseDocumentRepository, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDocumentRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = directory.appendingPathComponent(".course/course-library.sqlite")
        let repository = try await CourseDocumentRepository.open(
            workspaceID: UUID().uuidString,
            databaseURL: databaseURL,
            rootTitle: "Test course"
        )
        var plan = CourseBrief()
        plan.planID = "test-course-plan"
        plan.revision = 1
        try await repository.presentPlan(plan)
        try await repository.approvePlan(plan)
        return (repository, directory)
    }

    private func stageDraftWithoutFlushing(databaseURL: URL) async throws -> String {
        let repository = try await CourseDocumentRepository.open(
            workspaceID: UUID().uuidString,
            databaseURL: databaseURL,
            rootTitle: "Recovery course",
            autosaveDelay: .seconds(60)
        )
        let root = try await repository.rootPageSnapshot()
        var draft = root.document
        draft.root.children.append(.paragraph("Survives termination"))
        draft.ensureStableBlockIDs()
        try await repository.stageUserEdit(pageID: root.id, document: draft)
        return root.id
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
