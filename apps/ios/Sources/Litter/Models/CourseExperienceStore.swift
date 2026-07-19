import Foundation
import Observation
import UIKit

enum CourseRoute: Hashable {
    case newCourse
    case building
    case course(String)
    case courseFile(courseID: String, relativePath: String)
}

struct LearningCourse: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case inProgress
        case ready
    }

    let id: String
    var title: String
    var subtitle: String
    var accentHex: String
    var progress: Double
    var lessonCount: Int
    var duration: String
    var status: Status
    var workspaceID: String? = nil
    var agentServerID: String? = nil
    var agentThreadID: String? = nil
    var agentRuntimeKind: String? = nil
    var agentModelID: String? = nil

}

struct CourseAgentOption: Identifiable, Equatable {
    let id: String
    let title: String
    let available: Bool

    var subtitle: String {
        available ? "Available on this device" : "Not available on this device"
    }

    static func catalog(from runtimeInfos: [AgentRuntimeInfo], knownRuntimeIDs: [String]) -> [CourseAgentOption] {
        let runtimeByID = Dictionary(uniqueKeysWithValues: runtimeInfos.map { ($0.kind, $0) })
        var orderedIDs: [String] = []
        for id in knownRuntimeIDs + runtimeInfos.map(\.kind) where !orderedIDs.contains(id) {
            orderedIDs.append(id)
        }
        return orderedIDs.map { id in
            let runtime = runtimeByID[id]
            let runtimeTitle = runtime?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return CourseAgentOption(
                id: id,
                title: runtimeTitle?.isEmpty == false ? runtimeTitle! : id.titleDisplayLabel,
                available: runtime?.available == true
            )
        }
    }
}

private enum CourseAgentSelectionError: LocalizedError {
    case runtimeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let name):
            return "\(name) is supported by Litter, but its runtime is not installed on this iPhone."
        }
    }
}

private extension CourseAgentOption {
    static func coldStartTitle(for id: String) -> String {
        switch id {
        case "claude": return "Claude Code"
        case "opencode": return "OpenCode"
        case "droid": return "Factory Droid"
        case "pi": return "Pi"
        case "amp": return "Amp"
        case "grok": return "Grok"
        case "hermes": return "Hermes"
        case "devin": return "Devin"
        default: return id.titleDisplayLabel
        }
    }
}

struct CourseSource: Identifiable, Equatable {
    enum Kind {
        case document
        case image
        case link
    }

    let id = UUID()
    var name: String
    var detail: String
    var kind: Kind
    var runtimePath: String?
    var image: UIImage?
}

struct CourseChatMessage: Identifiable {
    enum Role {
        case learner
        case agent
    }

    let id = UUID()
    var role: Role
    var text: String
    var sources: [CourseSource] = []
}

struct CourseChapter: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var objective: String
    var deliverables: [String]
}

struct CourseLearningNode: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case folder
        case markdown
    }

    enum GenerationStatus: String, Codable {
        case pendingGeneration = "pending_generation"
        case generating
        case generated
        case partiallyGenerated = "partially_generated"
    }

    var id: String
    var title: String
    var kind: Kind
    var status: GenerationStatus
    var relativePath: String?
    var children: [CourseLearningNode]

    init(
        id: String,
        title: String,
        kind: Kind,
        status: GenerationStatus,
        relativePath: String? = nil,
        children: [CourseLearningNode] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.relativePath = relativePath
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case status
        case relativePath = "relative_path"
        case children
    }
}

struct CourseBrief: Codable, Equatable {
    var planID = ""
    var revision = 0
    var title = ""
    var summary = ""
    var outcome = ""
    var startingPoint = ""
    var focusGap = ""
    var estimatedDuration = ""
    var learningPath: [CourseLearningNode]? = nil
    var chapters: [CourseChapter] = []

    private enum CodingKeys: String, CodingKey {
        case planID = "plan_id"
        case revision
        case title
        case summary
        case outcome
        case startingPoint = "starting_point"
        case focusGap = "focus_gap"
        case estimatedDuration = "estimated_duration"
        case learningPath = "learning_path"
        case chapters
    }
}

private struct CourseBuildManifest: Codable {
    var planID: String
    var revision: Int
    var status: String
    var files: [String]
    var generatedChapterIDs: [String]
    var nextChapterID: String?

    private enum CodingKeys: String, CodingKey {
        case planID = "plan_id"
        case revision
        case status
        case files
        case generatedChapterIDs = "generated_chapter_ids"
        case nextChapterID = "next_chapter_id"
    }
}

private struct CourseWorkspaceChapter: Decodable {
    var id: String
    var title: String
}

private struct CourseWorkspaceMetadata: Decodable {
    var planID: String?
    var revision: Int?
    var title: String?
    var summary: String?
    var outcome: String?
    var estimatedDuration: String?
    var learningPath: [CourseLearningNode]?
    var chapters: [CourseWorkspaceChapter]?

    private enum CodingKeys: String, CodingKey {
        case planID = "plan_id"
        case revision
        case title
        case summary
        case outcome
        case estimatedDuration = "estimated_duration"
        case learningPath = "learning_path"
        case chapters
    }
}

@MainActor
@Observable
final class CourseExperienceStore {
    enum AgentConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private static let setupKey = "snappy.course.agentSetupComplete"
    private static let agentKey = "snappy.course.selectedAgent"
    private static let modelKey = "snappy.course.selectedModel"
    private static let effortKey = "snappy.course.selectedReasoningEffort"
    private static let coursesKey = "snappy.course.savedCourses"

    private static let coldStartRuntimeIDs = ["codex", "claude", "opencode", "pi", "amp", "droid", "hermes", "devin", "grok"]

