import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum CourseAgentProvider {
    enum CompactionFallback: Equatable {
        case localSummary
        case targetProvider(String)
    }

    static let codex = "codex"
    static let appleOnDevice = "apple-on-device"
    static let applePrivateCloud = "apple-private-cloud"

    static func isApple(_ id: String) -> Bool {
        id == appleOnDevice || id == applePrivateCloud
    }

    static func canContinueThread(from current: String, with proposed: String) -> Bool {
        current == proposed || (isApple(current) && isApple(proposed))
    }

    static func preferredDefault(in options: [CourseAgentOption]) -> String? {
        for id in [applePrivateCloud, appleOnDevice, codex] {
            if options.first(where: { $0.id == id })?.available == true {
                return id
            }
        }
        return options.first(where: \.available)?.id
    }

    static func compactionFallback(
        from sourceProviderID: String,
        to targetProviderID: String
    ) -> CompactionFallback? {
        if
            sourceProviderID == applePrivateCloud,
            targetProviderID == appleOnDevice
        {
            return .localSummary
        }
        if
            sourceProviderID == appleOnDevice,
            targetProviderID == applePrivateCloud
        {
            return .targetProvider(targetProviderID)
        }
        return nil
    }
}

struct AppleCourseContextBudget: Equatable, Sendable {
    let triggerTokens: Int
    let summaryTokenLimit: Int

    static func forProvider(_ providerID: String) -> Self {
        if providerID == CourseAgentProvider.applePrivateCloud {
            return Self(triggerTokens: 27_500, summaryTokenLimit: 1_500)
        }
        return Self(triggerTokens: 6_500, summaryTokenLimit: 1_500)
    }

    func estimatedTokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let byteEstimate = Int(ceil(Double(text.utf8.count) / 4.0))
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let wordPieceEstimate = Int(ceil(Double(wordCount) * 1.35))
        let nonASCIIEstimate = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !scalar.isASCII {
                count += 1
            }
        }
        return max(byteEstimate, wordPieceEstimate, nonASCIIEstimate)
    }

    func shouldCompact(currentContext: String, incomingPrompt: String) -> Bool {
        estimatedTokens(in: currentContext)
            + estimatedTokens(in: incomingPrompt)
            >= triggerTokens
    }

    func effectiveTrigger(contextSize: Int) -> Int {
        // The compaction request must fit the old context and still leave
        // enough output room for the durable summary plus instructions.
        let runtimeSafeTrigger = contextSize - summaryTokenLimit - 512
        return min(triggerTokens, max(summaryTokenLimit, runtimeSafeTrigger))
    }

    func shouldCompact(
        currentContext: String,
        incomingPrompt: String,
        contextSize: Int
    ) -> Bool {
        estimatedTokens(in: currentContext)
            + estimatedTokens(in: incomingPrompt)
            >= effectiveTrigger(contextSize: contextSize)
    }
}

enum AppleCourseApprovalPolicy {
    static let presentedPlanFilename = "presented-plan.json"
    static let approvedPlanFilename = "approved-plan.json"

    static func isLatestPlanApproved(courseDirectory: URL) -> Bool {
        let metadataDirectory = courseDirectory.appendingPathComponent(".course", isDirectory: true)
        guard
            let presentedData = try? Data(
                contentsOf: metadataDirectory.appendingPathComponent(presentedPlanFilename)
            ),
            let approvedData = try? Data(
                contentsOf: metadataDirectory.appendingPathComponent(approvedPlanFilename)
            ),
            let presented = try? JSONDecoder().decode(CourseBrief.self, from: presentedData),
            let approved = try? JSONDecoder().decode(CourseBrief.self, from: approvedData),
            !presented.planID.isEmpty,
            presented.planID == approved.planID,
            presented.revision == approved.revision
        else {
            return false
        }
        return true
    }
}

struct AppleCourseAgentAvailability: Equatable, Sendable {
    struct Capability: Equatable, Sendable {
        let available: Bool
        let reason: String
    }

    let onDevice: Capability
    let privateCloud: Capability

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        if let forced = forcedAvailability(environment: environment) {
            return forced
        }

        let onDevice = onDeviceCapability()
        return Self(
            onDevice: onDevice,
            privateCloud: privateCloudCapability()
        )
    }

    private static func forcedAvailability(environment: [String: String]) -> Self? {
        let onDeviceValue = environment["SNAPPY_APPLE_ON_DEVICE_AVAILABLE"]
        let cloudValue = environment["SNAPPY_APPLE_PRIVATE_CLOUD_AVAILABLE"]
        guard onDeviceValue != nil || cloudValue != nil else { return nil }

        func capability(_ value: String?, name: String) -> Capability {
            if value == "1" {
                return Capability(available: true, reason: "\(name) is available.")
            }
            return Capability(available: false, reason: "\(name) was disabled for this test run.")
        }

        return Self(
            onDevice: capability(onDeviceValue, name: "Apple On-Device"),
            privateCloud: capability(cloudValue, name: "Private Cloud Compute")
        )
    }

    private static func onDeviceCapability() -> Capability {
        guard #available(iOS 26.0, *) else {
            return Capability(
                available: false,
                reason: "Requires iOS 26 and an Apple Intelligence-capable iPhone."
            )
        }
#if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return Capability(available: true, reason: "Runs privately on this iPhone.")
        case .unavailable(.deviceNotEligible):
            return Capability(
                available: false,
                reason: "This iPhone does not support Apple Intelligence."
            )
        case .unavailable(.appleIntelligenceNotEnabled):
            return Capability(
                available: false,
                reason: "Turn on Apple Intelligence in Settings to use this agent."
            )
        case .unavailable(.modelNotReady):
            return Capability(
                available: false,
                reason: "Apple’s on-device model is still downloading or not ready."
            )
        @unknown default:
            return Capability(available: false, reason: "Apple’s on-device model is unavailable.")
        }
#else
        return Capability(available: false, reason: "Foundation Models is not present in this build.")
#endif
    }

    private static func privateCloudCapability() -> Capability {
#if LEARNFOLD_PRIVATE_CLOUD_COMPUTE_SDK && canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            switch model.availability {
            case .available:
                if model.quotaUsage.isLimitReached {
                    return Capability(
                        available: false,
                        reason: "Private Cloud Compute’s daily allowance has been reached."
                    )
                }
                return Capability(
                    available: true,
                    reason: "Uses Apple Private Cloud Compute for larger course requests."
                )
            case .unavailable(.deviceNotEligible):
                return Capability(
                    available: false,
                    reason: "This iPhone is not eligible for Apple Private Cloud Compute."
                )
            case .unavailable(.systemNotReady):
                return Capability(
                    available: false,
                    reason: "Private Cloud Compute is not ready. Check Apple Intelligence and your network."
                )
            case .unavailable:
                return Capability(
                    available: false,
                    reason: "Private Cloud Compute is unavailable."
                )
            @unknown default:
                return Capability(available: false, reason: "Private Cloud Compute is unavailable.")
            }
        }
