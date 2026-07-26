import Foundation
import NativeBlockEditorCore
import NativeEditorMCP
import Observation

private enum CourseDocumentRecoveryError: LocalizedError {
    case unreadableDraft(URL, Error)

    var errorDescription: String? {
        switch self {
        case let .unreadableDraft(url, error):
            "An unsaved course draft could not be read and was preserved at \(url.lastPathComponent). "
                + "The course was not opened to avoid losing it. \(error.localizedDescription)"
        }
    }
}

struct CourseDocumentChange: Sendable {
    let pageID: String?
    let sequence: Int
    let snapshot: NativeEditorPageSnapshot?
    let replacesDocument: Bool
    let sourceEditID: UUID?
    let hasPendingUserEdit: Bool
    let errorMessage: String?
}

struct CourseDocumentOutline: Sendable {
    let rootPageID: String
    let bootstrapStatus: String?
    let allPages: [CourseLearningNode]
    let learningPages: [CourseLearningNode]

    var isReadyForLearning: Bool {
        bootstrapStatus == "ready_for_learning"
            && learningPages.contains(where: Self.containsGeneratedLearningPage)
    }

    private static func containsGeneratedLearningPage(_ node: CourseLearningNode) -> Bool {
        node.status == .generated
            || node.status == .partiallyGenerated
            || node.children.contains(where: containsGeneratedLearningPage)
    }
}

struct CourseSyncRemoteApplyResult: Equatable, Sendable {
    let changedPageIDs: [String]
    let resultingChecksum: String
}

enum CourseCloudSyncRepositoryError: Error, Equatable, LocalizedError {
    case workspaceMismatch
    case localWorkspaceChanged
    case structuralConflict([String])
    case contentConflict([String])

    var errorDescription: String? {
        switch self {
        case .workspaceMismatch:
            "The cloud course belongs to a different workspace."
        case .localWorkspaceChanged:
            "The local course changed before the cloud generation could be applied."
        case .structuralConflict(let ids):
            "Course structure changed concurrently for: \(ids.joined(separator: ", "))."
        case .contentConflict(let ids):
            "Course pages changed concurrently without a safe common base: \(ids.joined(separator: ", "))."
        }
    }
}