    var navigationPath: [CourseRoute] = []
    var selectedAgentID: String?
    var selectedModelID: String?
    var selectedReasoningEffortID: String?
    var agentOptions: [CourseAgentOption] = CourseExperienceStore.coldStartRuntimeIDs.map {
        CourseAgentOption(id: $0, title: CourseAgentOption.coldStartTitle(for: $0), available: $0 == "codex")
    }
    var courseModels: [ModelInfo] = []
    var isLoadingAgentCatalog = false
    var setupComplete: Bool
    var connectionState: AgentConnectionState = .idle
    var courses: [LearningCourse]
    var messages: [CourseChatMessage]
    var sources: [CourseSource] = []
    var brief = CourseBrief()
    var showsBrief = false
    var generationStep = 0
    var generatedCourseID: String?
    var agentThreadKey: ThreadKey?
    var agentError: String?
    var generationError: String?
    var isAgentRequestPending = false
    var courseChatDraft: String?
    var backgroundGeneratingCourseID: String?
    var backgroundGeneratingNodeID: String?
    var backgroundGenerationError: String?
    var backgroundGenerationErrorCourseID: String?
    var courseWorkspaceRefreshVersion = 0
    private var currentCourseWorkspaceID = UUID().uuidString.lowercased()
    private var currentWorkspaceWasBuilt = false
    private var agentForwardTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var backgroundNodeGenerationTask: Task<Void, Never>?
    private var processedCoursePlanToolCallIDs: Set<String> = []
    private let defaults: UserDefaults
    private var currentAgentRuntimeID: String?
    private var currentAgentModelID: String?

    var activeAgentID: String {
        currentAgentRuntimeID ?? selectedAgentID ?? "codex"
    }

    init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        if environment["SNAPPY_RESET_ONBOARDING"] == "1" {
            defaults.removeObject(forKey: Self.setupKey)
            defaults.removeObject(forKey: Self.agentKey)
            defaults.removeObject(forKey: Self.modelKey)
            defaults.removeObject(forKey: Self.effortKey)
            defaults.removeObject(forKey: Self.coursesKey)
        }

        selectedAgentID = defaults.string(forKey: Self.agentKey)
        selectedModelID = defaults.string(forKey: Self.modelKey)
        selectedReasoningEffortID = defaults.string(forKey: Self.effortKey)
        setupComplete = defaults.bool(forKey: Self.setupKey)
        if environment["SNAPPY_SKIP_AGENT_SETUP"] == "1" {
            selectedAgentID = "codex"
            setupComplete = true
            connectionState = .connected
        }

        if let data = defaults.data(forKey: Self.coursesKey),
           let decoded = try? JSONDecoder().decode([LearningCourse].self, from: data) {
            let cleanedCourses = decoded.filter { $0.workspaceID?.isEmpty == false }
            courses = cleanedCourses
            if cleanedCourses.count != decoded.count,
               let cleanedData = try? JSONEncoder().encode(cleanedCourses) {
                defaults.set(cleanedData, forKey: Self.coursesKey)
            }
        } else {
            courses = []
        }