#endif
        return Capability(
            available: false,
            reason: "Requires iOS 27 and Learnfold’s Apple Private Cloud Compute entitlement."
        )
    }
}

enum AppleCoursePlanValidator {
    static func issue(in brief: CourseBrief) -> String? {
        func containsSerializedKeyFragment(_ value: String) -> Bool {
            let normalized = value.lowercased()
            let schemaKeys = [
                "chapters",
                "deliverables",
                "estimated_duration",
                "focus_gap",
                "objective",
                "outcome",
                "plan_id",
                "revision",
                "starting_point",
                "summary",
                "title",
            ]
            return schemaKeys.contains { key in
                normalized.contains("\(key):")
                    || normalized.contains("\"\(key)\":")
            }
        }

        func isNaturalLanguage(_ value: String, minimumWords: Int = 2) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                trimmed.unicodeScalars.contains(where: CharacterSet.letters.contains),
                !trimmed.hasPrefix(","),
                !trimmed.hasPrefix("}"),
                !trimmed.hasPrefix("]"),
                !trimmed.hasSuffix(":"),
                !containsSerializedKeyFragment(trimmed)
            else {
                return false
            }
            return trimmed.split(whereSeparator: \.isWhitespace).count >= minimumWords
        }

        let planIDPattern = /^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$/
        if brief.planID.wholeMatch(of: planIDPattern) == nil || brief.revision < 1 {
            return "plan_id must be non-empty and revision must be positive"
        }
        if !isNaturalLanguage(brief.title) {
            return "title must be a natural-language course title"
        }
        let narrativeFields = [
            brief.summary,
            brief.outcome,
            brief.startingPoint,
            brief.focusGap,
            brief.estimatedDuration,
        ]
        if narrativeFields.contains(where: { !isNaturalLanguage($0) }) {
            return "all plan summary fields must contain natural language, not serialized schema fragments"
        }
        if !(1...8).contains(brief.chapters.count) {
            return "the plan must contain between 1 and 8 chapters"
        }
        let chapterIDs = brief.chapters.map(\.id)
        if Set(chapterIDs).count != chapterIDs.count {
            return "chapter IDs must be unique"
        }
        for chapter in brief.chapters {
            if chapter.id.wholeMatch(of: planIDPattern) == nil
                || !isNaturalLanguage(chapter.title)
                || !isNaturalLanguage(chapter.objective)
            {
                return "every chapter needs a valid ID plus natural-language title and objective"
            }
            if chapter.deliverables.isEmpty
                || chapter.deliverables.contains(where: { !isNaturalLanguage($0) })
            {
                return "every chapter needs at least one natural-language deliverable"
            }
        }
        return nil
    }
}

enum AppleCourseGenerationSchemaOrdering {
    private static let preferredOrder = [
        "operation",
        "plan_id",
        "revision",
        "title",
        "summary",
        "outcome",
        "starting_point",
        "focus_gap",
        "estimated_duration",
        "id",
        "objective",
        "deliverables",
        "chapters",
        "arguments_json",
        "plan",
    ]

    static func orderedKeys(in properties: [String: [String: Any]]) -> [String] {
        properties.keys.sorted { lhs, rhs in
            let lhsRank = preferredOrder.firstIndex(of: lhs) ?? preferredOrder.count
            let rhsRank = preferredOrder.firstIndex(of: rhs) ?? preferredOrder.count
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            let lhsIsComplex = ["array", "object"].contains(properties[lhs]?["type"] as? String)
            let rhsIsComplex = ["array", "object"].contains(properties[rhs]?["type"] as? String)
            if lhsIsComplex != rhsIsComplex {
                return !lhsIsComplex
            }
            return lhs < rhs
        }
    }
}

struct AppleCourseAgentStoredMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case learner
        case agent
    }

    let role: Role
    let text: String
}

enum AppleCourseAgentError: LocalizedError {
    case unavailable(String)
    case invalidProvider
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .invalidProvider:
            return "This conversation cannot be moved to that agent."
        case .toolFailed(let message):
            return message
        }
    }
}

enum AppleCoursePrivateCloudRetryPolicy {
    static let maximumCancellationRetries = 2
    static let mutationFreeAttemptTimeout: Duration = .seconds(90)

    static func canCancelHungAttempt(
        taskWasCancelled: Bool,
        latestResponse: String,
        didPresentCoursePlan: Bool,
        didAttemptEditorMutation: Bool
    ) -> Bool {
        !taskWasCancelled
            && latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !didPresentCoursePlan
            && !didAttemptEditorMutation
    }