actor CourseDocumentRepository {
    let workspaceID: String

    private struct PendingUserEdit: Codable, Sendable {
        var document: BlockDocument
        var baseDocument: BlockDocument?
        var baseRevision: Int64?
        var sourceEditID: UUID?
    }

    private struct ActiveFlush: Sendable {
        let id: UUID
        let task: Task<[NativeEditorPageSnapshot], Error>
    }

    private let service: NativeEditorMCPService
    private let pendingEditsURL: URL
    private let autosaveDelay: Duration
    private var pendingUserEdits: [String: PendingUserEdit] = [:]
    private var pendingSaveTask: Task<Void, Never>?
    private var activeFlush: ActiveFlush?
    private var latestSnapshots: [String: NativeEditorPageSnapshot] = [:]
    private var autosaveRetryAttempt = 0
    private var asyncTaskMonitors: [String: Task<Void, Never>] = [:]
    private var continuations: [UUID: AsyncStream<CourseDocumentChange>.Continuation] = [:]
    private var changeSequence = 0

    private init(
        workspaceID: String,
        service: NativeEditorMCPService,
        pendingEditsURL: URL,
        autosaveDelay: Duration,
        recoveredUserEdits: [String: PendingUserEdit]
    ) {
        self.workspaceID = workspaceID
        self.service = service
        self.pendingEditsURL = pendingEditsURL
        self.autosaveDelay = autosaveDelay
        pendingUserEdits = recoveredUserEdits
    }

    static func open(
        workspaceID: String,
        databaseURL: URL,
        rootTitle: String,
        autosaveDelay: Duration = .milliseconds(350)
    ) async throws -> CourseDocumentRepository {
        let databaseAlreadyExists = FileManager.default.fileExists(atPath: databaseURL.path)
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let courseRoot = databaseURL.deletingLastPathComponent().deletingLastPathComponent()
        let seed = databaseAlreadyExists
            ? nil
            : LegacyCoursePageImporter.makeSeedWorkspace(
                workspaceID: workspaceID,
                rootTitle: rootTitle,
                courseRoot: courseRoot
            )
        let service = try await NativeEditorMCPService.open(
            databaseURL: databaseURL,
            seedWorkspace: seed
        )
        let pendingEditsURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("pending-user-edits.json")
        let recoveredUserEdits = try Self.loadPendingUserEdits(from: pendingEditsURL)
        let repository = CourseDocumentRepository(
            workspaceID: workspaceID,
            service: service,
            pendingEditsURL: pendingEditsURL,
            autosaveDelay: autosaveDelay,
            recoveredUserEdits: recoveredUserEdits
        )
        if !recoveredUserEdits.isEmpty {
            await repository.scheduleAutosave(after: .milliseconds(50))
        }
        Task {
            await CourseCloudSyncEngine.shared.queueRepositoryChangesIfNeeded(
                repository: repository
            )
        }
        return repository
    }

    func rootPageSnapshot() async throws -> NativeEditorPageSnapshot {
        try await flushPendingUserEdits()
        return record(try await service.rootPageSnapshot())
    }

    func pageSnapshot(id: String) async throws -> NativeEditorPageSnapshot {
        try await flushPendingUserEdits()
        return record(try await service.pageSnapshot(id: id))
    }

    func workspaceSnapshot() async throws -> PageWorkspace {
        try await flushPendingUserEdits()
        return try await service.workspaceSnapshot()
    }

    func exportSyncSnapshot(
        generationID: String = UUID().uuidString.lowercased(),
        previousGenerationID: String? = nil,
        version: CourseSyncVersionVector = .init()
    ) async throws -> CourseSyncWorkspaceSnapshot {
        try CourseSyncWorkspaceSnapshot(
            workspaceID: workspaceID,
            workspace: try await workspaceSnapshot(),
            generationID: generationID,
            previousGenerationID: previousGenerationID,
            version: version
        )
    }

    func pendingSyncMutationReceipts(limit: Int = 256) async throws -> [LibraryMutationReceipt] {
        try await service.pendingSyncMutationReceipts(limit: limit)
    }

    func acknowledgeSyncMutationReceipts(ids: [String]) async throws {
        try await service.acknowledgeSyncMutationReceipts(ids: ids)
    }

    /// Applies a fetched cloud generation through the repository's serialized
    /// lane. The caller supplies the exact base generation it previously
    /// observed; unknown-base or structural conflicts remain unapplied in the
    /// durable cloud inbox for explicit recovery UI.
    @discardableResult
    func applyRemoteSyncSnapshot(
        _ remoteSnapshot: CourseSyncWorkspaceSnapshot,
        baseSnapshot: CourseSyncWorkspaceSnapshot
    ) async throws -> CourseSyncRemoteApplyResult {
        guard remoteSnapshot.manifest.workspaceID == workspaceID,
              baseSnapshot.manifest.workspaceID == workspaceID else {
            throw CourseCloudSyncRepositoryError.workspaceMismatch
        }
        try await flushPendingUserEdits()
        let localSnapshot = try CourseSyncWorkspaceSnapshot(
            workspaceID: workspaceID,
            workspace: try await service.workspaceSnapshot(),
            generationID: "local-comparison"
        )

        if localSnapshot.checksum == remoteSnapshot.checksum {
            return CourseSyncRemoteApplyResult(
                changedPageIDs: [],
                resultingChecksum: localSnapshot.checksum
            )
        }
        if remoteSnapshot.checksum == baseSnapshot.checksum {
            return CourseSyncRemoteApplyResult(
                changedPageIDs: [],
                resultingChecksum: localSnapshot.checksum
            )
        }

        let merged: PageWorkspace
        if localSnapshot.checksum == baseSnapshot.checksum {
            merged = try remoteSnapshot.validatedWorkspace()
        } else {
            merged = try CourseSyncWorkspaceMerger.merge(
                base: baseSnapshot,
                local: localSnapshot,
                remote: remoteSnapshot
            )
        }

        try await service.replaceWorkspace(merged)
        latestSnapshots.removeAll()
        let mergedChecksums = Dictionary(
            uniqueKeysWithValues: try merged.pages.values.map {
                ($0.id, try CourseSyncPageDocument($0).checksum)
            }
        )
        let changedPageIDs = Set(localSnapshot.pages.map(\.id))
            .union(remoteSnapshot.pages.map(\.id))
            .filter { pageID in
                localSnapshot.pages.first(where: { $0.id == pageID })?.checksum
                    != mergedChecksums[pageID]
            }
            .sorted()
        publish(pageID: nil, replacesDocument: true)
        let result = try CourseSyncWorkspaceSnapshot(
            workspaceID: workspaceID,
            workspace: merged,
            generationID: remoteSnapshot.manifest.generationID,
            previousGenerationID: remoteSnapshot.manifest.previousGenerationID,
            version: localSnapshot.manifest.version.merged(with: remoteSnapshot.manifest.version)
        )
        return CourseSyncRemoteApplyResult(
            changedPageIDs: changedPageIDs,
            resultingChecksum: result.checksum
        )
    }

    /// Replaces a workspace only when the caller proves the local content is
    /// still the exact staging/base snapshot it inspected.
    func materializeRemoteSyncSnapshot(
        _ remoteSnapshot: CourseSyncWorkspaceSnapshot,
        expectedLocalChecksum: String
    ) async throws {
        guard remoteSnapshot.manifest.workspaceID == workspaceID else {
            throw CourseCloudSyncRepositoryError.workspaceMismatch
        }
        try await flushPendingUserEdits()
        let localSnapshot = try CourseSyncWorkspaceSnapshot(
            workspaceID: workspaceID,
            workspace: try await service.workspaceSnapshot(),
            generationID: "materialization-check"
        )
        guard localSnapshot.checksum == expectedLocalChecksum else {
            throw CourseCloudSyncRepositoryError.localWorkspaceChanged
        }
        try await service.replaceWorkspace(try remoteSnapshot.validatedWorkspace())
        latestSnapshots.removeAll()
        publish(pageID: nil, replacesDocument: true)
    }

    func outline() async throws -> CourseDocumentOutline {
        let workspace = try await workspaceSnapshot()
        guard let root = workspace.page(id: workspace.rootPageID) else {
            throw NativeEditorMCPError.pageNotFound(workspace.rootPageID)
        }
        let allPages = workspace.children(of: root.id).map { pageNode($0, workspace: workspace) }
        let learningPages = allPages.filter { node in
            guard let page = workspace.page(id: node.pageID ?? node.id) else { return true }
            let role = page.document.root.data["course_role"]?.stringValue
            return role != "context" && role != "agent_notes"
        }
        return CourseDocumentOutline(
            rootPageID: root.id,
            bootstrapStatus: root.document.root.data["course_bootstrap_status"]?.stringValue,
            allPages: allPages,
            learningPages: learningPages
        )
    }

    func stageUserEdit(
        pageID: String,
        document: BlockDocument,
        capturedBaseDocument: BlockDocument? = nil,
        capturedBaseRevision: Int64? = nil,
        sourceEditID: UUID? = nil
    ) throws {
        if var existing = pendingUserEdits[pageID] {
            existing.document = document
            existing.sourceEditID = sourceEditID
            pendingUserEdits[pageID] = existing
        } else {
            let base = latestSnapshots[pageID]
            pendingUserEdits[pageID] = PendingUserEdit(
                document: document,
                baseDocument: base?.document ?? capturedBaseDocument,
                baseRevision: base?.revision ?? capturedBaseRevision,
                sourceEditID: sourceEditID
            )
        }

        autosaveRetryAttempt = 0
        do {
            try persistPendingUserEdits()
            scheduleAutosave(after: autosaveDelay)
        } catch {
            // The draft is still retained by the repository actor. Persist it
            // into SQLite promptly instead of leaving it idle just because the
            // crash-recovery journal was temporarily unavailable.
            scheduleAutosave(after: .milliseconds(50))
            throw error
        }
    }

    @discardableResult
    func flushPendingUserEdits() async throws -> [NativeEditorPageSnapshot] {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        var snapshots: [NativeEditorPageSnapshot] = []

        while activeFlush != nil || !pendingUserEdits.isEmpty {
            let flush: ActiveFlush
            if let existing = activeFlush {
                flush = existing
            } else {
                let id = UUID()
                let task = Task<[NativeEditorPageSnapshot], Error> { [weak self] in
                    guard let self else { return [] }
                    return try await self.savePendingBatch()
                }
                flush = ActiveFlush(id: id, task: task)
                activeFlush = flush
            }

            do {
                snapshots.append(contentsOf: try await flush.task.value)
                if activeFlush?.id == flush.id {
                    activeFlush = nil
                }
            } catch {
                if activeFlush?.id == flush.id {
                    activeFlush = nil
                }
                throw error
            }
        }

        if !snapshots.isEmpty {
            scheduleCloudSync()
        }
        return snapshots
    }

    private func savePendingBatch() async throws -> [NativeEditorPageSnapshot] {
        let batch = pendingUserEdits
        pendingUserEdits.removeAll()
        var unsaved = batch
        var snapshots: [NativeEditorPageSnapshot] = []

        for pageID in batch.keys.sorted() {
            guard let edit = unsaved.removeValue(forKey: pageID) else { continue }
            do {
                let snapshot = try await saveUserEdit(edit, pageID: pageID)
                latestSnapshots[pageID] = snapshot
                snapshots.append(snapshot)

                if var queued = pendingUserEdits[pageID] {
                    queued.document = CourseDocumentThreeWayMerger.merge(
                        base: edit.document,
                        local: queued.document,
                        remote: snapshot.document
                    )
                    queued.baseDocument = snapshot.document
                    queued.baseRevision = snapshot.revision
                    pendingUserEdits[pageID] = queued
                }

                do {
                    try persistPendingUserEdits()
                } catch {
                    publishFailure(pageID: pageID, error: error)
                }
                publish(
                    pageID: pageID,
                    snapshot: snapshot,
                    replacesDocument: pendingUserEdits[pageID] == nil
                        && !CourseDocumentThreeWayMerger.semanticallyEqual(snapshot.document, edit.document),
                    sourceEditID: edit.sourceEditID,
                    hasPendingUserEdit: pendingUserEdits[pageID] != nil
                )
            } catch {
                requeue(edit, pageID: pageID)
                for (remainingPageID, remainingEdit) in unsaved {
                    requeue(remainingEdit, pageID: remainingPageID)
                }
                try? persistPendingUserEdits()
                throw error
            }
        }

        return snapshots
    }

    private func saveUserEdit(
        _ edit: PendingUserEdit,
        pageID: String
    ) async throws -> NativeEditorPageSnapshot {
        var baseDocument = edit.baseDocument
        var expectedRevision = edit.baseRevision
        if baseDocument == nil || expectedRevision == nil {
            let snapshot = record(try await service.pageSnapshot(id: pageID))
            baseDocument = snapshot.document
            expectedRevision = snapshot.revision
        }

        var candidate = edit.document
        for _ in 0 ..< 8 {
            do {
                return try await service.saveDocument(
                    candidate,
                    pageID: pageID,
                    expectedRevision: expectedRevision ?? 0
                )
            } catch NativeEditorMCPError.revisionConflict {
                let remote = record(try await service.pageSnapshot(id: pageID))
                candidate = CourseDocumentThreeWayMerger.merge(
                    base: baseDocument ?? remote.document,
                    local: candidate,
                    remote: remote.document
                )
                expectedRevision = remote.revision
            }
        }

        let actualSnapshot = try await service.pageSnapshot(id: pageID)
        throw NativeEditorMCPError.revisionConflict(
            pageID: pageID,
            expected: expectedRevision ?? 0,
            actual: actualSnapshot.revision
        )
    }

    private func requeue(_ edit: PendingUserEdit, pageID: String) {
        if var newer = pendingUserEdits[pageID] {
            if newer.baseDocument == nil {
                newer.baseDocument = edit.baseDocument
                newer.baseRevision = edit.baseRevision
            }
            pendingUserEdits[pageID] = newer
        } else {
            pendingUserEdits[pageID] = edit
        }
    }

    private func record(_ snapshot: NativeEditorPageSnapshot) -> NativeEditorPageSnapshot {
        latestSnapshots[snapshot.id] = snapshot
        return snapshot
    }

    private func scheduleAutosave(after delay: Duration) {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                _ = try await self.flushPendingUserEdits()
                await self.autosaveDidSucceed()
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                await self.autosaveDidFail(error)
            }
        }
    }

    private func autosaveDidSucceed() {
        autosaveRetryAttempt = 0
    }

    private func autosaveDidFail(_ error: Error) {
        let pageIDs = pendingUserEdits.keys.sorted()
        for pageID in pageIDs {
            publishFailure(pageID: pageID, error: error)
        }
        guard !pendingUserEdits.isEmpty else { return }
        autosaveRetryAttempt = min(autosaveRetryAttempt + 1, 6)
        let seconds = min(30, 1 << autosaveRetryAttempt)
        scheduleAutosave(after: .seconds(seconds))
    }

    private func persistPendingUserEdits() throws {
        if pendingUserEdits.isEmpty {
            if FileManager.default.fileExists(atPath: pendingEditsURL.path) {
                try FileManager.default.removeItem(at: pendingEditsURL)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: pendingEditsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(pendingUserEdits)
        try data.write(
            to: pendingEditsURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private static func loadPendingUserEdits(from url: URL) throws -> [String: PendingUserEdit] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return try JSONDecoder().decode([String: PendingUserEdit].self, from: Data(contentsOf: url))
        } catch {
            // Never turn an unreadable draft into an apparently empty draft.
            // Preserve the original bytes in place and block opening until the
            // recovery issue is handled explicitly.
            throw CourseDocumentRecoveryError.unreadableDraft(url, error)
        }
    }

    func callTool(named name: String, argumentsJSON: String) async -> NativeEditorMCPToolResult {
        do {
            try Task.checkCancellation()
            try await flushPendingUserEdits()
            try Task.checkCancellation()
            let data = Data(argumentsJSON.utf8)
            let arguments = try JSONDecoder().decode([String: JSONValue].self, from: data)
            let result = await service.callTool(named: name, arguments: arguments)
            if !result.isError {
                if let task = Self.asyncTaskDescriptor(result.value) {
                    handleAsyncTask(task)
                } else if Self.mutatingTools.contains(name) {
                    let pageID = arguments["page_id"]?.stringValue
                    latestSnapshots.removeAll()
                    publish(pageID: pageID, replacesDocument: true)
                    scheduleCloudSync()
                }
            }
            return result
        } catch {
            return NativeEditorMCPToolResult(
                value: .object([
                    "object": "error",
                    "code": "repository_error",
                    "message": .string(error.localizedDescription),
                ]),
                isError: true
            )
        }
    }

    func changes() -> AsyncStream<CourseDocumentChange> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func scheduleCloudSync() {
        Task {
            await CourseCloudSyncEngine.shared.queueRepositoryChangesIfNeeded(repository: self)
        }
    }

    private func publish(
        pageID: String?,
        snapshot: NativeEditorPageSnapshot? = nil,
        replacesDocument: Bool = false,
        sourceEditID: UUID? = nil,
        hasPendingUserEdit: Bool = false,
        errorMessage: String? = nil
    ) {
        changeSequence &+= 1
        let change = CourseDocumentChange(
            pageID: pageID,
            sequence: changeSequence,
            snapshot: snapshot,
            replacesDocument: replacesDocument,
            sourceEditID: sourceEditID,
            hasPendingUserEdit: hasPendingUserEdit,
            errorMessage: errorMessage
        )
        for continuation in continuations.values {
            continuation.yield(change)
        }
    }

    private func publishFailure(pageID: String?, error: Error) {
        publish(pageID: pageID, errorMessage: error.localizedDescription)
    }

    private static let mutatingTools: Set<String> = [
        NativeEditorMCPToolCatalog.createPages,
        NativeEditorMCPToolCatalog.updatePage,
        NativeEditorMCPToolCatalog.movePages,
        NativeEditorMCPToolCatalog.duplicatePage,
    ]

    private struct AsyncTaskDescriptor: Sendable {
        var id: String
        var status: String
    }

    private static func asyncTaskDescriptor(_ value: JSONValue) -> AsyncTaskDescriptor? {
        guard let object = value.objectValue,
              object["object"]?.stringValue == "async_task",
              let id = object["id"]?.stringValue,
              let status = object["status"]?.stringValue else { return nil }
        return AsyncTaskDescriptor(id: id, status: status)
    }

    private func handleAsyncTask(_ task: AsyncTaskDescriptor) {
        switch task.status {
        case "succeeded":
            asyncTaskMonitors.removeValue(forKey: task.id)?.cancel()
            latestSnapshots.removeAll()
            publish(pageID: nil, replacesDocument: true)
        case "failed":
            asyncTaskMonitors.removeValue(forKey: task.id)?.cancel()
        default:
            startAsyncTaskMonitor(id: task.id)
        }
    }

    private func startAsyncTaskMonitor(id: String) {
        guard asyncTaskMonitors[id] == nil else { return }
        asyncTaskMonitors[id] = Task { [weak self] in
            var pollDelay: Duration = .milliseconds(200)
            var consecutiveFailures = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollDelay)
                    guard let self else { return }
                    let value = try await self.service.asyncTask(["task_id": .string(id)])
                    guard let task = Self.asyncTaskDescriptor(value) else { return }
                    consecutiveFailures = 0
                    pollDelay = .milliseconds(200)
                    if task.status == "succeeded" || task.status == "failed" {
                        await self.handleAsyncTask(task)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Polling is observational; a transient failure must not
                    // abandon a mutation that can still commit later. Keep the
                    // monitor alive with bounded exponential backoff until the
                    // service reports a terminal state or the repository dies.
                    consecutiveFailures = min(consecutiveFailures + 1, 6)
                    let milliseconds = min(5_000, 200 * (1 << consecutiveFailures))
                    pollDelay = .milliseconds(milliseconds)
                }
            }
        }
    }

    private func pageNode(_ page: PageRecord, workspace: PageWorkspace) -> CourseLearningNode {
        let children = workspace.children(of: page.id).map { pageNode($0, workspace: workspace) }
        let role = page.document.root.data["course_role"]?.stringValue
        let isLeafPage = role.map {
            ["lesson", "module", "context", "agent_notes", "explainer"].contains($0)
        } ?? false
        let kind: CourseLearningNode.Kind = children.isEmpty && isLeafPage
            ? .markdown
            : .folder
        let explicitStatus = page.document.root.data["course_generation_status"]?.stringValue
            .flatMap(CourseLearningNode.GenerationStatus.init(rawValue:))
        let contentBlocks = page.document.root.children.filter {
            $0.type != "nbe/child_page" && $0.type != "nbe/page_reference"
        }
        let derivedStatus: CourseLearningNode.GenerationStatus
        if let explicitStatus {
            derivedStatus = explicitStatus
        } else if !contentBlocks.isEmpty || !children.isEmpty {
            derivedStatus = .generated
        } else {
            derivedStatus = .pendingGeneration
        }
        return CourseLearningNode(
            id: page.document.root.data["course_node_id"]?.stringValue ?? page.id,
            title: page.title,
            kind: kind,
            status: derivedStatus,
            pageID: page.id,
            children: children
        )
    }
}