        messages = []
    }

    func prepareLocalAgentCatalog(appModel: AppModel) async {
        guard !isLoadingAgentCatalog else { return }
        isLoadingAgentCatalog = true
        defer { isLoadingAgentCatalog = false }
        LitterPlatform.bootstrapLocalRuntimeIfNeeded()

        do {
            let serverID = try await connectedLocalServerID(appModel: appModel)
            await appModel.loadAvailableModelsIfNeeded(serverId: serverID)
            refreshAgentCatalog(appModel: appModel, serverID: serverID)
        } catch {
            agentError = error.localizedDescription
        }
    }

    func connectLocalAgent(
        appModel: AppModel,
        agentID: String = "codex",
        modelID: String? = nil,
        reasoningEffortID: String? = nil
    ) async {
        guard connectionState != .connecting else { return }
        let hadCompletedSetup = setupComplete
        connectionState = .connecting
        agentError = nil
        LitterPlatform.bootstrapLocalRuntimeIfNeeded()

        do {
            let serverID = try await connectedLocalServerID(appModel: appModel)
            refreshAgentCatalog(appModel: appModel, serverID: serverID)
            guard agentOptions.first(where: { $0.id == agentID })?.available == true else {
                throw CourseAgentSelectionError.runtimeUnavailable(agentID.titleDisplayLabel)
            }
            if agentID == .codex {
                guard try await appModel.ensureLocalAuthForThreadStart(serverId: serverID) else {
                    connectionState = hadCompletedSetup ? .connected : .idle
                    if !hadCompletedSetup { disconnectForAgentPicker() }
                    return
                }
            }
            await appModel.loadAvailableModelsIfNeeded(serverId: serverID)
            refreshAgentCatalog(appModel: appModel, serverID: serverID)

            let matchingModels = models(for: agentID)
            let requestedModel = modelID ?? (selectedAgentID == agentID ? selectedModelID : nil)
            let catalogMatch = matchingModels.first(where: {
                $0.id == requestedModel || $0.model == requestedModel
            })
            let fallbackModel = matchingModels.first(where: \.isDefault) ?? matchingModels.first
            let resolvedModel = catalogMatch ?? fallbackModel
            let resolvedModelID = OpenAICompatibleProviderConfiguration.resolvedModelID(
                requestedModelID: requestedModel,
                catalogMatchID: catalogMatch?.id,
                fallbackModelID: fallbackModel?.id,
                customEndpointEnabled: agentID == .codex && OpenAIApiKeyStore.shared.hasStoredBaseURL
            )
            let resolvedEffort = reasoningEffortID
                ?? (selectedAgentID == agentID && selectedModelID == resolvedModelID ? selectedReasoningEffortID : nil)
                ?? resolvedModel?.supportedReasoningEfforts.first(where: {
                    $0.reasoningEffort == resolvedModel?.defaultReasoningEffort
                })?.reasoningEffort.wireValue

            selectedAgentID = agentID
            selectedModelID = resolvedModelID
            selectedReasoningEffortID = resolvedEffort
            setupComplete = true
            connectionState = .connected
            persistAgentSelection()
        } catch {
            connectionState = .failed(error.localizedDescription)
            agentError = error.localizedDescription
        }
    }

    func models(for runtimeID: String) -> [ModelInfo] {
        courseModels
            .filter { !$0.hidden && $0.agentRuntimeKind == runtimeID }
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                return modelPickerDisplayName($0).localizedCaseInsensitiveCompare(modelPickerDisplayName($1)) == .orderedAscending
            }
    }

    func defaultModelID(for runtimeID: String) -> String? {
        let choices = models(for: runtimeID)
        return choices.first(where: \.isDefault)?.id ?? choices.first?.id
    }

    func disconnectForAgentPicker() {
        setupComplete = false
        connectionState = .idle
        defaults.set(false, forKey: Self.setupKey)
    }

    func beginNewCourse() {
        agentForwardTask?.cancel()
        generationTask?.cancel()
        backgroundNodeGenerationTask?.cancel()
        if !currentWorkspaceWasBuilt {
            try? FileManager.default.removeItem(at: nativeCourseDirectory())
        }
        currentCourseWorkspaceID = UUID().uuidString.lowercased()
        currentAgentRuntimeID = selectedAgentID ?? "codex"
        currentAgentModelID = selectedModelID
        currentWorkspaceWasBuilt = false
        messages = []
        sources = []
        showsBrief = false
        brief = CourseBrief()
        generatedCourseID = nil
        agentThreadKey = nil
        agentError = nil
        generationError = nil
        isAgentRequestPending = false
        courseChatDraft = nil
        backgroundGeneratingCourseID = nil
        backgroundGeneratingNodeID = nil
        backgroundGenerationError = nil
        backgroundGenerationErrorCourseID = nil
        processedCoursePlanToolCallIDs = []
        navigationPath.append(.newCourse)
        prepareCourseWorkspace()
    }

    func addSource(_ source: CourseSource) {
        guard !sources.contains(where: { $0.name == source.name && $0.detail == source.detail }) else { return }
        do {
            sources.append(try persistImageSourceIfNeeded(source))
        } catch {
            agentError = "Couldn’t save that image: \(error.localizedDescription)"
        }
    }

    func removeSource(_ source: CourseSource) {
        sources.removeAll(where: { $0.id == source.id })
        guard source.runtimePath != nil else { return }
        let localURL = nativeSourcesDirectory().appendingPathComponent(URL(fileURLWithPath: source.runtimePath ?? "").lastPathComponent)
        try? FileManager.default.removeItem(at: localURL)
    }

    func sendMessage(_ text: String, appModel: AppModel, appState: AppState) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !sources.isEmpty else { return }
        guard !isAgentRequestPending else { return }

        messages.append(
            CourseChatMessage(
                role: .learner,
                text: trimmed,
                sources: sources
            )
        )

        let submittedSources = sources
        sources = []
        let workspaceID = currentCourseWorkspaceID

        isAgentRequestPending = true
        agentError = nil
        let previousTask = agentForwardTask
        agentForwardTask = Task { [weak self] in
            await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            await self.forwardToAgent(
                text: trimmed,
                submittedSources: submittedSources,
                workspaceID: workspaceID,
                appModel: appModel,
                appState: appState
            )
        }
    }

    func interruptAgent(appModel: AppModel) {
        Task { [weak self] in
            guard let self else { return }
            do {
                var activeThreadKey: ThreadKey?
                var activeTurnID: String?

                // Thread creation and the first active-turn snapshot can land a
                // fraction after the learner taps Stop. Wait briefly so that a
                // startup stop interrupts the server turn instead of only
                // cancelling the local response watcher.
                for _ in 0..<20 {
                    if let key = self.agentThreadKey,
                       let turnID = appModel.threadSnapshot(for: key)?.activeTurnId {
                        activeThreadKey = key
                        activeTurnID = turnID
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }

                guard let threadKey = activeThreadKey, let turnID = activeTurnID else {
                    self.agentForwardTask?.cancel()
                    self.isAgentRequestPending = false
                    return
                }

                _ = try await appModel.client.interruptTurn(
                    serverId: threadKey.serverId,
                    params: AppInterruptTurnRequest(
                        threadId: threadKey.threadId,
                        turnId: turnID
                    )
                )
                self.agentForwardTask?.cancel()
                self.isAgentRequestPending = false
            } catch {
                self.agentError = "Couldn’t stop the agent: \(error.localizedDescription)"
            }
        }
    }

    func approveCoursePlan(appModel: AppModel, appState: AppState) {
        guard showsBrief else { return }
        do {
            try persistApprovedPlan()
        } catch {
            generationError = "Couldn’t save the approved plan: \(error.localizedDescription)"
            return
        }

        buildCourse()
        let approval = "I approve course plan \(brief.planID), revision \(brief.revision). Bootstrap the course now from the approved plan: save my learner profile and course design, create the full folder structure and chapter outlines, but write full learning content only for Chapter 1. Write the bootstrap manifest when Chapter 1 is ready. Do not generate later chapter lessons yet."
        sendMessage(approval, appModel: appModel, appState: appState)
    }

    private func buildCourse() {
        generationTask?.cancel()
        generationStep = 0
        generationError = nil
        if navigationPath.last == .newCourse {
            navigationPath.removeLast()
        }
        navigationPath.append(.building)

        let workspaceID = currentCourseWorkspaceID
        let acceptedBrief = brief
        generationTask = Task { [weak self] in
            var observedAgentTurn = false
            for _ in 0..<3_600 {
                guard let self, !Task.isCancelled, self.currentCourseWorkspaceID == workspaceID else { return }
                let state = self.courseBuildState()
                self.generationStep = state.step
                if state.isComplete {
                    self.finishGeneratedCourse(brief: acceptedBrief, workspaceID: workspaceID)
                    return
                }
                if self.isAgentRequestPending {
                    observedAgentTurn = true
                } else if observedAgentTurn,
                          let agentError = self.agentError,
                          !agentError.contains("The agent is still working") {
                    self.generationError = "The course agent stopped: \(agentError)"
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let self, !Task.isCancelled, self.currentCourseWorkspaceID == workspaceID else { return }
            self.generationError = "The agent has not finished the course yet. You can return to its thread from Classic Litter to inspect progress."
        }
    }

    func openGeneratedCourse() {
        guard let generatedCourseID else { return }
        navigationPath = [.course(generatedCourseID)]
    }

    func leaveBuildingScreen() {
        if navigationPath.last == .building {
            navigationPath.removeLast()
        }
    }

    func returnToCourseAgent() {
        generationTask?.cancel()
        if navigationPath.last == .building {
            navigationPath.removeLast()
        }
        if navigationPath.last != .newCourse {
            navigationPath.append(.newCourse)
        }
    }

    func resumeCourseAgent(for course: LearningCourse) {
        guard configureCourseAgentContext(for: course) else { return }
        courseChatDraft = nil
        messages = []
        navigationPath.append(.newCourse)
    }

    func generateCourseNodeInBackground(
        for course: LearningCourse,
        node: CourseLearningNode,
        appModel: AppModel,
        appState: AppState
    ) {
        guard backgroundGeneratingNodeID == nil, !isAgentRequestPending else { return }
        guard configureCourseAgentContext(for: course) else {
            backgroundGenerationErrorCourseID = course.id
            backgroundGenerationError = "This course is no longer connected to its agent thread."
            return
        }

        let workspaceID = currentCourseWorkspaceID
        let prompt = Self.targetedGenerationPrompt(for: node)
        backgroundGeneratingCourseID = course.id
        backgroundGeneratingNodeID = node.id
        backgroundGenerationError = nil
        backgroundGenerationErrorCourseID = nil
        agentError = nil

        isAgentRequestPending = true
        let previousTask = agentForwardTask
        backgroundNodeGenerationTask?.cancel()
        backgroundNodeGenerationTask = Task { [weak self] in
            await previousTask?.value
            guard let self, !Task.isCancelled,
                  self.currentCourseWorkspaceID == workspaceID else { return }

            if let key = self.agentThreadKey,
               let hydratedKey = await appModel.hydrateThreadPermissions(for: key, appState: appState) {
                self.agentThreadKey = hydratedKey
            }

            await self.forwardToAgent(
                text: prompt,
                submittedSources: [],
                workspaceID: workspaceID,
                appModel: appModel,
                appState: appState
            )

            guard !Task.isCancelled, self.currentCourseWorkspaceID == workspaceID else { return }
            self.courseWorkspaceRefreshVersion += 1
            if let agentError = self.agentError {
                self.backgroundGenerationErrorCourseID = course.id
                self.backgroundGenerationError = "The course agent couldn’t generate \(node.title): \(agentError)"
            }
            self.backgroundGeneratingCourseID = nil
            self.backgroundGeneratingNodeID = nil
        }
    }

    static func targetedGenerationPrompt(for node: CourseLearningNode) -> String {
        let targetKind = node.kind == .folder ? "course section" : "module"
        return "Generate only the \(targetKind) ‘\(node.title)’ (node ID: \(node.id)) now. This request was started from the Learn screen, so work autonomously without asking for confirmation unless you are blocked. First read context/learner-profile.md, context/course-design.md, .course/agent-notes.md, .course/generation-state.json, and the relevant completed modules. Atomically mark only this node generating in course.json and generation-state.json, then create its Markdown modules and any necessary nested subsections. Mark only completed Markdown leaves generated; mark ancestor folders generated or partially_generated as appropriate. Update the index, README files, generation state, and manifest. Do not generate any sibling or later section."
    }

    private func configureCourseAgentContext(for course: LearningCourse) -> Bool {
        guard let workspaceID = course.workspaceID,
              let loadedBrief = courseBrief(for: course) else { return false }
        currentCourseWorkspaceID = workspaceID
        currentWorkspaceWasBuilt = true
        generatedCourseID = course.id
        brief = loadedBrief
        showsBrief = false
        sources = []
        agentError = nil
        generationError = nil
        agentThreadKey = nil
        currentAgentRuntimeID = course.agentRuntimeKind ?? "codex"
        currentAgentModelID = course.agentModelID
        if let serverID = course.agentServerID, let threadID = course.agentThreadID {
            agentThreadKey = ThreadKey(serverId: serverID, threadId: threadID)
        }
        return agentThreadKey != nil
    }

    func hydrateCourseThread(appModel: AppModel, appState: AppState) async {
        guard let key = agentThreadKey,
              let hydratedKey = await appModel.hydrateThreadPermissions(for: key, appState: appState) else { return }
        agentThreadKey = hydratedKey
        await appModel.loadInitialTurnsIfNeeded(threadId: hydratedKey)
    }

    func course(withID id: String) -> LearningCourse? {
        courses.first(where: { $0.id == id })
    }

    func courseDirectory(for course: LearningCourse) -> URL? {
        guard let workspaceID = course.workspaceID, !workspaceID.isEmpty else { return nil }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apps", isDirectory: true)
            .appendingPathComponent("Courses", isDirectory: true)
            .appendingPathComponent(workspaceID, isDirectory: true)
    }

    func courseBrief(for course: LearningCourse) -> CourseBrief? {
        guard let rootURL = courseDirectory(for: course) else {
            return generatedCourseID == course.id ? brief : nil
        }

        let approvedPlanURL = rootURL.appendingPathComponent(".course/approved-plan.json")
        var resolved = (try? Data(contentsOf: approvedPlanURL))
            .flatMap { try? JSONDecoder().decode(CourseBrief.self, from: $0) }
            ?? (generatedCourseID == course.id ? brief : CourseBrief())

        let metadataURL = rootURL.appendingPathComponent("course.json")
        guard let metadataData = try? Data(contentsOf: metadataURL) else {
            return resolved.planID.isEmpty && resolved.title.isEmpty && resolved.chapters.isEmpty ? nil : resolved
        }
        if let completeBrief = try? JSONDecoder().decode(CourseBrief.self, from: metadataData) {
            return completeBrief
        }
        guard let metadata = try? JSONDecoder().decode(CourseWorkspaceMetadata.self, from: metadataData) else {
            return resolved
        }

        resolved.planID = metadata.planID ?? resolved.planID
        resolved.revision = metadata.revision ?? resolved.revision
        resolved.title = metadata.title ?? resolved.title
        resolved.summary = metadata.summary ?? resolved.summary
        resolved.outcome = metadata.outcome ?? resolved.outcome
        resolved.estimatedDuration = metadata.estimatedDuration ?? resolved.estimatedDuration
        resolved.learningPath = metadata.learningPath ?? resolved.learningPath
        if let workspaceChapters = metadata.chapters, !workspaceChapters.isEmpty {
            let approvedByID = Dictionary(uniqueKeysWithValues: resolved.chapters.map { ($0.id, $0) })
            resolved.chapters = workspaceChapters.map { chapter in
                approvedByID[chapter.id] ?? CourseChapter(
                    id: chapter.id,
                    title: chapter.title,
                    objective: "",
                    deliverables: []
                )
            }
        }
        return resolved.planID.isEmpty && resolved.title.isEmpty && resolved.chapters.isEmpty ? nil : resolved
    }

    func openCourseFile(courseID: String, relativePath: String) {
        guard let course = course(withID: courseID),
              let rootURL = courseDirectory(for: course),
              (try? CourseWorkspaceSnapshot.validatedFileURL(
                  relativePath: relativePath,
                  rootURL: rootURL
              )) != nil else { return }
        navigationPath.append(.courseFile(courseID: courseID, relativePath: relativePath))
    }

    func nativeCourseDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apps", isDirectory: true)
            .appendingPathComponent("Courses", isDirectory: true)
            .appendingPathComponent(currentCourseWorkspaceID, isDirectory: true)
    }

    func nativeSourcesDirectory() -> URL {
        nativeCourseDirectory()
            .appendingPathComponent("sources", isDirectory: true)
            .appendingPathComponent("originals", isDirectory: true)
    }

    func copySourceIntoCourse(url: URL) throws -> CourseSource {
        let destinationDirectory = nativeSourcesDirectory()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let safeName = url.lastPathComponent.isEmpty ? "source" : url.lastPathComponent
        let destination = uniqueDestination(for: destinationDirectory.appendingPathComponent(safeName))
        try FileManager.default.copyItem(at: url, to: destination)
        let runtimePath = runtimeSourcePath(for: destination.lastPathComponent)
        return CourseSource(
            name: destination.deletingPathExtension().lastPathComponent,
            detail: destination.pathExtension.uppercased().isEmpty ? "FILE" : destination.pathExtension.uppercased(),
            kind: .document,
            runtimePath: runtimePath
        )
    }

    private func prepareCourseWorkspace() {
        try? FileManager.default.createDirectory(at: nativeSourcesDirectory(), withIntermediateDirectories: true)
    }

    private func persistApprovedPlan() throws {
        let metadataDirectory = nativeCourseDirectory().appendingPathComponent(".course", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.courseFileEncoder.encode(brief)
        try data.write(
            to: metadataDirectory.appendingPathComponent("approved-plan.json"),
            options: .atomic
        )
    }

    private func courseBuildState() -> (step: Int, isComplete: Bool) {
        Self.courseBuildState(root: nativeCourseDirectory(), brief: brief)
    }

    static func courseBuildState(root: URL, brief: CourseBrief) -> (step: Int, isComplete: Bool) {
        let fileManager = FileManager.default
        let hasIndex = fileManager.fileExists(atPath: root.appendingPathComponent("index.md").path)
        let hasCourseMetadata = fileManager.fileExists(atPath: root.appendingPathComponent("course.json").path)
        let hasLearnerProfile = fileManager.fileExists(atPath: root.appendingPathComponent("context/learner-profile.md").path)
        let hasCourseDesign = fileManager.fileExists(atPath: root.appendingPathComponent("context/course-design.md").path)
        let hasAgentNotes = fileManager.fileExists(atPath: root.appendingPathComponent(".course/agent-notes.md").path)
        let hasGenerationState = fileManager.fileExists(atPath: root.appendingPathComponent(".course/generation-state.json").path)
        let chapterFolders = brief.chapters.enumerated().map { index, chapter in
            root.appendingPathComponent(
                "chapters/\(String(format: "%02d", index + 1))-\(chapter.id)",
                isDirectory: true
            )
        }
        let hasAllChapterOutlines = chapterFolders.allSatisfy {
            fileManager.fileExists(atPath: $0.appendingPathComponent("README.md").path)
        }
        let courseMetadata = (try? Data(contentsOf: root.appendingPathComponent("course.json")))
            .flatMap { try? JSONDecoder().decode(CourseWorkspaceMetadata.self, from: $0) }
        let firstChapterNodes = courseMetadata?.learningPath?.first.map { [$0] } ?? []
        let hasFirstGeneratedContent = flattenLearningNodes(firstChapterNodes).contains { node in
            guard node.kind == .markdown,
                  node.status == .generated,
                  let relativePath = node.relativePath,
                  URL(fileURLWithPath: relativePath).lastPathComponent.lowercased() != "readme.md",
                  !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..") else { return false }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(
                atPath: root.appendingPathComponent(relativePath).path,
                isDirectory: &isDirectory
            ) && !isDirectory.boolValue
        }

        let manifestURL = root.appendingPathComponent(".course/build-manifest.json")
        let manifest: CourseBuildManifest?
        if let data = try? Data(contentsOf: manifestURL) {
            manifest = try? JSONDecoder().decode(CourseBuildManifest.self, from: data)
        } else {
            manifest = nil
        }
        let hasCompleteManifest = manifest.map { manifest in
            guard manifest.planID == brief.planID,
                  manifest.revision == brief.revision,
                  manifest.status == "bootstrap_complete",
                  manifest.generatedChapterIDs == Array(brief.chapters.prefix(1).map(\.id)),
                  manifest.nextChapterID == brief.chapters.dropFirst().first?.id,
                  !manifest.files.isEmpty else { return false }
            return manifest.files.allSatisfy { relativePath in
                guard !relativePath.hasPrefix("/"),
                      !relativePath.split(separator: "/").contains("..") else { return false }
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(
                    atPath: root.appendingPathComponent(relativePath).path,
                    isDirectory: &isDirectory
                )
                return exists
            }
        } ?? false

        var step = 0
        if hasLearnerProfile && hasCourseDesign && hasAgentNotes { step = 1 }
        if hasIndex && hasCourseMetadata { step = 2 }
        if hasAllChapterOutlines { step = 3 }
        if hasFirstGeneratedContent { step = 4 }
        if hasCompleteManifest { step = 5 }
        let bootstrapFilesReady = hasIndex
            && hasCourseMetadata
            && hasLearnerProfile
            && hasCourseDesign
            && hasAgentNotes
            && hasGenerationState
            && hasAllChapterOutlines
            && hasFirstGeneratedContent
        return (step, hasCompleteManifest && bootstrapFilesReady)
    }

    private static func flattenLearningNodes(_ nodes: [CourseLearningNode]) -> [CourseLearningNode] {
        nodes.flatMap { [$0] + flattenLearningNodes($0.children) }
    }

    private func persistImageSourceIfNeeded(_ source: CourseSource) throws -> CourseSource {
        guard source.kind == .image, source.runtimePath == nil, let image = source.image else { return source }
        let directory = nativeSourcesDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueDestination(for: directory.appendingPathComponent("reference-image.jpg"))
        guard let data = image.jpegData(compressionQuality: 0.94) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: destination, options: .atomic)
        var persisted = source
        persisted.name = destination.deletingPathExtension().lastPathComponent
        persisted.runtimePath = runtimeSourcePath(for: destination.lastPathComponent)
        return persisted
    }

    private func runtimeSourcePath(for filename: String) -> String {
        "/mnt/apps/Courses/\(currentCourseWorkspaceID)/sources/originals/\(filename)"
    }

    private func uniqueDestination(for proposed: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let base = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        let parent = proposed.deletingLastPathComponent()
        for index in 2...999 {
            let candidateName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = parent.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return parent.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
    }

    private func forwardToAgent(
        text: String,
        submittedSources: [CourseSource],
        workspaceID: String,
        appModel: AppModel,
        appState: AppState
    ) async {
        defer { isAgentRequestPending = false }
        do {
            guard !Task.isCancelled, currentCourseWorkspaceID == workspaceID else { return }
            let serverID = try await connectedLocalServerID(appModel: appModel)
            let runtimeID = currentAgentRuntimeID ?? selectedAgentID ?? "codex"
            if runtimeID == .codex {
                guard try await appModel.ensureLocalAuthForThreadStart(serverId: serverID) else {
                    agentError = "Codex authentication was cancelled. Reconnect the agent to continue."
                    return
                }
            }

            let threadKey: ThreadKey
            let startsNewThread = agentThreadKey == nil
            if let existingThreadKey = agentThreadKey {
                threadKey = existingThreadKey
            } else {
                let launch = AppThreadLaunchConfig(
                    agentRuntimeKind: runtimeID,
                    model: currentAgentModelID ?? selectedModelID,
                    approvalPolicy: .never,
                    sandbox: .workspaceWrite,
                    developerInstructions: Self.courseAgentInstructions,
                    persistExtendedHistory: true
                )
                let startedThreadKey = try await appModel.client.startThread(
                    serverId: serverID,
                    params: launch.threadStartRequest(
                        cwd: "/mnt/apps/Courses/\(workspaceID)",
                        dynamicTools: try courseDynamicToolSpecs(appModel: appModel, serverID: serverID)
                    )
                )
                guard !Task.isCancelled, currentCourseWorkspaceID == workspaceID else { return }
                agentThreadKey = startedThreadKey
                threadKey = startedThreadKey
            }

            let fileAttachments = submittedSources.compactMap { source -> ComposerFileAttachment? in
                guard let runtimePath = source.runtimePath else { return nil }
                return ComposerFileAttachment(label: source.name, path: runtimePath)
            }
            let imageInputs = submittedSources.compactMap { source in
                source.image.flatMap(ConversationAttachmentSupport.prepareImage)?.userInput
            }
            let previousResponseTurnID = appModel.snapshot?.sessionSummaries
                .first(where: { $0.key == threadKey })?.lastResponseTurnId
            let payload = AppComposerPayload(
                text: text,
                additionalInputs: imageInputs,
                fileAttachments: fileAttachments,
                approvalPolicy: .never,
                sandboxPolicy: TurnSandboxPolicy.workspaceWrite.ffiValue,
                model: startsNewThread ? (currentAgentModelID ?? selectedModelID) : nil,
                effort: startsNewThread ? ReasoningEffort(wireValue: selectedReasoningEffortID) : nil,
                serviceTier: nil
            )
            guard !Task.isCancelled, currentCourseWorkspaceID == workspaceID else { return }
            try await appModel.startTurn(key: threadKey, payload: payload)
            await hydrateAgentResponse(
                for: threadKey,
                previousResponseTurnID: previousResponseTurnID,
                workspaceID: workspaceID,
                appModel: appModel
            )
        } catch {
            guard !Task.isCancelled, currentCourseWorkspaceID == workspaceID else { return }
            agentError = error.localizedDescription
        }
    }

    private func hydrateAgentResponse(
        for key: ThreadKey,
        previousResponseTurnID: String?,
        workspaceID: String,
        appModel: AppModel
    ) async {
        var receivedCoursePlan = false
        for _ in 0..<480 {
            guard !Task.isCancelled, currentCourseWorkspaceID == workspaceID else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, currentCourseWorkspaceID == workspaceID else { return }
            receivedCoursePlan = hydrateCoursePlanToolCalls(for: key, appModel: appModel) || receivedCoursePlan
            guard let summary = appModel.snapshot?.sessionSummaries.first(where: { $0.key == key }) else { continue }
            let response = summary.lastResponsePreview?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard summary.hasActiveTurn == false else { continue }
            if let response,
               !response.isEmpty,
               summary.lastResponseTurnId != previousResponseTurnID {
                messages.append(CourseChatMessage(role: .agent, text: response))
                return
            }
            if receivedCoursePlan { return }
        }
        guard !Task.isCancelled, currentCourseWorkspaceID == workspaceID else { return }
        agentError = "The agent is still working. Open Classic Litter from the home menu to inspect the live thread."
    }

    private func hydrateCoursePlanToolCalls(for key: ThreadKey, appModel: AppModel) -> Bool {
        guard let thread = appModel.threadSnapshot(for: key) else { return false }
        var appliedPlan = false
        for item in thread.hydratedConversationItems {
            guard !processedCoursePlanToolCallIDs.contains(item.id) else { continue }
            guard case .dynamicToolCall(let data) = item.content,
                  data.tool == CourseAgentTools.presentPlan,
                  data.status == .completed else { continue }
            processedCoursePlanToolCallIDs.insert(item.id)
            guard data.success != false,
                  let arguments = data.argumentsJson,
                  let json = arguments.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(CourseBrief.self, from: json) else {
                agentError = "The agent presented an invalid course plan. Ask it to present the plan again."
                continue
            }
            brief = decoded
            showsBrief = true
            appliedPlan = true
        }
        return appliedPlan
    }

    private func courseDynamicToolSpecs(appModel: AppModel, serverID: String) throws -> [AppDynamicToolSpec] {
        var tools = appModel.localGenerativeUiToolSpecs(for: serverID) ?? []
        tools.removeAll(where: { $0.name == CourseAgentTools.presentPlan })
        tools.append(try CourseAgentTools.dynamicToolSpec())
        return tools
    }

    private func connectedLocalServerID(appModel: AppModel) async throws -> String {
        if let local = appModel.snapshot?.servers.first(where: \.isLocal) {
            return local.serverId
        }
        let serverID = try await appModel.serverBridge.connectLocalServer(
            serverId: "local",
            displayName: appModel.resolvedLocalServerDisplayName(),
            host: "127.0.0.1",
            port: 0
        )
        await appModel.restoreStoredLocalAuthState(serverId: serverID)
        await appModel.refreshSnapshot()
        return serverID
    }

    private func finishGeneratedCourse(brief: CourseBrief, workspaceID: String) {
        guard currentCourseWorkspaceID == workspaceID else { return }
        currentWorkspaceWasBuilt = true
        let titleParts = brief.title.split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let title = titleParts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "New Course"
        let subtitle = titleParts.count > 1 ? titleParts[1] : "Built for you"
        let id = slug(for: title)
        generatedCourseID = id
        let course = LearningCourse(
            id: id,
            title: title,
            subtitle: subtitle,
            accentHex: "1F6FEB",
            progress: 0,
            lessonCount: brief.chapters.count,
            duration: brief.estimatedDuration,
            status: .ready,
            workspaceID: workspaceID,
            agentServerID: agentThreadKey?.serverId,
            agentThreadID: agentThreadKey?.threadId,
            agentRuntimeKind: currentAgentRuntimeID ?? selectedAgentID ?? "codex",
            agentModelID: currentAgentModelID ?? selectedModelID
        )
        courses.removeAll(where: { $0.id == id })
        courses.insert(course, at: 0)
        persistCourses()
    }

    private func slug(for title: String) -> String {
        let pieces = title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        let value = pieces.filter { !$0.isEmpty }.joined(separator: "-")
        return value.isEmpty ? currentCourseWorkspaceID : value
    }

    private func persistCourses() {
        guard let data = try? JSONEncoder().encode(courses) else { return }
        defaults.set(data, forKey: Self.coursesKey)
    }

    private func refreshAgentCatalog(appModel: AppModel, serverID: String) {
        guard let server = appModel.snapshot?.serverSnapshot(for: serverID) else { return }
        let metadataIDs = AgentRuntimeKind.presentationOrder
        let knownIDs = metadataIDs.isEmpty ? Self.coldStartRuntimeIDs : metadataIDs
        agentOptions = CourseAgentOption.catalog(from: server.agentRuntimes, knownRuntimeIDs: knownIDs)
        if metadataIDs.isEmpty {
            agentOptions = agentOptions.map { option in
                CourseAgentOption(
                    id: option.id,
                    title: option.available ? option.title : CourseAgentOption.coldStartTitle(for: option.id),
                    available: option.available
                )
            }
        }
        courseModels = appModel.availableModels(for: serverID)
    }

    private func persistAgentSelection() {
        defaults.set(selectedAgentID, forKey: Self.agentKey)
        defaults.set(selectedModelID, forKey: Self.modelKey)
        defaults.set(selectedReasoningEffortID, forKey: Self.effortKey)
        defaults.set(true, forKey: Self.setupKey)
    }

    static let courseAgentInstructions = """
    You are the persistent course agent for one learner and one course. Work only inside this course folder. Treat files under sources/originals as the learner's source library. Read images directly, extract PDFs and documents when needed, and fetch URLs the learner sends.

    This course folder is mounted into the mobile runtime. The built-in `apply_patch` tool cannot resolve this mounted workspace and MUST NOT be used here. Create and update course files with shell filesystem commands scoped strictly to the current course directory. Never write outside the current course directory.

    Before proposing a course, you MUST assess the learner instead of guessing their level. Ask concise, conversational questions that establish:
    - what they can already explain or do without help;
    - their prior experience and prerequisite knowledge;
    - their concrete goal and why they want to learn this now;
    - the depth, pace, examples, and learning style that would work for them;
    - misconceptions or gaps, using one or two diagnostic questions when useful.

    Do not call `present_course_plan` after only a topic name or a vague level label such as beginner/intermediate/advanced. Ask at least one diagnostic question that lets the learner demonstrate understanding. Keep the assessment proportionate: typically 2-5 focused questions over a natural conversation, fewer only when the learner has already supplied equivalent evidence in their message or sources.

    When you have enough evidence, briefly say you are ready to propose a plan, then call `present_course_plan`. The plan's starting_point and focus_gap must reflect the assessment evidence, not assumptions. Never print the plan as JSON, XML, or a Markdown table. The native app renders the tool arguments as the plan card. If the learner requests changes, discuss them normally and call `present_course_plan` again with the same plan_id and a higher revision.

    Do not begin building until the learner sends a message explicitly approving a plan ID and revision. After approval:
    1. Read `.course/approved-plan.json` as the canonical contract.
    2. Create `context/learner-profile.md` recording assessed knowledge, demonstrated strengths, gaps or misconceptions, goals, preferences, and constraints. Separate evidence from inference.
    3. Create `context/course-design.md` explaining the chosen sequence, depth, teaching approach, and how it adapts to the learner.
    4. Create `.course/agent-notes.md` for concise private continuity notes that future course turns must reread and update.
    5. Create `index.md` with the overview and links to Chapter 1's lesson and every later chapter's README outline.
    6. Create `course.json` with the approved course metadata, ordered chapter list, and a recursive `learning_path` array that drives the native Learn tab. Every learning-path node must contain `id`, `title`, `kind`, `status`, `relative_path`, and `children`. Use `kind: "folder"` for chapters, subchapters, and groups; use `kind: "markdown"` only for leaf modules that open in the reader. Folder nodes have a null relative_path. Markdown nodes have a workspace-relative path to their `.md` file.
    7. Use exactly these learning-path statuses: `pending_generation`, `generating`, `partially_generated`, and `generated`. A pending node shows Generate; a generating node shows progress; a partially-generated folder expands to mixed child states; a generated folder expands; and a generated Markdown leaf opens its file. Never mark a Markdown node generated until its file exists. Keep node IDs stable across every update.
    8. Create every physical folder as `chapters/<two-digit-number>-<chapter-id>/` and put a `README.md` in every chapter. Chapters may contain nested subchapter folders and multiple Markdown module files. Each README contains status, objective, prerequisites, planned concepts, and deliverables. Chapter 1 is generated; all later chapters begin pending_generation.
    9. Generate actual learning content ONLY for Chapter 1: one or more Markdown module leaves, practice, plus examples or assets when useful. Do not create full module content for later chapters during bootstrap.
    10. Put generated or copied supporting media under `assets/`; never modify `sources/originals`. Keep Markdown useful without network access.
    11. Write `.course/generation-state.json` with `plan_id`, `revision`, `status: "ready_for_learning"`, `generated_chapter_ids` containing only Chapter 1's ID, `next_chapter_id` containing Chapter 2's ID or null, and `node_statuses` mapping every stable learning-path node ID to its status.
    12. Finally write `.course/build-manifest.json` atomically with `plan_id`, `revision`, `status: "bootstrap_complete"`, `files`, `generated_chapter_ids`, and `next_chapter_id`. List only paths that exist; regular files are preferred, but an intentionally empty directory may also be listed with a trailing slash. This manifest means the structure and Chapter 1 are ready, not that the whole course has been written.

    On later turns, the learner may give feedback or ask for any pending chapter, subchapter, or module by node ID. First reread `context/learner-profile.md`, `context/course-design.md`, `.course/agent-notes.md`, `.course/generation-state.json`, and relevant completed work. Incorporate useful feedback into the profile or agent notes. Atomically mark only the requested node `generating`, create exactly that node's content and descendants, then mark its completed leaves `generated` and ancestors `generated` or `partially_generated` as appropriate. Update course.json, README files, index, generation state, and manifest. Do not generate siblings or later sections. If the learner only gives feedback without asking to generate, update notes as appropriate and respond conversationally; do not start generation.

    You may update the learner conversationally while working, but the manifest is the native app's bootstrap completion signal.
    """
}

private extension JSONEncoder {
    static var courseFileEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