    static func canRetryCancellation(
        retryCount: Int,
        taskWasCancelled: Bool,
        latestResponse: String,
        didPresentCoursePlan: Bool,
        didAttemptEditorMutation: Bool
    ) -> Bool {
        retryCount < maximumCancellationRetries
            && canCancelHungAttempt(
                taskWasCancelled: taskWasCancelled,
                latestResponse: latestResponse,
                didPresentCoursePlan: didPresentCoursePlan,
                didAttemptEditorMutation: didAttemptEditorMutation
            )
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@MainActor
final class AppleCourseLiveSessionCallbacks {
    private var onCoursePlan: @MainActor (CourseBrief) throws -> Void
    private var onEditorMutationAttempt: @MainActor () -> Void

    init(
        onCoursePlan: @escaping @MainActor (CourseBrief) throws -> Void,
        onEditorMutationAttempt: @escaping @MainActor () -> Void
    ) {
        self.onCoursePlan = onCoursePlan
        self.onEditorMutationAttempt = onEditorMutationAttempt
    }

    func rebind(
        onCoursePlan: @escaping @MainActor (CourseBrief) throws -> Void,
        onEditorMutationAttempt: @escaping @MainActor () -> Void
    ) {
        self.onCoursePlan = onCoursePlan
        self.onEditorMutationAttempt = onEditorMutationAttempt
    }

    func presentCoursePlan(_ plan: CourseBrief) throws {
        try onCoursePlan(plan)
    }

    func recordEditorMutationAttempt() {
        onEditorMutationAttempt()
    }
}
#endif

@MainActor
protocol AppleCourseAgentRuntime: AnyObject {
    func availability() -> AppleCourseAgentAvailability
    func restoredMessages(sessionID: UUID, workspaceID: String) async -> [AppleCourseAgentStoredMessage]
    func send(
        sessionID: UUID,
        providerID: String,
        workspaceID: String,
        prompt: String,
        onPartialResponse: @escaping @MainActor (String) -> Void,
        onCoursePlan: @escaping @MainActor (CourseBrief) throws -> Void
    ) async throws
    func cancel(sessionID: UUID)
    func remove(sessionID: UUID, workspaceID: String)
}

@MainActor
final class SystemAppleCourseAgentRuntime: AppleCourseAgentRuntime {
    static let shared = SystemAppleCourseAgentRuntime()

    private let environment: [String: String]

#if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private struct LiveSession {
        let workspaceID: String
        let providerID: String
        let session: LanguageModelSession
        let callbacks: AppleCourseLiveSessionCallbacks
    }

    @available(iOS 26.0, *)
    private final class LiveSessionStore {
        var sessions: [UUID: LiveSession] = [:]
    }

    private var liveSessionStorage: Any?
#endif
    private var activeTasks: [UUID: Task<Void, Error>] = [:]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func availability() -> AppleCourseAgentAvailability {
        AppleCourseAgentAvailability.current(environment: environment)
    }

    func restoredMessages(
        sessionID: UUID,
        workspaceID: String
    ) async -> [AppleCourseAgentStoredMessage] {
        (try? loadState(sessionID: sessionID, workspaceID: workspaceID).messages) ?? []
    }

    func send(
        sessionID: UUID,
        providerID: String,
        workspaceID: String,
        prompt: String,
        onPartialResponse: @escaping @MainActor (String) -> Void,
        onCoursePlan: @escaping @MainActor (CourseBrief) throws -> Void
    ) async throws {
        guard CourseAgentProvider.isApple(providerID) else {
            throw AppleCourseAgentError.invalidProvider
        }
        let capability = providerID == CourseAgentProvider.applePrivateCloud
            ? availability().privateCloud
            : availability().onDevice
        guard capability.available else {
            throw AppleCourseAgentError.unavailable(capability.reason)
        }
        guard #available(iOS 26.0, *) else {
            throw AppleCourseAgentError.unavailable("Apple Foundation Models requires iOS 26 or later.")
        }
#if canImport(FoundationModels)
        LLog.info(
            "AppleCourseAgent",
            "send started",
            fields: [
                "provider": providerID,
                "session_id": sessionID.uuidString.lowercased(),
                "workspace_id": workspaceID,
            ]
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var state = (try? loadState(sessionID: sessionID, workspaceID: workspaceID))
                ?? PersistedState(
                    providerID: providerID,
                    transcript: nil,
                    compactedSummary: nil,
                    messages: []
            )
            var didPresentCoursePlan = false
            var didAttemptEditorMutation = false
            let trackedOnCoursePlan: @MainActor (CourseBrief) throws -> Void = { plan in
                didPresentCoursePlan = true
                LLog.info(
                    "AppleCourseAgent",
                    "course plan tool called",
                    fields: [
                        "chapter_count": plan.chapters.count,
                        "revision": plan.revision,
                        "session_id": sessionID.uuidString.lowercased(),
                    ]
                )
                try onCoursePlan(plan)
            }
            let budget = AppleCourseContextBudget.forProvider(providerID)
            if let transcriptData = state.transcript,
               let transcript = try? JSONDecoder().decode(Transcript.self, from: transcriptData) {
                let providerChanged = state.providerID != providerID
                let contextIsFull = await shouldCompact(
                    providerID: providerID,
                    transcript: transcript,
                    incomingPrompt: prompt,
                    budget: budget
                )
                if providerChanged || contextIsFull {
                    // Rebase every Apple model switch through a summary.
                    // Besides fitting a PCC transcript into the smaller
                    // on-device window, this removes the previous model's
                    // injected tool definitions before the target session
                    // installs its own schema.
                    let compactionProvider = state.providerID
                    let summary: String
                    do {
                        summary = try await compactedSummary(
                            providerID: compactionProvider,
                            workspaceID: workspaceID,
                            transcript: transcript,
                            previousSummary: state.compactedSummary,
                            tokenLimit: budget.summaryTokenLimit
                        )
                    } catch {
                        guard providerChanged else {
                            throw error
                        }
                        switch CourseAgentProvider.compactionFallback(
                            from: compactionProvider,
                            to: providerID
                        ) {
                        case .localSummary:
                            // PCC may be offline or quota-limited precisely
                            // when a learner needs to fall back. Preserve
                            // durable state and the newest context locally.
                            summary = Self.localTransitionSummary(
                                workspaceID: workspaceID,
                                transcript: transcript,
                                previousSummary: state.compactedSummary,
                                tokenLimit: budget.summaryTokenLimit
                            )
                        case .targetProvider(let targetProviderID):
                            // If Apple Intelligence becomes unavailable, the
                            // already-validated PCC target can summarize the
                            // smaller on-device transcript before taking over.
                            summary = try await compactedSummary(
                                providerID: targetProviderID,
                                workspaceID: workspaceID,
                                transcript: transcript,
                                previousSummary: state.compactedSummary,
                                tokenLimit: budget.summaryTokenLimit
                            )
                        case nil:
                            throw error
                        }
                    }
                    state.compactedSummary = summary
                    state.transcript = nil
                    liveSessionStore().sessions[sessionID] = nil
                    try saveState(state, sessionID: sessionID, workspaceID: workspaceID)
                }
            }
            if state.transcript == nil {
                try await validateInitialTurnFits(
                    providerID: providerID,
                    workspaceID: workspaceID,
                    compactedSummary: state.compactedSummary,
                    prompt: prompt,
                    onCoursePlan: trackedOnCoursePlan
                )
            }
            let session = try makeSession(
                sessionID: sessionID,
                providerID: providerID,
                workspaceID: workspaceID,
                persistedTranscript: state.transcript,
                compactedSummary: state.compactedSummary,
                onCoursePlan: trackedOnCoursePlan,
                onEditorMutationAttempt: {
                    didAttemptEditorMutation = true
                    LLog.info(
                        "AppleCourseAgent",
                        "editor mutation tool entered",
                        fields: ["session_id": sessionID.uuidString.lowercased()]
                    )
                }
            )
            state.messages.append(.init(role: .learner, text: prompt))
            try saveState(state, sessionID: sessionID, workspaceID: workspaceID)
            LLog.info(
                "AppleCourseAgent",
                "request state persisted",
                fields: [
                    "has_transcript": state.transcript != nil,
                    "message_count": state.messages.count,
                    "session_id": sessionID.uuidString.lowercased(),
                ]
            )

            var latest = ""
            var completedSession = session
            @MainActor
            func consume(
                _ activeSession: LanguageModelSession,
                attemptNumber: Int
            ) async throws {
                let runtimePrompt = Self.runtimePrompt(
                    for: prompt,
                    providerID: providerID
                )
                LLog.info(
                    "AppleCourseAgent",
                    "generation attempt started",
                    fields: [
                        "attempt": attemptNumber,
                        "provider": providerID,
                        "session_id": sessionID.uuidString.lowercased(),
                    ]
                )
#if LEARNFOLD_PRIVATE_CLOUD_COMPUTE_SDK
                if providerID == CourseAgentProvider.applePrivateCloud,
                   #available(iOS 27.0, *) {
                    let stream = activeSession.streamResponse(
                        to: runtimePrompt,
                        contextOptions: ContextOptions(reasoningLevel: .light)
                    )
                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        latest = snapshot.content
                        onPartialResponse(latest)
                    }
                    LLog.info(
                        "AppleCourseAgent",
                        "generation attempt completed",
                        fields: [
                            "attempt": attemptNumber,
                            "did_attempt_editor_mutation": didAttemptEditorMutation,
                            "did_present_course_plan": didPresentCoursePlan,
                            "response_characters": latest.count,
                            "session_id": sessionID.uuidString.lowercased(),
                        ]
                    )
                    return
                }
#endif
                let stream = activeSession.streamResponse(to: runtimePrompt)
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    latest = snapshot.content
                    onPartialResponse(latest)
                }
                LLog.info(
                    "AppleCourseAgent",
                    "generation attempt completed",
                    fields: [
                        "attempt": attemptNumber,
                        "did_attempt_editor_mutation": didAttemptEditorMutation,
                        "did_present_course_plan": didPresentCoursePlan,
                        "response_characters": latest.count,
                        "session_id": sessionID.uuidString.lowercased(),
                    ]
                )
            }
            var privateCloudCancellationRetryCount = 0
            @MainActor
            func consumeWithPrivateCloudTimeout(
                _ activeSession: LanguageModelSession,
                attemptNumber: Int
            ) async throws {
                guard providerID == CourseAgentProvider.applePrivateCloud else {
                    try await consume(activeSession, attemptNumber: attemptNumber)
                    return
                }

                let generationTask = Task { @MainActor in
                    try await consume(activeSession, attemptNumber: attemptNumber)
                }
                let watchdogTask = Task { @MainActor in
                    do {
                        try await Task.sleep(
                            for: AppleCoursePrivateCloudRetryPolicy.mutationFreeAttemptTimeout
                        )
                    } catch {
                        return
                    }
                    guard AppleCoursePrivateCloudRetryPolicy.canCancelHungAttempt(
                        taskWasCancelled: generationTask.isCancelled,
                        latestResponse: latest,
                        didPresentCoursePlan: didPresentCoursePlan,
                        didAttemptEditorMutation: didAttemptEditorMutation
                    ) else {
                        LLog.info(
                            "AppleCourseAgent",
                            "PCC watchdog left active attempt running",
                            fields: [
                                "attempt": attemptNumber,
                                "did_attempt_editor_mutation": didAttemptEditorMutation,
                                "did_present_course_plan": didPresentCoursePlan,
                                "response_characters": latest.count,
                                "session_id": sessionID.uuidString.lowercased(),
                            ]
                        )
                        return
                    }
                    LLog.warn(
                        "AppleCourseAgent",
                        "cancelling unresolved mutation-free PCC attempt",
                        fields: [
                            "attempt": attemptNumber,
                            "session_id": sessionID.uuidString.lowercased(),
                            "timeout_seconds": 90,
                        ]
                    )
                    generationTask.cancel()
                }
                defer { watchdogTask.cancel() }
                try await generationTask.value
                if generationTask.isCancelled {
                    // PCC's AsyncSequence may finish normally after cancellation instead of
                    // throwing. Normalize that zero-output completion so the existing
                    // mutation-safe cancellation retry policy still runs.
                    throw CancellationError()
                }
            }
            @MainActor
            func preparePrivateCloudCancellationRetry() throws -> Bool {
                guard providerID == CourseAgentProvider.applePrivateCloud,
                      AppleCoursePrivateCloudRetryPolicy.canRetryCancellation(
                        retryCount: privateCloudCancellationRetryCount,
                        taskWasCancelled: Task.isCancelled,
                        latestResponse: latest,
                        didPresentCoursePlan: didPresentCoursePlan,
                        didAttemptEditorMutation: didAttemptEditorMutation
                      ) else { return false }
                privateCloudCancellationRetryCount += 1
                LLog.warn(
                    "AppleCourseAgent",
                    "retrying mutation-free PCC cancellation",
                    fields: [
                        "next_attempt": privateCloudCancellationRetryCount + 1,
                        "session_id": sessionID.uuidString.lowercased(),
                    ]
                )
                liveSessionStore().sessions[sessionID] = nil
                didPresentCoursePlan = false
                didAttemptEditorMutation = false
                completedSession = try makeSession(
                    sessionID: sessionID,
                    providerID: providerID,
                    workspaceID: workspaceID,
                    persistedTranscript: state.transcript,
                    compactedSummary: state.compactedSummary,
                    onCoursePlan: trackedOnCoursePlan,
                    onEditorMutationAttempt: {
                        didAttemptEditorMutation = true
                        LLog.info(
                            "AppleCourseAgent",
                            "editor mutation tool entered",
                            fields: ["session_id": sessionID.uuidString.lowercased()]
                        )
                    }
                )
                return true
            }
            @MainActor
            func recoverFromContextOverflow(_ originalError: any Error) async throws {
                guard
                    latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let transcriptData = state.transcript,
                    let transcript = try? JSONDecoder().decode(
                        Transcript.self,
                        from: transcriptData
                    ),
                    transcriptText(session.transcript) == transcriptText(transcript)
                else {
                    // A partial response or transcript change may include an
                    // already-executed side effect. Never replay the learner's
                    // turn when mutation safety cannot be proven.
                    throw originalError
                }
                let compactionProvider = state.providerID
                let summary = try await compactedSummary(
                    providerID: compactionProvider,
                    workspaceID: workspaceID,
                    transcript: transcript,
                    previousSummary: state.compactedSummary,
                    tokenLimit: budget.summaryTokenLimit
                )
                state.compactedSummary = summary
                state.transcript = nil
                liveSessionStore().sessions[sessionID] = nil
                try saveState(state, sessionID: sessionID, workspaceID: workspaceID)
                completedSession = try makeSession(
                    sessionID: sessionID,
                    providerID: providerID,
                    workspaceID: workspaceID,
                    persistedTranscript: nil,
                    compactedSummary: summary,
                    onCoursePlan: trackedOnCoursePlan,
                    onEditorMutationAttempt: {
                        didAttemptEditorMutation = true
                        LLog.info(
                            "AppleCourseAgent",
                            "editor mutation tool entered",
                            fields: ["session_id": sessionID.uuidString.lowercased()]
                        )
                    }
                )
                latest = ""
                try await consumeWithPrivateCloudTimeout(
                    completedSession,
                    attemptNumber: privateCloudCancellationRetryCount + 1
                )
            }
            do {
                do {
#if LEARNFOLD_PRIVATE_CLOUD_COMPUTE_SDK
                    while true {
                        do {
                            try await consumeWithPrivateCloudTimeout(
                                completedSession,
                                attemptNumber: privateCloudCancellationRetryCount + 1
                            )
                            break
                        } catch {
                            LLog.error(
                                "AppleCourseAgent",
                                "generation attempt failed",
                                error: error,
                                fields: [
                                    "attempt": privateCloudCancellationRetryCount + 1,
                                    "did_attempt_editor_mutation": didAttemptEditorMutation,
                                    "did_present_course_plan": didPresentCoursePlan,
                                    "error_type": String(reflecting: type(of: error)),
                                    "response_characters": latest.count,
                                    "session_id": sessionID.uuidString.lowercased(),
                                    "task_cancelled": Task.isCancelled,
                                ]
                            )
                            if error is CancellationError,
                               try preparePrivateCloudCancellationRetry() {
                                continue
                            }
                            if #available(iOS 27.0, *),
                               let modelError = error as? LanguageModelError,
                               case .contextSizeExceeded(let context) = modelError {
                                try await recoverFromContextOverflow(
                                    AppleCourseAgentError.toolFailed(context.debugDescription)
                                )
                                break
                            }
                            throw error
                        }
                    }
#else
                    try await consumeWithPrivateCloudTimeout(session, attemptNumber: 1)
#endif
                } catch let error as LanguageModelSession.GenerationError {
                    guard case .exceededContextWindowSize = error else {
                        throw error
                    }
                    try await recoverFromContextOverflow(error)
                }
                state.providerID = providerID
                state.transcript = try JSONEncoder().encode(completedSession.transcript)
                if !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.messages.append(.init(role: .agent, text: latest))
                }
                try saveState(state, sessionID: sessionID, workspaceID: workspaceID)
                LLog.info(
                    "AppleCourseAgent",
                    "send completed and transcript persisted",
                    fields: [
                        "message_count": state.messages.count,
                        "session_id": sessionID.uuidString.lowercased(),
                    ]
                )
            } catch {
                LLog.error(
                    "AppleCourseAgent",
                    "send failed",
                    error: error,
                    fields: [
                        "did_attempt_editor_mutation": didAttemptEditorMutation,
                        "did_present_course_plan": didPresentCoursePlan,
                        "error_type": String(reflecting: type(of: error)),
                        "response_characters": latest.count,
                        "session_id": sessionID.uuidString.lowercased(),
                        "task_cancelled": Task.isCancelled,
                    ]
                )
                state.providerID = providerID
                state.transcript = try? JSONEncoder().encode(completedSession.transcript)
                if !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.messages.append(.init(role: .agent, text: latest))
                }
                try? saveState(state, sessionID: sessionID, workspaceID: workspaceID)
                liveSessionStore().sessions[sessionID] = nil
                if let toolError = error as? LanguageModelSession.ToolCallError {
                    if let courseError = toolError.underlyingError as? AppleCourseAgentError {
                        throw courseError
                    }
                    throw AppleCourseAgentError.toolFailed(
                        "Apple’s model could not complete that course action. Please try again."
                    )
                }
                if error is CancellationError, !Task.isCancelled {
                    throw AppleCourseAgentError.toolFailed(
                        "Apple Private Cloud did not finish that request. Please try again."
                    )
                }
                throw error
            }
        }
        activeTasks[sessionID] = task
        defer { activeTasks[sessionID] = nil }
        try await task.value