private enum CourseSyncWorkspaceMerger {
    static func merge(
        base: CourseSyncWorkspaceSnapshot,
        local: CourseSyncWorkspaceSnapshot,
        remote: CourseSyncWorkspaceSnapshot
    ) throws -> PageWorkspace {
        let baseWorkspace = try base.validatedWorkspace()
        let localWorkspace = try local.validatedWorkspace()
        let remoteWorkspace = try remote.validatedWorkspace()

        let allItemIDs = Set(baseWorkspace.items.keys)
            .union(localWorkspace.items.keys)
            .union(remoteWorkspace.items.keys)
        var mergedItems: [String: NativeBlockEditorLibrary.LibraryItem] = [:]
        var structuralConflicts: [String] = []

        for id in allItemIDs.sorted() {
            do {
                if let item = try mergeItem(
                    id: id,
                    base: baseWorkspace.items[id],
                    local: localWorkspace.items[id],
                    remote: remoteWorkspace.items[id]
                ) {
                    mergedItems[id] = item
                }
            } catch {
                structuralConflicts.append(id)
            }
        }
        guard structuralConflicts.isEmpty else {
            throw CourseCloudSyncRepositoryError.structuralConflict(structuralConflicts)
        }

        let allPageIDs = Set(baseWorkspace.pages.keys)
            .union(localWorkspace.pages.keys)
            .union(remoteWorkspace.pages.keys)
        var mergedPages: [String: PageRecord] = [:]
        var contentConflicts: [String] = []

        for id in allPageIDs.sorted() {
            guard let mergedItem = mergedItems[id], mergedItem.kind == .page else { continue }
            let basePage = baseWorkspace.pages[id]
            let localPage = localWorkspace.pages[id]
            let remotePage = remoteWorkspace.pages[id]

            do {
                let page = try mergePage(
                    id: id,
                    item: mergedItem,
                    base: basePage,
                    local: localPage,
                    remote: remotePage
                )
                mergedPages[id] = page
            } catch {
                contentConflicts.append(id)
            }
        }
        guard contentConflicts.isEmpty else {
            throw CourseCloudSyncRepositoryError.contentConflict(contentConflicts)
        }

        return try PageWorkspace(
            rootPageID: try mergeRequiredValue(
                base: baseWorkspace.rootPageID,
                local: localWorkspace.rootPageID,
                remote: remoteWorkspace.rootPageID
            ),
            pages: mergedPages,
            items: mergedItems
        )
    }