#else
        throw AppleCourseAgentError.unavailable("Foundation Models is not present in this build.")
#endif
    }

    func cancel(sessionID: UUID) {
        activeTasks[sessionID]?.cancel()
        activeTasks[sessionID] = nil
    }

    func remove(sessionID: UUID, workspaceID: String) {
        cancel(sessionID: sessionID)
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            liveSessionStore().sessions[sessionID] = nil
        }
#endif
        try? FileManager.default.removeItem(
            at: stateURL(sessionID: sessionID, workspaceID: workspaceID)
        )
    }

    private struct PersistedState: Codable {
        var providerID: String
        var transcript: Data?
        var compactedSummary: String?
        var messages: [AppleCourseAgentStoredMessage]
    }

    private func loadState(sessionID: UUID, workspaceID: String) throws -> PersistedState {
        let data = try Data(contentsOf: stateURL(sessionID: sessionID, workspaceID: workspaceID))
        return try JSONDecoder().decode(PersistedState.self, from: data)
    }

    private func saveState(
        _ state: PersistedState,
        sessionID: UUID,
        workspaceID: String
    ) throws {
        let url = stateURL(sessionID: sessionID, workspaceID: workspaceID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    private func stateURL(sessionID: UUID, workspaceID: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apps", isDirectory: true)
            .appendingPathComponent("Courses", isDirectory: true)
            .appendingPathComponent(workspaceID, isDirectory: true)
            .appendingPathComponent(".course", isDirectory: true)
            .appendingPathComponent("apple-agent-\(sessionID.uuidString.lowercased()).json")
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private extension SystemAppleCourseAgentRuntime {
    static func courseDirectory(workspaceID: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apps", isDirectory: true)
            .appendingPathComponent("Courses", isDirectory: true)
            .appendingPathComponent(workspaceID, isDirectory: true)
    }

    private func liveSessionStore() -> LiveSessionStore {
        if let store = liveSessionStorage as? LiveSessionStore {
            return store
        }
        let store = LiveSessionStore()
        liveSessionStorage = store
        return store
    }

    func makeSession(
        sessionID: UUID,
        providerID: String,
        workspaceID: String,
        persistedTranscript: Data?,
        compactedSummary: String?,
        onCoursePlan: @escaping @MainActor (CourseBrief) throws -> Void,
        onEditorMutationAttempt: @escaping @MainActor () -> Void = {}
    ) throws -> LanguageModelSession {
        if let cached = liveSessionStore().sessions[sessionID],
           cached.workspaceID == workspaceID,
           cached.providerID == providerID {
            cached.callbacks.rebind(
                onCoursePlan: onCoursePlan,
                onEditorMutationAttempt: onEditorMutationAttempt
            )
            LLog.info(
                "AppleCourseAgent",
                "reusing live model session with rebound callbacks",
                fields: [
                    "provider": providerID,
                    "session_id": sessionID.uuidString.lowercased(),
                ]
            )
            return cached.session
        }

        let callbacks = AppleCourseLiveSessionCallbacks(
            onCoursePlan: onCoursePlan,
            onEditorMutationAttempt: onEditorMutationAttempt
        )
        let tools = try AppleCourseToolFactory.tools(
            providerID: providerID,
            workspaceID: workspaceID,
            onCoursePlan: { plan in
                try callbacks.presentCoursePlan(plan)
            },
            onEditorMutationAttempt: {
                callbacks.recordEditorMutationAttempt()
            }
        )
        let transcript = persistedTranscript.flatMap {
            try? JSONDecoder().decode(Transcript.self, from: $0)
        }
        let instructions = Self.instructions(
            providerID: providerID,
            compactedSummary: compactedSummary
        )
        let session: LanguageModelSession
        if providerID == CourseAgentProvider.applePrivateCloud {
#if LEARNFOLD_PRIVATE_CLOUD_COMPUTE_SDK
            if #available(iOS 27.0, *) {
                if let transcript {
                    session = LanguageModelSession(
                        model: PrivateCloudComputeLanguageModel(),
                        tools: tools,
                        transcript: transcript
                    )
                } else {
                    session = LanguageModelSession(
                        model: PrivateCloudComputeLanguageModel(),
                        tools: tools,
                        instructions: instructions
                    )
                }
            } else {
                throw AppleCourseAgentError.unavailable("Private Cloud Compute requires iOS 27.")
            }
#else
            throw AppleCourseAgentError.unavailable(
                "This Learnfold build does not include the iOS 27 Private Cloud Compute SDK."
            )
#endif
        } else if let transcript {
            session = LanguageModelSession(
                model: SystemLanguageModel.default,
                tools: tools,
                transcript: transcript
            )
        } else {
            session = LanguageModelSession(
                model: SystemLanguageModel.default,
                tools: tools,
                instructions: instructions
            )
        }
        liveSessionStore().sessions[sessionID] = LiveSession(
            workspaceID: workspaceID,
            providerID: providerID,
            session: session,
            callbacks: callbacks
        )
        LLog.info(
            "AppleCourseAgent",
            "created live model session",
            fields: [
                "has_persisted_transcript": transcript != nil,
                "provider": providerID,
                "session_id": sessionID.uuidString.lowercased(),
            ]
        )
        return session
    }

    func validateInitialTurnFits(
        providerID: String,
        workspaceID: String,
        compactedSummary: String?,
        prompt: String,
        onCoursePlan: @escaping @MainActor (CourseBrief) throws -> Void
    ) async throws {
        guard
            providerID == CourseAgentProvider.appleOnDevice,
            #available(iOS 26.4, *)
        else {
            return
        }

        do {
            let model = SystemLanguageModel.default
            let tools = try AppleCourseToolFactory.tools(
                providerID: providerID,
                workspaceID: workspaceID,
                onCoursePlan: onCoursePlan
            )
            let instructionTokens = try await model.tokenCount(
                for: Instructions(
                    Self.instructions(
                        providerID: providerID,
                        compactedSummary: compactedSummary
                    )
                )
            )
            let toolTokens = try await model.tokenCount(for: tools)
            let promptTokens = try await model.tokenCount(
                for: Self.runtimePrompt(for: prompt, providerID: providerID)
            )
            // A first turn has no transcript to compact. Keep room for a
            // useful response or a plan tool call and fail with actionable
            // copy instead of exposing the framework's overflow error.
            let responseReserve = min(768, max(256, model.contextSize / 5))
            guard
                instructionTokens + toolTokens + promptTokens
                    < model.contextSize - responseReserve
            else {
                throw AppleCourseAgentError.toolFailed(
                    """
                    This first request is too long for Apple On-Device’s context window. Shorten \
                    it or start this course with Apple Private Cloud Compute.
                    """
                )
            }
        } catch let error as AppleCourseAgentError {
            throw error
        } catch {
            // Token counting can become unavailable while Apple Intelligence
            // changes state. Generation still owns the final error boundary.
        }
    }

    func compactedSummary(
        providerID: String,
        workspaceID: String,
        transcript: Transcript,
        previousSummary: String?,
        tokenLimit: Int
    ) async throws -> String {
        let session: LanguageModelSession
        if providerID == CourseAgentProvider.applePrivateCloud {
#if LEARNFOLD_PRIVATE_CLOUD_COMPUTE_SDK
            if #available(iOS 27.0, *) {
                session = LanguageModelSession(
                    model: PrivateCloudComputeLanguageModel(),
                    instructions: Self.compactionInstructions
                )
            } else {
                throw AppleCourseAgentError.unavailable("Private Cloud Compute requires iOS 27.")
            }
#else
            throw AppleCourseAgentError.unavailable(
                "This Learnfold build does not include the iOS 27 Private Cloud Compute SDK."
            )
#endif
        } else {
            session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: Self.compactionInstructions
            )
        }

        let response = try await session.respond(
            to: Self.compactionPrompt(
                workspaceID: workspaceID,
                transcript: transcript,
                previousSummary: previousSummary
            ),
            options: GenerationOptions(
                sampling: .greedy,
                temperature: 0,
                maximumResponseTokens: tokenLimit
            )
        )
        let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw AppleCourseAgentError.toolFailed(
                "The Apple course agent could not compact its working context."
            )
        }
        return summary
    }

    func transcriptText(_ transcript: Transcript) -> String {
        transcript.map(\.description).joined(separator: "\n")
    }

    func shouldCompact(
        providerID: String,
        transcript: Transcript,
        incomingPrompt: String,
        budget: AppleCourseContextBudget
    ) async -> Bool {
        let contextSize: Int
        if providerID == CourseAgentProvider.applePrivateCloud {
#if LEARNFOLD_PRIVATE_CLOUD_COMPUTE_SDK
            if #available(iOS 27.0, *) {
                contextSize = (try? await PrivateCloudComputeLanguageModel().contextSize)
                    ?? 32_768
            } else {
                contextSize = 32_768
            }
#else
            contextSize = 32_768
#endif
        } else {
            contextSize = SystemLanguageModel.default.contextSize
        }

        if providerID == CourseAgentProvider.appleOnDevice,
           #available(iOS 26.4, *) {
            do {
                let model = SystemLanguageModel.default
                let transcriptTokens = try await model.tokenCount(for: transcript)
                let promptTokens = try await model.tokenCount(
                    for: Self.runtimePrompt(
                        for: incomingPrompt,
                        providerID: providerID
                    )
                )
                return transcriptTokens + promptTokens
                    >= budget.effectiveTrigger(contextSize: contextSize)
            } catch {
                // Availability can change while counting. The conservative
                // text estimate remains a safe fallback and the generation
                // error path still provides a final recovery boundary.
            }
        }

        return budget.shouldCompact(
            currentContext: transcriptText(transcript),
            incomingPrompt: incomingPrompt,
            contextSize: contextSize
        )
    }

    static func instructions(
        providerID _: String,
        compactedSummary: String?
    ) -> String {
        let toolInstructions = """
        Use learnfold_course_action. To propose or revise a plan, set operation to \
        present_course_plan and fill every typed plan field directly. For native course reads or \
        edits, set operation to the native-editor tool name, put that tool’s JSON object in \
        arguments_json, and omit the plan fields.
        """
        let baseInstructions = """
        \(appleInstructions)

        \(toolInstructions)
        """
        guard let compactedSummary, !compactedSummary.isEmpty else {
            return baseInstructions
        }
        return """
        \(baseInstructions)

        Durable summary of the earlier conversation and course state:
        \(compactedSummary)

        Treat the summary as prior context. Do not mention that compaction occurred unless the \
        learner asks.
        """
    }

    static var compactionInstructions: String {
        """
        Produce a dense, faithful working-memory summary for another Learnfold course agent. \
        Preserve the learner’s goal, starting knowledge, preferences, constraints, decisions, \
        unresolved questions, source links, exact course/page/tool IDs, revision numbers, tool \
        results, and the latest presented/approved plan status. Drop pleasantries, repetition, and \
        superseded drafts. Never invent facts. Use compact Markdown headings and bullets.
        """
    }

    static func compactionPrompt(
        workspaceID: String,
        transcript: Transcript,
        previousSummary: String?
    ) -> String {
        let transcriptBody = transcript.map(\.description).joined(separator: "\n")
        var sections = [
            "Workspace ID: \(workspaceID)",
        ]
        if
            let previousSummary,
            !previousSummary.isEmpty,
            !transcriptBody.contains(previousSummary)
        {
            sections.append("Earlier compacted summary:\n\(previousSummary)")
        }
        if let durableState = durableCourseState(workspaceID: workspaceID) {
            sections.append("Authoritative persisted plan state:\n\(durableState)")
        }
        sections.append("Transcript to compact:\n\(transcriptBody)")
        return sections.joined(separator: "\n\n")
    }

    static func durableCourseState(workspaceID: String) -> String? {
        let metadata = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Apps", isDirectory: true)
            .appendingPathComponent("Courses", isDirectory: true)
            .appendingPathComponent(workspaceID, isDirectory: true)
            .appendingPathComponent(".course", isDirectory: true)
        let filenames = [
            AppleCourseApprovalPolicy.presentedPlanFilename,
            AppleCourseApprovalPolicy.approvedPlanFilename,
        ]
        let entries = filenames.compactMap { filename -> String? in
            guard
                let data = try? Data(
                    contentsOf: metadata.appendingPathComponent(filename)
                ),
                let plan = try? JSONDecoder().decode(CourseBrief.self, from: data)
            else {
                return nil
            }
            return """
            \(filename): plan_id=\(plan.planID), revision=\(plan.revision), \
            title=\(plan.title), chapters=\(plan.chapters.count)
            """
        }
        return entries.isEmpty ? nil : entries.joined(separator: "\n")
    }

    static func localTransitionSummary(
        workspaceID: String,
        transcript: Transcript,
        previousSummary: String?,
        tokenLimit: Int
    ) -> String {
        let estimator = AppleCourseContextBudget(
            triggerTokens: tokenLimit,
            summaryTokenLimit: tokenLimit
        )
        var sections = [
            """
            # Apple provider transition
            Workspace ID: \(workspaceID)
            PCC could not perform the transition summary. Preserve the authoritative persisted \
            state and newest transcript context below.
            """,
        ]
        if let durable = durableCourseState(workspaceID: workspaceID) {
            sections.append("# Persisted plan state\n\(durable)")
        }
        if let previousSummary, !previousSummary.isEmpty {
            sections.append(
                "# Earlier durable summary\n"
                    + boundedText(
                        previousSummary,
                        maximumTokens: max(256, tokenLimit / 2),
                        fromEnd: false,
                        estimator: estimator
                    )
            )
        }
        let usedTokens = estimator.estimatedTokens(in: sections.joined(separator: "\n\n"))
        let remainingTokens = max(256, tokenLimit - usedTokens)
        sections.append(
            "# Most recent transcript context\n"
                + boundedText(
                    transcript.map(\.description).joined(separator: "\n"),
                    maximumTokens: remainingTokens,
                    fromEnd: true,
                    estimator: estimator
                )
        )
        return boundedText(
            sections.joined(separator: "\n\n"),
            maximumTokens: tokenLimit,
            fromEnd: false,
            estimator: estimator
        )
    }

    static func boundedText(
        _ text: String,
        maximumTokens: Int,
        fromEnd: Bool,
        estimator: AppleCourseContextBudget
    ) -> String {
        guard estimator.estimatedTokens(in: text) > maximumTokens else {
            return text
        }
        var lower = 0
        var upper = text.count
        var best = ""
        while lower <= upper {
            let candidateCount = (lower + upper) / 2
            let candidate = fromEnd
                ? String(text.suffix(candidateCount))
                : String(text.prefix(candidateCount))
            if estimator.estimatedTokens(in: candidate) <= maximumTokens {
                best = candidate
                lower = candidateCount + 1
            } else {
                upper = candidateCount - 1
            }
        }
        return best
    }

    static var appleInstructions: String {
        """
        You are Learnfold’s course agent. Answer the learner directly and concisely. Assess their \
        starting point before proposing a new course. When you are ready to propose or revise a \
        course plan, you MUST call present_course_plan. Never print or summarize plan fields, \
        chapters, plan IDs, or revisions in chat. Use the exact chapter count requested by the \
        learner; otherwise choose 3 to 8 focused chapters. Never write course pages before the \
        learner approves that plan. After approval, use the native-editor tools for all course \
        content. Fetch immediately before updating a page and always use its latest \
        expected_revision. Generate the full course hierarchy but initially write complete learning \
        content only for Chapter 1. For a selected-passage question, autonomously choose the \
        smallest sufficient response: answer only in chat for a short-lived clarification; add or \
        revise a focused section on the referenced page when it durably improves that lesson; or \
        create an explainer child page and link it from the lesson when a reusable deep dive would \
        interrupt the lesson’s flow. Do not edit merely because tools are available, preserve \
        unrelated content, and never claim an edit succeeded until the native-editor tool returns \
        success.
        """
    }

    static func runtimePrompt(
        for learnerPrompt: String,
        providerID _: String
    ) -> String {
        return """
        \(learnerPrompt)

        Learnfold runtime rule: If this turn is ready to propose or revise a course plan, do not \
        describe that plan in chat; call present_course_plan with every typed plan field instead. \
        Otherwise reply normally.
        """
    }
}

@available(iOS 26.0, *)
private enum AppleCourseToolFactory {
    static func tools(
        providerID _: String,
        workspaceID: String,
        onCoursePlan: @escaping @MainActor (CourseBrief) throws -> Void,
        onEditorMutationAttempt: @escaping @MainActor () -> Void = {}
    ) throws -> [any Tool] {
        let planSpec = try presentCoursePlanSpec()
        let editorSpec = try editorActionSpec()
        return [
            try AppleDynamicCourseTool(spec: planSpec) { generatedJSON in
                let brief: CourseBrief
                do {
                    brief = try JSONDecoder().decode(
                        CourseBrief.self,
                        from: Data(generatedJSON.utf8)
                    )
                } catch {
                    return try rejection(
                        """
                        The generated plan did not match the tool schema. Call \
                        present_course_plan again with every typed plan field. Do not print the \
                        plan in chat.
                        """
                    )
                }
                return try await present(
                    brief,
                    retryToolName: CourseAgentTools.presentPlan,
                    onCoursePlan: onCoursePlan
                )
            },
            try AppleDynamicCourseTool(spec: editorSpec) { generatedJSON in
                let action: EditorAction
                do {
                    action = try JSONDecoder().decode(
                        EditorAction.self,
                        from: Data(generatedJSON.utf8)
                    )
                } catch {
                    return try rejection(
                        """
                        The editor action did not match the tool schema. Call \
                        learnfold_editor_action again with a supported operation and its valid \
                        arguments_json object.
                        """
                    )
                }
                if isMutation(action.operation) {
                    await onEditorMutationAttempt()
                }
                return try await execute(
                    operation: action.operation,
                    argumentsJSON: action.argumentsJSON,
                    workspaceID: workspaceID
                )
            },
        ]
    }