    private static func mergeItem(
        id: String,
        base: NativeBlockEditorLibrary.LibraryItem?,
        local: NativeBlockEditorLibrary.LibraryItem?,
        remote: NativeBlockEditorLibrary.LibraryItem?
    ) throws -> NativeBlockEditorLibrary.LibraryItem? {
        guard let base, let local, let remote else {
            return try mergeValue(base: base, local: local, remote: remote)
        }
        return NativeBlockEditorLibrary.LibraryItem(
            id: id,
            kind: try mergeRequiredValue(
                base: base.kind,
                local: local.kind,
                remote: remote.kind
            ),
            parentID: try mergeValue(
                base: base.parentID,
                local: local.parentID,
                remote: remote.parentID
            ),
            sortKey: try mergeRequiredValue(
                base: base.sortKey,
                local: local.sortKey,
                remote: remote.sortKey
            ),
            title: try mergeRequiredValue(
                base: base.title,
                local: local.title,
                remote: remote.title
            ),
            icon: try mergeRequiredValue(
                base: base.icon,
                local: local.icon,
                remote: remote.icon
            ),
            isFavorite: try mergeRequiredValue(
                base: base.isFavorite,
                local: local.isFavorite,
                remote: remote.isFavorite
            ),
            createdAt: min(local.createdAt, remote.createdAt),
            updatedAt: max(local.updatedAt, remote.updatedAt),
            lastOpenedAt: max(local.lastOpenedAt ?? .distantPast, remote.lastOpenedAt ?? .distantPast)
                .nilIfDistantPast,
            trashedAt: try mergeValue(
                base: base.trashedAt,
                local: local.trashedAt,
                remote: remote.trashedAt
            )
        )
    }