    private struct EditorAction: Decodable {
        let operation: String
        let argumentsJSON: String

        enum CodingKeys: String, CodingKey {
            case operation
            case argumentsJSON = "arguments_json"
        }
    }

    private static func execute(
        operation: String,
        argumentsJSON: String,
        workspaceID: String
    ) async throws -> String {
        let validEditorTools = Set(try CourseAgentTools.documentToolSpecs().map(\.name))
        guard validEditorTools.contains(operation) else {
            throw AppleCourseAgentError.toolFailed("Unknown Learnfold course action.")
        }
        if isMutation(operation) {
            guard AppleCourseApprovalPolicy.isLatestPlanApproved(
                courseDirectory: courseDirectory(workspaceID: workspaceID)
            ) else {
                return try rejection(
                    """
                    Course changes are locked until the learner approves the latest presented \
                    plan. Do not retry the editor mutation. Call present_course_plan with every \
                    typed plan field, then wait for learner approval.
                    """
                )
            }
        }
        guard let result = await CourseDocumentRegistry.shared.handle(
            workspaceID: workspaceID,
            tool: operation,
            argumentsJSON: argumentsJSON
        ) else {
            throw AppleCourseAgentError.toolFailed("The native course document is not open.")
        }
        let data = try JSONEncoder().encode(result.value)
        let text = String(decoding: data, as: UTF8.self)
        if result.isError {
            return try rejection(
                """
                The native editor rejected that action: \(text). Correct arguments_json and call \
                learnfold_course_action again.
                """
            )
        }
        return text
    }