    private static func mergePage(
        id: String,
        item: NativeBlockEditorLibrary.LibraryItem,
        base: PageRecord?,
        local: PageRecord?,
        remote: PageRecord?
    ) throws -> PageRecord {
        let selected: PageRecord
        switch (base, local, remote) {
        case (_, let local?, let remote?) where local == remote:
            selected = local
        case (let base?, let local?, let remote?) where local == base:
            selected = remote
        case (let base?, let local?, let remote?) where remote == base:
            selected = local
        case (let base?, let local?, let remote?):
            selected = PageRecord(
                id: id,
                title: item.title,
                icon: item.icon,
                parentID: item.parentID,
                document: CourseDocumentThreeWayMerger.merge(
                    base: base.document,
                    local: local.document,
                    remote: remote.document
                ),
                createdAt: min(local.createdAt, remote.createdAt),
                updatedAt: max(local.updatedAt, remote.updatedAt)
            )
        case (nil, let local?, nil):
            selected = local
        case (nil, nil, let remote?):
            selected = remote
        case (nil, let local?, let remote?) where local == remote:
            selected = local
        case (let base?, nil, let remote?) where remote == base:
            throw MergeConflict()
        case (let base?, let local?, nil) where local == base:
            throw MergeConflict()
        default:
            throw MergeConflict()
        }

        return PageRecord(
            id: id,
            title: item.title,
            icon: item.icon,
            parentID: item.parentID,
            document: selected.document,
            createdAt: selected.createdAt,
            updatedAt: selected.updatedAt
        )
    }

    private static func mergeValue<T: Equatable>(
        base: T?,
        local: T?,
        remote: T?
    ) throws -> T? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        if base == nil {
            if local == nil { return remote }
            if remote == nil { return local }
        }
        throw MergeConflict()
    }

    private static func mergeRequiredValue<T: Equatable>(
        base: T,
        local: T,
        remote: T
    ) throws -> T {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        throw MergeConflict()
    }

    private struct MergeConflict: Error {}
}

private extension Date {
    var nilIfDistantPast: Date? {
        self == .distantPast ? nil : self
    }
}

/// Three-way reconciliation for the local editor lane. Stable block IDs let us
/// preserve independent learner and agent changes without replacing a whole
/// page merely because its SQLite revision advanced.
private enum CourseDocumentThreeWayMerger {
    static func semanticallyEqual(_ lhs: BlockDocument, _ rhs: BlockDocument) -> Bool {
        semanticallyEqual(lhs.root, rhs.root)
    }

    static func merge(
        base: BlockDocument,
        local: BlockDocument,
        remote: BlockDocument
    ) -> BlockDocument {
        if semanticallyEqual(local.root, base.root) { return remote }
        if semanticallyEqual(remote.root, base.root) { return local }
        if semanticallyEqual(local.root, remote.root) { return local }

        var document = BlockDocument(root: mergeNode(base: base.root, local: local.root, remote: remote.root))
        document.ensureStableBlockIDs()
        return document
    }

    private static func mergeNode(base: BlockNode, local: BlockNode, remote: BlockNode) -> BlockNode {
        if semanticallyEqual(local, base) { return remote }
        if semanticallyEqual(remote, base) { return local }
        if semanticallyEqual(local, remote) { return local }

        var merged = remote
        merged.type = mergeValue(base: base.type, local: local.type, remote: remote.type)
        merged.data = mergeData(base: base.data, local: local.data, remote: remote.data)
        merged.children = mergeChildren(
            base: base.children,
            local: local.children,
            remote: remote.children
        )
        return merged
    }

    private static func mergeChildren(
        base: [BlockNode],
        local: [BlockNode],
        remote: [BlockNode]
    ) -> [BlockNode] {
        if semanticallyEqual(local, base) { return remote }
        if semanticallyEqual(remote, base) { return local }

        let baseByID = nodeMap(base)
        let localByID = nodeMap(local)
        let remoteByID = nodeMap(remote)
        let allIDs = Set(baseByID.keys).union(localByID.keys).union(remoteByID.keys)
        var mergedByID: [String: BlockNode] = [:]

        for id in allIDs {
            switch (baseByID[id], localByID[id], remoteByID[id]) {
            case let (baseNode?, localNode?, remoteNode?):
                mergedByID[id] = mergeNode(base: baseNode, local: localNode, remote: remoteNode)
            case let (nil, localNode?, remoteNode?):
                mergedByID[id] = semanticallyEqual(localNode, remoteNode)
                    ? localNode
                    : mergeNode(base: localNode, local: localNode, remote: remoteNode)
            case (_?, nil, _?):
                // A missing local node is an intentional learner deletion. The
                // remote version remains recoverable in SQLite history, so do
                // not silently resurrect it when an agent edits concurrently.
                break
            case let (baseNode?, localNode?, nil):
                if !semanticallyEqual(localNode, baseNode) { mergedByID[id] = localNode }
            case let (nil, localNode?, nil):
                mergedByID[id] = localNode
            case let (nil, nil, remoteNode?):
                mergedByID[id] = remoteNode
            case (_, nil, nil):
                break
            }
        }

        let allowed = Set(mergedByID.keys)
        let baseOrder = base.map(stableKey)
        let localOrder = local.map(stableKey)
        let remoteOrder = remote.map(stableKey)
        let localReordered = relativeOrderChanged(base: baseOrder, variant: localOrder)
        let remoteReordered = relativeOrderChanged(base: baseOrder, variant: remoteOrder)
        let primary = localReordered || !remoteReordered ? localOrder : remoteOrder
        let secondary = primary == localOrder ? remoteOrder : localOrder
        let order = insertingMissingIDs(from: secondary, into: primary.filter(allowed.contains), allowed: allowed)
        return order.compactMap { mergedByID[$0] }
    }

    private static func mergeData(
        base: [String: JSONValue],
        local: [String: JSONValue],
        remote: [String: JSONValue]
    ) -> [String: JSONValue] {
        var merged: [String: JSONValue] = [:]
        for key in Set(base.keys).union(local.keys).union(remote.keys) {
            let value = mergeOptionalValue(base: base[key], local: local[key], remote: remote[key])
            if let value { merged[key] = value }
        }
        return merged
    }

    private static func mergeValue<T: Equatable>(base: T, local: T, remote: T) -> T {
        if local == base { return remote }
        if remote == base { return local }
        return local
    }

    private static func mergeOptionalValue<T: Equatable>(base: T?, local: T?, remote: T?) -> T? {
        if local == base { return remote }
        if remote == base { return local }
        return local
    }

    private static func semanticallyEqual(_ lhs: [BlockNode], _ rhs: [BlockNode]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(semanticallyEqual)
    }

    private static func semanticallyEqual(_ lhs: BlockNode, _ rhs: BlockNode) -> Bool {
        lhs.type == rhs.type
            && lhs.data == rhs.data
            && semanticallyEqual(lhs.children, rhs.children)
    }