    private static func present(
        _ brief: CourseBrief,
        retryToolName: String,
        onCoursePlan: @escaping @MainActor (CourseBrief) throws -> Void
    ) async throws -> String {
        if let issue = AppleCoursePlanValidator.issue(in: brief) {
            return try rejection(
                """
                The plan was not shown because \(issue). Correct the plan and call \
                \(retryToolName) again. Do not print the plan in chat.
                """
            )
        }
        try await onCoursePlan(brief)
        return #"{"accepted":true,"message":"The plan is ready for learner approval."}"#
    }

    private static func presentCoursePlanSpec() throws -> AppDynamicToolSpec {
        let source = try CourseAgentTools.dynamicToolSpec()
        guard
            let plan = try JSONSerialization.jsonObject(
                with: Data(source.inputSchemaJson.utf8)
            ) as? [String: Any],
            var properties = plan["properties"] as? [String: Any],
            var chapters = properties["chapters"] as? [String: Any]
        else {
            throw AppleCourseAgentError.toolFailed(
                "Learnfold could not construct the Apple On-Device course tool schema."
            )
        }
        chapters["minItems"] = 1
        chapters["maxItems"] = 8
        chapters["description"] = """
        Use exactly the chapter count requested by the learner; otherwise create 3 to 8 focused \
        chapters. Never add placeholder chapters.
        """
        if
            var chapter = chapters["items"] as? [String: Any],
            var chapterProperties = chapter["properties"] as? [String: Any],
            var deliverables = chapterProperties["deliverables"] as? [String: Any]
        {
            deliverables["minItems"] = 1
            deliverables["maxItems"] = 6
            chapterProperties["deliverables"] = deliverables
            chapter["properties"] = chapterProperties
            chapters["items"] = chapter
        }
        properties["chapters"] = chapters
        var root = plan
        root["properties"] = properties
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return AppDynamicToolSpec(
            name: source.name,
            description: """
            Present the complete typed course plan in Learnfold's approval card. Use exactly the \
            requested chapter count, fill every field, do not print the plan in chat, and wait \
            for learner approval before calling learnfold_editor_action.
            """,
            inputSchemaJson: String(decoding: data, as: UTF8.self),
            deferLoading: false
        )
    }