    private static func nodeMap(_ nodes: [BlockNode]) -> [String: BlockNode] {
        Dictionary(nodes.map { (stableKey($0), $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private static func stableKey(_ node: BlockNode) -> String {
        node.stableBlockID ?? "runtime:\(node.id.uuidString.lowercased())"
    }

    private static func relativeOrderChanged(base: [String], variant: [String]) -> Bool {
        let common = Set(base).intersection(variant)
        return base.filter(common.contains) != variant.filter(common.contains)
    }

    private static func insertingMissingIDs(
        from secondary: [String],
        into primary: [String],
        allowed: Set<String>
    ) -> [String] {
        var result = primary
        for (index, id) in secondary.enumerated() where allowed.contains(id) && !result.contains(id) {
            if let preceding = secondary[..<index].last(where: result.contains),
               let insertionIndex = result.firstIndex(of: preceding) {
                result.insert(id, at: result.index(after: insertionIndex))
            } else if let following = secondary[(index + 1)...].first(where: result.contains),
                      let insertionIndex = result.firstIndex(of: following) {
                result.insert(id, at: insertionIndex)
            } else {
                result.append(id)
            }
        }
        return result
    }
}

private enum LegacyCoursePageImporter {
    private struct Metadata: Decodable {
        var planID: String?
        var title: String?
        var learningPath: [CourseLearningNode]?

        private enum CodingKeys: String, CodingKey {
            case planID = "plan_id"
            case title
            case learningPath = "learning_path"
        }
    }

    static func makeSeedWorkspace(
        workspaceID: String,
        rootTitle: String,
        courseRoot: URL
    ) -> PageWorkspace {
        let metadata = decodeMetadata(at: courseRoot.appendingPathComponent("course.json"))
        var rootDocument = document(at: courseRoot.appendingPathComponent("index.md")) ?? .blank()
        applyMetadata(
            to: &rootDocument,
            nodeID: metadata?.planID ?? workspaceID,
            role: "course",
            generationStatus: nil,
            bootstrapStatus: "ready_for_learning"
        )
        var workspace = PageWorkspace(rootPage: PageRecord(
            title: metadata?.title ?? rootTitle,
            icon: "books.vertical.fill",
            document: rootDocument
        ))

        importContextPages(into: &workspace, courseRoot: courseRoot)
        if let learningPath = metadata?.learningPath, !learningPath.isEmpty {
            for node in learningPath {
                importLearningNode(node, parentID: workspace.rootPageID, depth: 0, into: &workspace, courseRoot: courseRoot)
            }
        } else {
            importLegacyChapterFolders(into: &workspace, courseRoot: courseRoot)
        }
        return workspace
    }

    private static func decodeMetadata(at url: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private static func importContextPages(into workspace: inout PageWorkspace, courseRoot: URL) {
        let contextDirectory = courseRoot.appendingPathComponent("context", isDirectory: true)
        for url in markdownFiles(in: contextDirectory) {
            let title = displayTitle(for: url)
            addPage(
                title: title,
                parentID: workspace.rootPageID,
                document: document(at: url) ?? .blank(),
                nodeID: "context-\(slug(url.deletingPathExtension().lastPathComponent))",
                role: "context",
                status: .generated,
                into: &workspace
            )
        }

        let agentNotesURL = courseRoot.appendingPathComponent(".course/agent-notes.md")
        if let notes = document(at: agentNotesURL) {
            addPage(
                title: "Agent notes",
                parentID: workspace.rootPageID,
                document: notes,
                nodeID: "agent-notes",
                role: "agent_notes",
                status: .generated,
                into: &workspace
            )
        }
    }

    private static func importLearningNode(
        _ node: CourseLearningNode,
        parentID: String,
        depth: Int,
        into workspace: inout PageWorkspace,
        courseRoot: URL
    ) {
        let pageDocument = node.relativePath
            .flatMap { document(at: courseRoot.appendingPathComponent($0)) }
            ?? headingDocument(node.title)
        let role: String
        switch node.kind {
        case .folder: role = depth == 0 ? "chapter" : "subchapter"
        case .markdown: role = "lesson"
        }
        guard let page = addPage(
            title: node.title,
            parentID: parentID,
            document: pageDocument,
            nodeID: node.id,
            role: role,
            status: node.status,
            into: &workspace
        ) else { return }
        for child in node.children {
            importLearningNode(child, parentID: page.id, depth: depth + 1, into: &workspace, courseRoot: courseRoot)
        }
    }

    private static func importLegacyChapterFolders(into workspace: inout PageWorkspace, courseRoot: URL) {
        let chaptersDirectory = courseRoot.appendingPathComponent("chapters", isDirectory: true)
        guard let chapterURLs = try? FileManager.default.contentsOfDirectory(
            at: chaptersDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for chapterURL in chapterURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? chapterURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            importDirectoryPage(
                chapterURL,
                parentID: workspace.rootPageID,
                depth: 0,
                into: &workspace
            )
        }
    }

    private static func importDirectoryPage(
        _ directory: URL,
        parentID: String,
        depth: Int,
        into workspace: inout PageWorkspace
    ) {
        let readme = directory.appendingPathComponent("README.md")
        guard let page = addPage(
            title: displayTitle(for: directory),
            parentID: parentID,
            document: document(at: readme) ?? headingDocument(displayTitle(for: directory)),
            nodeID: "legacy-\(slug(directory.lastPathComponent))",
            role: depth == 0 ? "chapter" : "subchapter",
            status: .generated,
            into: &workspace
        ) else { return }

        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                importDirectoryPage(child, parentID: page.id, depth: depth + 1, into: &workspace)
            } else if child.pathExtension.lowercased() == "md", child.lastPathComponent.lowercased() != "readme.md" {
                _ = addPage(
                    title: displayTitle(for: child),
                    parentID: page.id,
                    document: document(at: child) ?? .blank(),
                    nodeID: "legacy-\(slug(child.deletingPathExtension().lastPathComponent))",
                    role: "lesson",
                    status: .generated,
                    into: &workspace
                )
            }
        }
    }

    @discardableResult
    private static func addPage(
        title: String,
        parentID: String,
        document sourceDocument: BlockDocument,
        nodeID: String,
        role: String,
        status: CourseLearningNode.GenerationStatus,
        into workspace: inout PageWorkspace
    ) -> PageRecord? {
        var pageDocument = sourceDocument
        applyMetadata(
            to: &pageDocument,
            nodeID: nodeID,
            role: role,
            generationStatus: status.rawValue,
            bootstrapStatus: nil
        )
        guard let page = try? workspace.createPage(
            title: title,
            parentID: parentID,
            icon: role == "chapter" || role == "subchapter" ? "folder.fill" : "doc.text",
            document: pageDocument
        ) else { return nil }
        if var parentDocument = workspace.page(id: parentID)?.document {
            parentDocument.root.children.append(.childPage(pageID: page.id, title: page.title, icon: page.icon))
            try? workspace.saveDocument(parentDocument, for: parentID)
        }
        return page
    }

    private static func applyMetadata(
        to document: inout BlockDocument,
        nodeID: String,
        role: String,
        generationStatus: String?,
        bootstrapStatus: String?
    ) {
        document.root.data["course_node_id"] = .string(nodeID)
        document.root.data["course_role"] = .string(role)
        if let generationStatus {
            document.root.data["course_generation_status"] = .string(generationStatus)
        }
        if let bootstrapStatus {
            document.root.data["course_bootstrap_status"] = .string(bootstrapStatus)
        }
        document.ensureStableBlockIDs()
    }

    private static func document(at url: URL) -> BlockDocument? {
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (try? AppFlowyMarkdownCodec().decode(markdown))
            ?? BlockDocument(root: BlockNode(type: "page", children: [.paragraph(markdown)]))
    }

    private static func headingDocument(_ title: String) -> BlockDocument {
        BlockDocument(root: BlockNode(type: "page", children: [.heading(title, level: 1)]))
    }

    private static func markdownFiles(in directory: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func displayTitle(for url: URL) -> String {
        let stem = url.hasDirectoryPath ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let withoutOrder = stem.replacingOccurrences(of: #"^\d+[-_ ]*"#, with: "", options: .regularExpression)
        return withoutOrder
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(mapped)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

actor CourseDocumentRegistry {
    static let shared = CourseDocumentRegistry()

    private struct OpeningRepository: Sendable {
        let id: UUID
        let task: Task<CourseDocumentRepository, Error>
    }

    private var repositories: [String: CourseDocumentRepository] = [:]
    private var openingRepositories: [String: OpeningRepository] = [:]
    private var workspaceByThreadID: [String: String] = [:]

    func repository(
        workspaceID: String,
        databaseURL: URL,
        rootTitle: String
    ) async throws -> CourseDocumentRepository {
        if let existing = repositories[workspaceID] { return existing }
        let opening: OpeningRepository
        if let existing = openingRepositories[workspaceID] {
            opening = existing
        } else {
            let id = UUID()
            let task = Task {
                try await CourseDocumentRepository.open(
                    workspaceID: workspaceID,
                    databaseURL: databaseURL,
                    rootTitle: rootTitle
                )
            }
            opening = OpeningRepository(id: id, task: task)
            openingRepositories[workspaceID] = opening
        }

        do {
            let repository = try await opening.task.value
            if openingRepositories[workspaceID]?.id == opening.id {
                openingRepositories.removeValue(forKey: workspaceID)
                repositories[workspaceID] = repository
            }
            return repositories[workspaceID] ?? repository
        } catch {
            if openingRepositories[workspaceID]?.id == opening.id {
                openingRepositories.removeValue(forKey: workspaceID)
            }
            throw error
        }
    }

    func register(threadID: String, workspaceID: String) {
        workspaceByThreadID[threadID] = workspaceID
    }

    func openRepositories() -> [CourseDocumentRepository] {
        Array(repositories.values)
    }

    func handle(
        threadID: String,
        tool: String,
        argumentsJSON: String
    ) async -> NativeEditorMCPToolResult? {
        guard let workspaceID = workspaceByThreadID[threadID],
              let repository = repositories[workspaceID] else { return nil }
        return await repository.callTool(named: tool, argumentsJSON: argumentsJSON)
    }

    func handle(
        workspaceID: String,
        tool: String,
        argumentsJSON: String
    ) async -> NativeEditorMCPToolResult? {
        guard let repository = repositories[workspaceID] else { return nil }
        return await repository.callTool(named: tool, argumentsJSON: argumentsJSON)
    }
}

private final class CourseToolResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppPlatformDynamicToolResult?

    func store(_ result: AppPlatformDynamicToolResult?) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func load() -> AppPlatformDynamicToolResult? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class CourseDocumentToolRouter: PlatformDynamicToolHandler, @unchecked Sendable {
    static let shared = CourseDocumentToolRouter()

    func handleDynamicTool(
        invocation: AppPlatformDynamicToolInvocation
    ) -> AppPlatformDynamicToolResult? {
        guard NativeEditorMCPToolCatalog.tools.contains(where: { $0.name == invocation.tool }) else {
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = CourseToolResultBox()
        let routingTask = Task {
            defer { semaphore.signal() }
            guard !Task.isCancelled else { return }
            let result = await CourseDocumentRegistry.shared.handle(
                threadID: invocation.threadId,
                tool: invocation.tool,
                argumentsJSON: invocation.argumentsJson
            )
            guard !Task.isCancelled else { return }
            let encoded = result.flatMap { result -> AppPlatformDynamicToolResult? in
                guard let data = try? JSONEncoder().encode(result.value),
                      let output = String(data: data, encoding: .utf8) else { return nil }
                return AppPlatformDynamicToolResult(success: !result.isError, output: output)
            }
            box.store(encoded)
        }

        guard semaphore.wait(timeout: .now() + 45) == .success else {
            routingTask.cancel()
            return AppPlatformDynamicToolResult(
                success: false,
                output: "The course document tool timed out. Its operation may still finish; fetch the current page state before deciding whether to retry."
            )
        }
        return box.load()
    }
}

@MainActor
@Observable
final class CoursePageEditorModel {
    var title = "Course page"
    var document = BlockDocument.blank()
    var isLoading = true
    var errorMessage: String?
    var pageTitles: [String: String] = [:]

    let pageID: String
    private let repository: CourseDocumentRepository
    private let stagingDelay: Duration?
    private var confirmedDocument: BlockDocument?
    private var confirmedRevision: Int64?
    private var latestEditID: UUID?
    private var latestStagedEditID: UUID?
    private var stagedSaveTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var changesTask: Task<Void, Never>?

    init(
        pageID: String,
        repository: CourseDocumentRepository,
        stagingDelay: Duration? = nil
    ) {
        self.pageID = pageID
        self.repository = repository
        self.stagingDelay = stagingDelay
    }

    deinit {
        changesTask?.cancel()
    }

    func load() async {
        // Register the stream first. AsyncStream buffers any mutation that
        // lands while initial hydration is awaiting SQLite, closing the gap
        // where a change could previously occur before the observer existed.
        if changesTask == nil {
            let stream = await repository.changes()
            changesTask = Task { [weak self] in
                for await change in stream {
                    guard !Task.isCancelled else { return }
                    if change.pageID == nil || change.pageID == pageID {
                        if let errorMessage = change.errorMessage {
                            self?.errorMessage = errorMessage
                        } else if let snapshot = change.snapshot {
                            guard let self else { return }
                            let completesLatestEdit = change.sourceEditID != nil
                                && change.sourceEditID == self.latestEditID
                                && !change.hasPendingUserEdit
                            let canAdoptSnapshot = self.latestEditID == nil || completesLatestEdit
                            self.apply(
                                snapshot,
                                replacingDocument: canAdoptSnapshot
                                    && (change.replacesDocument
                                        || !CourseDocumentThreeWayMerger.semanticallyEqual(
                                            self.document,
                                            snapshot.document
                                        ))
                            )
                            if completesLatestEdit {
                                self.latestEditID = nil
                                self.latestStagedEditID = nil
                            }
                        } else {
                            guard let self else { return }
                            // An external mutation may publish before the latest
                            // keystroke's staging task reaches the repository. The
                            // captured base will reconcile it once staged, so never
                            // overwrite the visible editor during that gap.
                            guard self.latestEditID == self.latestStagedEditID else { continue }
                            await self.reload()
                        }
                    }
                }
            }
        }
        await reload()
    }

    func userChangedDocument(_ updated: BlockDocument) {
        document = updated
        let editID = UUID()
        latestEditID = editID
        let previous = stagedSaveTask
        let repository = repository
        let pageID = pageID
        let capturedBaseDocument = confirmedDocument
        let capturedBaseRevision = confirmedRevision
        let stagingDelay = stagingDelay
        stagedSaveTask = Task { [weak self] in
            await previous?.value
            if let stagingDelay {
                try? await Task.sleep(for: stagingDelay)
            }
            do {
                try await repository.stageUserEdit(
                    pageID: pageID,
                    document: updated,
                    capturedBaseDocument: capturedBaseDocument,
                    capturedBaseRevision: capturedBaseRevision,
                    sourceEditID: editID
                )
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            if self?.latestEditID == editID {
                self?.latestStagedEditID = editID
            }
        }
    }

    func flush() async {
        while true {
            let targetEditID = latestEditID
            let targetStagingTask = stagedSaveTask
            await targetStagingTask?.value
            do {
                let snapshots = try await repository.flushPendingUserEdits()
                // A newer edit may enter while either await is suspended. Do
                // not adopt an older snapshot or clear its identity; include
                // the new staging task in another pass instead.
                guard latestEditID == targetEditID else { continue }
                if let snapshot = snapshots.last(where: { $0.id == pageID }) {
                    apply(snapshot, replacingDocument: true)
                }
                latestEditID = nil
                latestStagedEditID = nil
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    private func reload() async {
        let targetEditID = latestEditID
        do {
            let snapshot = try await repository.pageSnapshot(id: pageID)
            let workspace = try await repository.workspaceSnapshot()
            // Loading and external refreshes suspend on repository I/O. If a
            // keystroke entered meanwhile, its captured base must remain in
            // charge; adopting this older snapshot would erase visible input.
            if latestEditID == targetEditID {
                apply(snapshot, replacingDocument: true)
                latestEditID = nil
                latestStagedEditID = nil
            }
            pageTitles = workspace.pages.mapValues(\.title)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func apply(_ snapshot: NativeEditorPageSnapshot, replacingDocument: Bool) {
        title = snapshot.title
        confirmedDocument = snapshot.document
        confirmedRevision = snapshot.revision
        if replacingDocument, document != snapshot.document {
            document = snapshot.document
        }
        errorMessage = nil
    }

    func pageTitle(id: String) -> String? {
        pageTitles[id]
    }
}