    private static func editorActionSpec() throws -> AppDynamicToolSpec {
        let root: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "operation": [
                    "type": "string",
                    "description": "The approved native-editor operation to execute.",
                    "enum": [
                        "native-editor-search",
                        "native-editor-fetch",
                        "native-editor-create-pages",
                        "native-editor-update-page",
                        "native-editor-move-pages",
                        "native-editor-duplicate-page",
                        "native-editor-get-async-task",
                    ],
                ],
                "arguments_json": [
                    "type": "string",
                    "description": """
                    A valid JSON object for the selected native-editor operation. For \
                    native-editor-create-pages, every item in pages must contain properties with \
                    a nonempty title.
                    """,
                ],
            ],
            "required": ["operation", "arguments_json"],
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return AppDynamicToolSpec(
            name: "learnfold_editor_action",
            description: """
            Read or change the approved native course. Never call a mutating operation until the \
            learner approves the latest plan. Pass the native editor's JSON object in \
            arguments_json.
            """,
            inputSchemaJson: String(decoding: data, as: UTF8.self),
            deferLoading: false
        )
    }

    private static func rejection(_ message: String) throws -> String {
        let payload: [String: Any] = [
            "accepted": false,
            "message": message,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static func isMutation(_ tool: String) -> Bool {
        !["native-editor-search", "native-editor-fetch", "native-editor-get-async-task"].contains(tool)
    }

    private static func courseDirectory(workspaceID: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apps", isDirectory: true)
            .appendingPathComponent("Courses", isDirectory: true)
            .appendingPathComponent(workspaceID, isDirectory: true)
    }
}

@available(iOS 26.0, *)
private struct AppleDynamicCourseTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    private let handler: @Sendable (String) async throws -> String

    init(
        spec: AppDynamicToolSpec,
        handler: @escaping @Sendable (String) async throws -> String
    ) throws {
        // Foundation Models tool identifiers follow Swift-style identifier
        // rules. The native editor's public names use hyphens, so expose a
        // stable underscored name while keeping the original name captured by
        // the handler for repository dispatch.
        name = spec.name.replacingOccurrences(of: "-", with: "_")
        description = spec.description
        parameters = try Self.generationSchema(
            name: spec.name,
            schemaJSON: spec.inputSchemaJson
        )
        self.handler = handler
    }

    func call(arguments: GeneratedContent) async throws -> String {
        try await handler(arguments.jsonString)
    }

    private static func generationSchema(name: String, schemaJSON: String) throws -> GenerationSchema {
        let object = try JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))
        guard let schema = object as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        let root = try dynamicSchema(name: name.replacingOccurrences(of: "-", with: "_"), schema: schema)
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func dynamicSchema(
        name: String,
        schema: [String: Any]
    ) throws -> DynamicGenerationSchema {
        if let choices = schema["enum"] as? [String] {
            return DynamicGenerationSchema(
                name: "\(name)_choice",
                description: schema["description"] as? String,
                anyOf: choices
            )
        }
        switch schema["type"] as? String {
        case "object":
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])
            return DynamicGenerationSchema(
                name: name,
                description: schema["description"] as? String,
                properties: try AppleCourseGenerationSchemaOrdering
                    .orderedKeys(in: properties)
                    .map { key in
                    DynamicGenerationSchema.Property(
                        name: key,
                        description: properties[key]?["description"] as? String,
                        schema: try dynamicSchema(name: "\(name)_\(key)", schema: properties[key] ?? [:]),
                        isOptional: !required.contains(key)
                    )
                }
            )
        case "array":
            let item = schema["items"] as? [String: Any] ?? ["type": "string"]
            return DynamicGenerationSchema(
                arrayOf: try dynamicSchema(name: "\(name)_item", schema: item),
                minimumElements: schema["minItems"] as? Int,
                maximumElements: schema["maxItems"] as? Int
            )
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }
}
#endif
