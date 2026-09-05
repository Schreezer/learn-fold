import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum CourseRequestLifecycle: String, Equatable {
    case optimistic
    case thinking
    case streaming
    case stopping
    case reconnecting

    static func project(
        runPhase: CourseChatRunPhase,
        isAgentWorking: Bool,
        hasAssistantContent: Bool,
        isReconnecting: Bool
    ) -> Self? {
        if isReconnecting {
            return .reconnecting
        }

        switch runPhase {
        case .submitting:
            return .optimistic
        case .running:
            return hasAssistantContent ? .streaming : .thinking
        case .stopping:
            return .stopping
        case .idle, .failed:
            guard isAgentWorking else { return nil }
            return hasAssistantContent ? .streaming : .thinking
        }
    }
}

enum CourseFocusedQAState: String, Equatable {
    case initialSheet = "initial-sheet"
    case thinking
    case answer

    static func project(
        requestLifecycle: CourseRequestLifecycle?,
        hasSubmittedQuestion: Bool,
        hasAssistantContent: Bool
    ) -> Self {
        if hasAssistantContent {
            return .answer
        }
        return requestLifecycle == nil && !hasSubmittedQuestion
            ? .initialSheet
            : .thinking
    }
}

enum CourseHermesRecoveryProgressState: String, Equatable {
    case submissionIntent = "submission-intent"
    case acceptedTurn = "accepted-turn"
    case toolLifecyclePending = "tool-lifecycle-pending"
    case toolExecuting = "tool-executing"
    case toolExecuted = "tool-executed"
    case resultSubmitting = "result-submitting"
    case resultSubmitted = "result-submitted"
}

enum CourseHermesRecoveryAction: Hashable {
    case retry
    case abandon
}

enum CourseHermesRecoveryInteractionState: Equatable {
    case active(CourseHermesRecoveryProgressState)
    case blocking

    var contributesActiveWork: Bool {
        if case .active = self { return true }
        return false
    }

    var blocksNewSubmission: Bool { true }
}

enum CourseHermesRecoveryProgressPolicy {
    static func progressState(
        for journalState: CourseHermesRecoveryProvenance.JournalState
    ) -> CourseHermesRecoveryProgressState? {
        switch journalState {
        case .submissionIntent:
            .submissionIntent
        case .acceptedTurn:
            .acceptedTurn
        case .toolLifecyclePending:
            .toolLifecyclePending
        case .toolExecuting:
            .toolExecuting
        case .toolExecuted:
            .toolExecuted
        case .resultSubmitting:
            .resultSubmitting
        case .resultSubmitted:
            .resultSubmitted
        case .terminalFailure, .unreadableEvidence:
            nil
        }
    }

    static func shouldShow(
        progressState: CourseHermesRecoveryProgressState?,
        hasDisplayedError: Bool,
        isStopping: Bool
    ) -> Bool {
        progressState != nil && !hasDisplayedError && !isStopping
    }

    static func interactionState(
        for journalState: CourseHermesRecoveryProvenance.JournalState
    ) -> CourseHermesRecoveryInteractionState {
        if let progressState = progressState(for: journalState) {
            return .active(progressState)
        }
        return .blocking
    }

    static func usesResolutionCopy(
        for journalState: CourseHermesRecoveryProvenance.JournalState,
        abandonMode: CourseHermesRecoveryAbandonMode = .chooseWorkspaceDisposition
    ) -> Bool {
        abandonMode != .finishDraftDeletion
            && interactionState(for: journalState) == .blocking
    }

    static func blockingErrorMessage(
        for journalState: CourseHermesRecoveryProvenance.JournalState,
        abandonMode: CourseHermesRecoveryAbandonMode = .chooseWorkspaceDisposition
    ) -> String? {
        if abandonMode == .finishDraftDeletion {
            return "Recovery evidence is already archived. Review what will be kept, then permanently delete the remaining draft workspace data before starting new messages."
        }
        return switch journalState {
        case .terminalFailure:
            "Hermes recovery could not finish. Your draft, course workspace, and recovery evidence are preserved. Resolve this recovery to continue with the preserved workspace."
        case .unreadableEvidence:
            "Hermes recovery evidence could not be read safely. Your draft and course workspace remain protected. Retry recovery or resolve it without losing the evidence."
        case .submissionIntent, .acceptedTurn, .toolLifecyclePending,
             .toolExecuting, .toolExecuted, .resultSubmitting, .resultSubmitted:
            nil
        }
    }

    static func availableActions(
        for journalState: CourseHermesRecoveryProvenance.JournalState
    ) -> Set<CourseHermesRecoveryAction> {
        switch journalState {
        case .terminalFailure:
            [.abandon]
        case .unreadableEvidence:
            [.retry, .abandon]
        case .submissionIntent, .acceptedTurn, .toolLifecyclePending,
             .toolExecuting, .toolExecuted, .resultSubmitting, .resultSubmitted:
            [.abandon]
        }
    }

    static func correlationLabel(
        for journalState: CourseHermesRecoveryProvenance.JournalState
    ) -> String {
        switch journalState {
        case .terminalFailure:
            "Correlation · Retained privately until recovery is abandoned"
        case .unreadableEvidence:
            "Correlation · Retained privately for retry or abandon"
        case .submissionIntent, .acceptedTurn, .toolLifecyclePending,
             .toolExecuting, .toolExecuted, .resultSubmitting, .resultSubmitted:
            "Correlation · Retained privately for safe retry"
        }
    }

    static func allowsErrorDismissal(hasRecoveryPresentation: Bool) -> Bool {
        !hasRecoveryPresentation
    }
}

enum CourseChatTimelinePolicy {
    static func projectLiveItems(
        _ items: [ConversationItem],
        hidesSelectionEnvelope: Bool = false
    ) -> [ConversationItem] {
        let internalTurnIDs = Set(items.compactMap { item -> String? in
            guard isInternalCourseActionUserItem(item) else { return nil }
            return item.sourceTurnId
        })
        let internalTurnIndices = Set(items.compactMap { item -> Int? in
            guard isInternalCourseActionUserItem(item) else { return nil }
            return item.sourceTurnIndex
        })
        var suppressesUnscopedInternalTurn = false
        var projected: [ConversationItem] = []
        projected.reserveCapacity(items.count)
        for item in items {
            if isInternalCourseActionUserItem(item) {
                // Hydration and streaming can disagree about whether later
                // items carry turn metadata. Treat every internal learner
                // instruction as a whole-turn boundary until the next genuine
                // learner message, even when this boundary itself has an ID.
                suppressesUnscopedInternalTurn = true
                continue
            }
            if item.sourceTurnId.map(internalTurnIDs.contains) == true
                || item.sourceTurnIndex.map(internalTurnIndices.contains) == true {
                continue
            }
            if suppressesUnscopedInternalTurn {
                if case .user(let data) = item.content,
                   !isRemoteCourseToolResultEnvelope(data.text) {
                    suppressesUnscopedInternalTurn = false
                } else {
                    continue
                }
            }
            if let item = projectLiveItem(
                item,
                hidesSelectionEnvelope: hidesSelectionEnvelope
            ) {
                projected.append(item)
            }
        }
        return projected
    }

    private static func isInternalCourseActionUserItem(_ item: ConversationItem) -> Bool {
        guard case .user(let data) = item.content else { return false }
        let learnerText = remoteLearnerMessage(from: data.text) ?? data.text
        return CourseAgentInternalPromptPolicy.isInternalInstruction(learnerText)
    }

    static func isAgentWorking(
        requestPending: Bool,
        threadHasActiveTurn: Bool,
        usesDurableHermesLifecycle: Bool = false,
        durableHermesRecoveryPending: Bool = false,
        durableHermesRecoveryBlocksActivity: Bool = false
    ) -> Bool {
        if usesDurableHermesLifecycle {
            if durableHermesRecoveryBlocksActivity { return false }
            return requestPending || durableHermesRecoveryPending
        }
        return requestPending || threadHasActiveTurn
    }

    static func mergedConversationItems(
        localMessages: [CourseChatMessage],
        liveItems: [ConversationItem]
    ) -> [ConversationItem] {
        let localItems = CourseChatTranscriptPolicy.learnerVisibleMessages(localMessages)
            .map(localConversationItem)
        guard !localItems.isEmpty else { return liveItems }
        guard !liveItems.isEmpty else { return localItems }

        var matches: [(local: Int, live: Int)] = []
        var liveCursor = 0
        for localIndex in localItems.indices {
            guard let localSignature = messageSignature(for: localItems[localIndex]) else {
                continue
            }
            guard let liveIndex = liveItems.indices.dropFirst(liveCursor).first(where: {
                guard let liveSignature = messageSignature(for: liveItems[$0]) else {
                    return false
                }
                return localSignature.matches(liveSignature)
            }) else {
                continue
            }
            matches.append((localIndex, liveIndex))
            liveCursor = liveIndex + 1
        }

        var merged: [ConversationItem] = []
        var localCursor = 0
        liveCursor = 0
        for match in matches {
            merged.append(contentsOf: localItems[localCursor..<match.local])
            merged.append(contentsOf: liveItems[liveCursor..<match.live])
            merged.append(liveItems[match.live].replacingID(with: localItems[match.local].id))
            localCursor = match.local + 1
            liveCursor = match.live + 1
        }
        // The remaining live tail is canonical history that predates any
        // unmatched local suffix. Appending the optimistic suffix first can
        // move a historical assistant reply after a newly submitted learner
        // message and falsely present that new request as streaming.
        merged.append(contentsOf: liveItems[liveCursor...])
        merged.append(contentsOf: localItems[localCursor...])
        return merged
    }

    static func hasAssistantContentAfterLatestLearner(
        in items: [ConversationItem]
    ) -> Bool {
        guard let latestLearnerIndex = items.lastIndex(where: { item in
            if case .user = item.content { return true }
            return false
        }) else { return false }

        return items[items.index(after: latestLearnerIndex)...]
            .contains(where: { item in
                guard case .assistant(let data) = item.content else {
                    return false
                }
                return !data.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            })
    }

    private struct MessageSignature {
        enum Role {
            case learner
            case agent
        }

        let role: Role
        let text: String

        func matches(_ other: MessageSignature) -> Bool {
            guard role == other.role else { return false }
            if text == other.text { return true }
            guard role == .agent, !text.isEmpty, !other.text.isEmpty else { return false }
            return text.hasPrefix(other.text) || other.text.hasPrefix(text)
        }
    }

    private static func messageSignature(for item: ConversationItem) -> MessageSignature? {
        switch item.content {
        case .user(let data):
            MessageSignature(role: .learner, text: normalizedMessageText(data.text))
        case .assistant(let data):
            MessageSignature(role: .agent, text: normalizedMessageText(data.text))
        default:
            nil
        }
    }

    private static func normalizedMessageText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func localConversationItem(_ message: CourseChatMessage) -> ConversationItem {
        let content: ConversationItemContent
        switch message.role {
        case .learner:
            let images = message.sources.compactMap(\.image)
                .compactMap(ConversationAttachmentSupport.prepareImage)
                .map(\.chatImage)
            content = .user(
                ConversationUserMessageData(text: message.text, images: images)
            )
        case .agent:
            content = .assistant(
                ConversationAssistantMessageData(
                    text: message.text,
                    agentNickname: nil,
                    agentRole: nil,
                    phase: nil
                )
            )
        }
        return ConversationItem(
            id: "course-local-\(message.id.uuidString.lowercased())",
            content: content,
            timestamp: message.createdAt,
            isFromUserTurnBoundary: message.role == .learner
        )
    }

    private static func projectLiveItem(
        _ item: ConversationItem,
        hidesSelectionEnvelope: Bool
    ) -> ConversationItem? {
        switch item.content {
        case .mcpToolCall(let data) where isInternalCourseServer(data.server):
            return data.status == .failed
                ? learnerFacingFailure(for: item, tool: data.tool)
                : nil
        case .dynamicToolCall(let data) where isInternalCourseDynamicTool(data):
            return data.status == .failed
                ? learnerFacingFailure(for: item, tool: data.tool)
                : nil
        case .assistant(let data) where isRemoteCourseToolEnvelope(data.text):
            return nil
        case .user(let data):
            if isRemoteCourseToolResultEnvelope(data.text) {
                return nil
            }
            let projectedText: String?
            if let learnerMessage = remoteLearnerMessage(from: data.text) {
                projectedText = learnerMessage
            } else if hidesSelectionEnvelope {
                projectedText = selectionQuestion(from: data.text)
            } else {
                projectedText = nil
            }
            let learnerText = projectedText ?? data.text
            guard !CourseAgentInternalPromptPolicy.isInternalInstruction(learnerText) else {
                return nil
            }
            guard let projectedText else { return item }
            return ConversationItem(
                id: item.id,
                content: .user(
                    ConversationUserMessageData(text: projectedText, images: data.images)
                ),
                sourceTurnId: item.sourceTurnId,
                sourceTurnIndex: item.sourceTurnIndex,
                timestamp: item.timestamp,
                isFromUserTurnBoundary: item.isFromUserTurnBoundary
            )
        default:
            return item
        }
    }

    static func selectionQuestion(from prompt: String) -> String? {
        guard prompt.contains("<selected_course_passage"),
              let marker = prompt.range(of: "\nMy question: ") else { return nil }
        let question = prompt[marker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? nil : question
    }

    static func remoteLearnerMessage(from prompt: String) -> String? {
        guard prompt.contains("Learnfold remote native-tool protocol:"),
              let marker = prompt.range(of: "\n\nLearner message:\n") else {
            return nil
        }
        let message = prompt[marker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    private static func isRemoteCourseToolEnvelope(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{")
            && trimmed.contains(#""learnfold_tool_call""#)
    }

    private static func isRemoteCourseToolResultEnvelope(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{")
            && trimmed.contains(#""learnfold_tool_result""#)
    }

    private static func isInternalCourseServer(_ server: String) -> Bool {
        server == CourseAgentTools.mcpServerName ||
            server == CourseAgentTools.mcpDirectNamespace
    }

    private static func isInternalCourseDynamicTool(
        _ data: ConversationDynamicToolCallData
    ) -> Bool {
        if data.tool == CourseAgentTools.presentPlan ||
            CourseAgentTools.isEditorTool(data.tool) {
            return true
        }

        if let namespace = data.namespace,
           namespace == CourseAgentTools.mcpServerName ||
               namespace == CourseAgentTools.mcpDirectNamespace {
            return true
        }

        return data.tool.hasPrefix("\(CourseAgentTools.mcpDirectNamespace)__")
    }

    private static func learnerFacingFailure(
        for item: ConversationItem,
        tool: String
    ) -> ConversationItem {
        let message = tool == CourseAgentTools.presentPlan
            ? "The course plan couldn’t be prepared. Please try again."
            : "The course couldn’t be updated. Please try again."

        return ConversationItem(
            id: item.id,
            content: .error(
                ConversationSystemErrorData(
                    title: "Course action failed",
                    message: message,
                    details: nil
                )
            ),
            sourceTurnId: item.sourceTurnId,
            sourceTurnIndex: item.sourceTurnIndex,
            timestamp: item.timestamp,
            isFromUserTurnBoundary: item.isFromUserTurnBoundary
        )
    }
}

private extension ConversationItem {
    func replacingID(with id: String) -> ConversationItem {
        ConversationItem(
            id: id,
            content: content,
            sourceTurnId: sourceTurnId,
            sourceTurnIndex: sourceTurnIndex,
            timestamp: timestamp,
            isFromUserTurnBoundary: isFromUserTurnBoundary
        )
    }
}

enum CourseChatScrollPolicy {
    static let nearBottomDistance: CGFloat = 12

    static func shouldFollow(
        autoFollowEnabled: Bool,
        userIsDragging: Bool
    ) -> Bool {
        autoFollowEnabled && !userIsDragging
    }

    static func updatedAutoFollow(
        currentValue: Bool,
        distanceFromBottom: CGFloat,
        userIsDragging: Bool,
        isAgentWorking: Bool
    ) -> Bool {
        if distanceFromBottom <= nearBottomDistance {
            return true
        }
        if userIsDragging && isAgentWorking {
            return false
        }
        return currentValue
    }
}

enum CourseChatAuthPolicy {
    static func needsSignIn(
        isCodex: Bool,
        requiresOpenAIAuth: Bool,
        hasAccount: Bool,
        explicitlyRequired: Bool,
        hasOwnedReadinessError: Bool = false
    ) -> Bool {
        guard !hasOwnedReadinessError else { return false }
        return isCodex && (explicitlyRequired || (requiresOpenAIAuth && !hasAccount))
    }

    static func isReady(
        isCodex: Bool,
        transportConnected: Bool,
        runtimeAvailable: Bool,
        requiresOpenAIAuth: Bool,
        hasAccount: Bool
    ) -> Bool {
        guard transportConnected, runtimeAvailable else { return false }
        return !isCodex || !requiresOpenAIAuth || hasAccount
    }
}

enum CourseAgentErrorBlockingAction: Equatable {
    case none
    case recovery(allowsRetry: Bool)
    case missingThread
}

enum CourseAgentErrorActionPolicy {
    static func blockingAction(
        recoveryActions: Set<CourseHermesRecoveryAction>,
        hasMissingBoundThread: Bool,
        abandonMode: CourseHermesRecoveryAbandonMode = .chooseWorkspaceDisposition
    ) -> CourseAgentErrorBlockingAction {
        if abandonMode == .finishDraftDeletion {
            return .recovery(allowsRetry: false)
        }
        if !recoveryActions.isEmpty {
            return .recovery(
                allowsRetry: recoveryActions.contains(.retry)
                    && !hasMissingBoundThread
            )
        }
        return hasMissingBoundThread ? .missingThread : .none
    }

    static func showsReconnect(
        agentID: String,
        hasOwnedReadinessError: Bool,
        needsAuthentication: Bool
    ) -> Bool {
        hasOwnedReadinessError && !needsAuthentication && CourseAgentProvider.usesAppServer(agentID)
    }
}

enum CourseAgentReconnectPolicy {
    enum Action: Equatable {
        case reconnectServer(String)
        case connectAgent
    }

    static func action(
        effectiveTargetServerID: String?,
        localServerID: String?
    ) -> Action {
        if let serverID = effectiveTargetServerID ?? localServerID {
            return .reconnectServer(serverID)
        }
        return .connectAgent
    }
}

enum CourseSourceAttachmentErrorKind: String, Equatable {
    case permission = "permission-error"
    case parse = "parse-error"
    case preparation = "preparation-error"

    var userMessage: String {
        switch self {
        case .permission:
            "Learnfold couldn’t access that source. Choose it again and allow access."
        case .parse:
            "That source could not be parsed. Choose a supported file or a valid http or https link."
        case .preparation:
            "The selected source could not be prepared. Nothing was added; try again."
        }
    }
}

struct CourseSourceAttachmentErrorPresentation: Equatable {
    let kind: CourseSourceAttachmentErrorKind

    var message: String { kind.userMessage }

    init(kind: CourseSourceAttachmentErrorKind) {
        self.kind = kind
    }

    init(
        error: Error,
        fallbackKind: CourseSourceAttachmentErrorKind = .preparation
    ) {
        kind = Self.kind(for: error, fallback: fallbackKind)
    }

    private static func kind(
        for error: Error,
        fallback: CourseSourceAttachmentErrorKind
    ) -> CourseSourceAttachmentErrorKind {
        if let sourceError = error as? CourseSourceIngestionError {
            switch sourceError {
            case .invalidURL, .unsupportedDocument, .unreadableDocument, .emptyPDF:
                return .parse
            case .blockedURL, .badHTTPStatus, .responseTooLarge, .tooManySources,
                 .storageLimitExceeded, .setupFailed:
                return fallback
            }
        }

        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain {
            switch cocoaError.code {
            case CocoaError.Code.fileReadNoPermission.rawValue,
                 CocoaError.Code.fileWriteNoPermission.rawValue:
                return .permission
            case CocoaError.Code.fileReadCorruptFile.rawValue:
                return .parse
            default:
                break
            }
        }
        if cocoaError.domain == NSPOSIXErrorDomain {
            switch cocoaError.code {
            case Int(POSIXErrorCode.EACCES.rawValue),
                 Int(POSIXErrorCode.EPERM.rawValue):
                return .permission
            default:
                break
            }
        }
        return fallback
    }
}

private struct CourseSourceAttachmentErrorAlertModifier: ViewModifier {
    @Binding var error: CourseSourceAttachmentErrorPresentation?

    func body(content: Content) -> some View {
        content.alert(
            "Couldn’t Add Source",
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )
        ) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error?.message ?? "Unknown error")
                .accessibilityIdentifier("course-source-attachment-error")
                .accessibilityLabel(error?.message ?? "Unknown error")
                .accessibilityValue(
                    error?.kind.rawValue
                        ?? CourseSourceAttachmentErrorKind.preparation.rawValue
                )
        }
    }
}

private extension View {
    func courseSourceAttachmentErrorAlert(
        error: Binding<CourseSourceAttachmentErrorPresentation?>
    ) -> some View {
        modifier(
            CourseSourceAttachmentErrorAlertModifier(
                error: error
            )
        )
    }
}

struct CourseChatView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CourseExperienceStore
    let selectionContext: CourseTextReference?
    let selectionDiscussionID: UUID?
    let showsDismissButton: Bool
    let onSelectionDiscussionReplaced: (CourseSelectionDiscussion) -> Void
    @State private var inputText = ""
    @State private var sources: [CourseSource] = []
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsFileImporter = false
    @State private var attachmentError: CourseSourceAttachmentErrorPresentation?
    @State private var hasSentSelectionContext = false
    @State private var isNearBottom = true
    @State private var autoFollowStreaming = true
    @State private var userIsDraggingScroll = false
    @State private var followScrollScheduled = false
    @State private var isResolvingDiscussion = false
    @State private var resolveError: String?
    @State private var isReconnectingAgent = false
    @State private var draftWorkspaceID: String?
    @FocusState private var composerFocused: Bool

    init(
        store: CourseExperienceStore,
        selectionContext: CourseTextReference? = nil,
        selectionDiscussionID: UUID? = nil,
        showsDismissButton: Bool = false,
        onSelectionDiscussionReplaced: @escaping (CourseSelectionDiscussion) -> Void = { _ in }
    ) {
        self.store = store
        self.selectionContext = selectionContext
        self.selectionDiscussionID = selectionDiscussionID
        self.showsDismissButton = showsDismissButton
        self.onSelectionDiscussionReplaced = onSelectionDiscussionReplaced
        _draftWorkspaceID = State(
            initialValue: store.draftWorkspaceID(for: selectionDiscussionID)
        )
    }

    private var activeThreadKey: ThreadKey? {
        if let selectionDiscussionID {
            return store.selectionDiscussionThreadKey(id: selectionDiscussionID)
        }
        return store.agentThreadKey
    }

    private var liveThread: AppThreadSnapshot? {
        guard let key = activeThreadKey else { return nil }
        return appModel.threadSnapshot(for: key)
    }

    private var liveConversationItems: [ConversationItem] {
        CourseChatTimelinePolicy.projectLiveItems(
            liveThread?.hydratedConversationItems.map(\.conversationItem) ?? [],
            hidesSelectionEnvelope: selectionDiscussionID != nil
        )
    }

    private var localMessages: [CourseChatMessage] {
        store.localMessages(for: selectionDiscussionID)
    }

    private var remoteTimelineItems: [ConversationItem] {
        CourseChatTimelinePolicy.mergedConversationItems(
            localMessages: localMessages,
            liveItems: liveConversationItems
        )
    }

    private var localStreamingTextLength: Int {
        localMessages.last(where: { $0.role == .agent })?.text.utf16.count ?? 0
    }

    private var isPreparingSelectionDiscussion: Bool {
        selectionDiscussionID.map {
            store.preparingSelectionDiscussionIDs.contains($0)
        } ?? false
    }

    private var displayedAgentError: String? {
        if displayedAgentID == "hermes",
           let recoveryPresentation = store.hermesRecoveryPresentation(
               selectionDiscussionID: selectionDiscussionID
           ) {
            // Durable recovery state is authoritative. In particular, an
            // active journal must not be presented as a stale generic failure
            // with a Retry action while recovery is already running.
            return CourseHermesRecoveryProgressPolicy.blockingErrorMessage(
                for: recoveryPresentation.provenance.journalState,
                abandonMode: recoveryPresentation.abandonMode
            )
        }
        if let selectionDiscussionID {
            if let error = store.selectionDiscussionErrors[selectionDiscussionID] {
                return error
            }
        } else if let error = store.agentError {
            return error
        }
        return nil
    }

    private var displayedAgentID: String {
        store.selectionDiscussionAgentID(id: selectionDiscussionID)
    }

    private var displayedConnectionState: CourseExperienceStore.AgentConnectionState {
        store.connectionState(for: selectionDiscussionID)
    }

    private var displayedSources: [CourseSource] {
        store.sources(for: selectionDiscussionID)
    }

    private var displayedSubmissionRecoveryState: CourseAgentSubmissionRecoveryState? {
        store.submissionRecoveryState(for: selectionDiscussionID)
    }

    private var restoredDraftText: String? {
        if let selectionDiscussionID {
            return store.selectionDiscussionDrafts[selectionDiscussionID]
        }
        return store.courseChatDraft
    }

    private var isPreparingDisplayedSource: Bool {
        store.isPreparingSource(for: selectionDiscussionID)
    }

    private var isAgentWorking: Bool {
        let usesDurableHermesLifecycle = displayedAgentID == "hermes"
        let recoveryInteractionState = displayedHermesRecoveryInteractionState
        return CourseChatTimelinePolicy.isAgentWorking(
            requestPending: store.isAgentRequestPending(for: selectionDiscussionID),
            threadHasActiveTurn: liveThread?.hasActiveTurn == true,
            usesDurableHermesLifecycle: usesDurableHermesLifecycle,
            durableHermesRecoveryPending: usesDurableHermesLifecycle
                && recoveryInteractionState?.contributesActiveWork == true,
            durableHermesRecoveryBlocksActivity: usesDurableHermesLifecycle
                && recoveryInteractionState == .blocking
        )
    }

    private var isStoppingAgent: Bool {
        displayedHermesRecoveryInteractionState != .blocking
            && store.agentRunPhase(for: selectionDiscussionID) == .stopping
    }

    private var displayedHermesRecoveryPresentation: CourseHermesRecoveryPresentation? {
        guard displayedAgentID == "hermes" else { return nil }
        return store.hermesRecoveryPresentation(
            selectionDiscussionID: selectionDiscussionID
        )
    }

    private var displayedHermesRecoveryInteractionState:
        CourseHermesRecoveryInteractionState? {
        displayedHermesRecoveryPresentation.map {
            CourseHermesRecoveryProgressPolicy.interactionState(
                for: $0.provenance.journalState
            )
        }
    }

    private var blocksNewSubmissionForHermesRecovery: Bool {
        displayedHermesRecoveryInteractionState?.blocksNewSubmission == true
    }

    private var hasAssistantContentForCurrentRequest: Bool {
        CourseChatTimelinePolicy.hasAssistantContentAfterLatestLearner(
            in: remoteTimelineItems
        )
    }

    private var requestLifecycle: CourseRequestLifecycle? {
        guard displayedHermesRecoveryInteractionState != .blocking else {
            return nil
        }
        return CourseRequestLifecycle.project(
            runPhase: store.agentRunPhase(for: selectionDiscussionID),
            isAgentWorking: isAgentWorking,
            hasAssistantContent: hasAssistantContentForCurrentRequest,
            isReconnecting: isReconnectingAgent
        )
    }

    private var focusedQAState: CourseFocusedQAState {
        CourseFocusedQAState.project(
            requestLifecycle: requestLifecycle,
            hasSubmittedQuestion: hasSentSelectionContext || selectionDiscussionID.map {
                store.selectionDiscussionHasSubmittedQuestion(id: $0)
            } == true,
            hasAssistantContent: hasAssistantContentForCurrentRequest
        )
    }

    private var courseServer: AppServerSnapshot? {
        if let selectionDiscussionID {
            if let serverID = activeThreadKey?.serverId
                ?? store.selectionDiscussion(id: selectionDiscussionID)?.serverID {
                return appModel.snapshot?.serverSnapshot(for: serverID)
            }
        } else if let serverID = store.effectiveMainCourseServerID() {
            // Returning nil when the configured target is absent is
            // intentional: a connected local Codex server must not make a
            // selected remote Hermes course appear ready.
            return appModel.snapshot?.serverSnapshot(for: serverID)
        }
        return appModel.snapshot?.servers.first(where: \.isLocal)
    }

    private var codexNeedsSignIn: Bool {
        CourseChatAuthPolicy.needsSignIn(
            isCodex: displayedAgentID == .codex,
            requiresOpenAIAuth: courseServer?.requiresOpenaiAuth == true,
            hasAccount: courseServer?.account != nil,
            explicitlyRequired: store.agentNeedsAuthentication(for: selectionDiscussionID),
            hasOwnedReadinessError: store.isDisplayingOwnedReadinessError(
                for: selectionDiscussionID
            )
        )
    }

    private var isAgentReady: Bool {
        if CourseAgentProvider.usesLocalMessages(displayedAgentID) {
            return displayedConnectionState == .connected
        }
        return CourseChatAuthPolicy.isReady(
            isCodex: displayedAgentID == .codex,
            transportConnected: courseServer?.isConnected == true,
            runtimeAvailable: courseServer?.agentRuntimes.contains(where: {
                $0.kind == displayedAgentID && $0.available
            }) == true,
            requiresOpenAIAuth: courseServer?.requiresOpenaiAuth == true,
            hasAccount: courseServer?.account != nil
        )
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if let selectionContext {
                            CourseSelectionContextCard(
                                reference: selectionContext,
                                agentName: displayedAgentID.displayLabel,
                                focusedQAState: focusedQAState
                            )
                        } else {
                            CourseChatIntro(
                                agentID: displayedAgentID,
                                supportsBinarySources: CourseAgentProvider.supportsBinarySources(
                                    displayedAgentID
                                )
                            )
                        }

                        if isPreparingSelectionDiscussion {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Starting a focused discussion…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Starting a focused discussion")
                        }

                        if CourseAgentProvider.usesLocalMessages(displayedAgentID) {
                            ForEach(localMessages) { message in
                                CourseMessageRow(
                                    message: message,
                                    agentID: displayedAgentID
                                )
                                    .id(message.id)
                            }
                        } else if !remoteTimelineItems.isEmpty || liveThread != nil {
                            ConversationTurnTimeline(
                                items: remoteTimelineItems,
                                isLive: liveThread?.hasActiveTurn == true,
                                serverId: liveThread?.key.serverId ?? activeThreadKey?.serverId ?? "",
                                originThreadId: liveThread?.key.threadId ?? activeThreadKey?.threadId,
                                agentDirectoryVersion: appModel.snapshot?.agentDirectoryVersion ?? 0,
                                messageActionsDisabled: true,
                                onStreamingSnapshotRendered: {
                                    requestFollowScrollAfterLayout(proxy)
                                },
                                onLiveContentLayoutChanged: {
                                    requestFollowScrollAfterLayout(proxy)
                                },
                                resolveTargetLabel: { target in
                                    appModel.snapshot?.resolvedAgentTargetLabel(
                                        for: target,
                                        serverId: liveThread?.key.serverId ?? activeThreadKey?.serverId ?? ""
                                    )
                                },
                                onWidgetPrompt: { prompt in
                                    inputText = prompt
                                    composerFocused = true
                                },
                                onEditUserItem: { _ in },
                                onForkFromUserItem: { _ in }
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("course-live-timeline")
                        }

                        if isAgentWorking && displayedAgentError == nil {
                            Group {
                                if let recoveryPresentation = displayedHermesRecoveryPresentation,
                                   let progressState =
                                       CourseHermesRecoveryProgressPolicy.progressState(
                                           for: recoveryPresentation.provenance.journalState
                                       ),
                                   CourseHermesRecoveryProgressPolicy.shouldShow(
                                       progressState: progressState,
                                       hasDisplayedError: false,
                                       isStopping: isStoppingAgent
                                   ) {
                                    CourseHermesRecoveryProgressView(
                                        agentID: displayedAgentID,
                                        provenance: recoveryPresentation.provenance,
                                        progressState: progressState,
                                        allowsWorkspaceDeletion:
                                            store.canDeletePendingHermesDraft(
                                                selectionDiscussionID:
                                                    selectionDiscussionID
                                            ),
                                        onStopRecovery: stopHermesRecovery
                                    )
                                } else {
                                    HStack(alignment: .center, spacing: 8) {
                                        AgentIconView(kind: displayedAgentID, size: 27)
                                        if isStoppingAgent {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Stopping…")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            TypingIndicator()
                                        }
                                        Spacer()
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel(
                                        isStoppingAgent
                                            ? "Stopping \(displayedAgentID.displayLabel)"
                                            : "\(displayedAgentID.displayLabel) is thinking"
                                    )
                                }
                            }
                            .id("course-agent-working")
                        }

                        if store.showsBrief {
                            CourseBriefCard(
                                brief: store.brief,
                                agentName: displayedAgentID.displayLabel,
                                isAgentWorking: isAgentWorking,
                                isApprovalEnabled: displayedSubmissionRecoveryState == nil
                                    && !blocksNewSubmissionForHermesRecovery,
                                buildAction: {
                                    store.approveCoursePlan(appModel: appModel, appState: appState)
                                }
                            )
                                .id("course-brief")
                        }

                        if let agentError = displayedAgentError {
                            let recoveryPresentation =
                                store.hermesRecoveryPresentation(
                                    selectionDiscussionID: selectionDiscussionID
                                )
                            let recoveryActions = recoveryPresentation.map {
                                CourseHermesRecoveryProgressPolicy.availableActions(
                                    for: $0.provenance.journalState
                                )
                            } ?? []
                            let blockingAction = CourseAgentErrorActionPolicy.blockingAction(
                                recoveryActions: recoveryActions,
                                hasMissingBoundThread:
                                    store.selectionDiscussionHasMissingBoundThread(
                                        id: selectionDiscussionID
                                    ),
                                abandonMode: recoveryPresentation?.abandonMode
                                    ?? .chooseWorkspaceDisposition
                            )
                            CourseAgentErrorCard(
                                agentName: displayedAgentID.displayLabel,
                                message: agentError,
                                needsAuthentication: codexNeedsSignIn,
                                isConnecting: displayedConnectionState == .connecting || isReconnectingAgent,
                                showsReconnectAction: CourseAgentErrorActionPolicy.showsReconnect(
                                    agentID: displayedAgentID,
                                    hasOwnedReadinessError: store.isDisplayingOwnedReadinessError(
                                        for: selectionDiscussionID
                                    ),
                                    needsAuthentication: codexNeedsSignIn
                                ),
                                blockingAction: blockingAction,
                                abandonMode: recoveryPresentation?.abandonMode
                                    ?? .chooseWorkspaceDisposition,
                                allowsWorkspaceDeletion: store.canDeletePendingHermesDraft(
                                    selectionDiscussionID: selectionDiscussionID
                                ),
                                allowsUnknownSubmissionAbandon: store.canAbandonUnconfirmedSubmission(
                                    selectionDiscussionID: selectionDiscussionID
                                ),
                                submissionRecoveryState: displayedSubmissionRecoveryState,
                                hermesRecoveryProvenance: recoveryPresentation?.provenance,
                                onReconnect: reconnectAgent,
                                onRetrySubmission: retryCurrentSubmission,
                                onCheckStatus: checkSubmissionStatus,
                                onDiscardSubmission: discardRecoveredSubmission,
                                onAbandonUnknownSubmission: abandonUnconfirmedSubmission,
                                onRetryRecovery: {
                                    Task {
                                        await store.retryPendingHermesRecovery(
                                            selectionDiscussionID: selectionDiscussionID,
                                            appModel: appModel,
                                            appState: appState
                                        )
                                    }
                                },
                                onAbandonRecovery: stopHermesRecovery,
                                onStartNewDiscussion: {
                                    guard let selectionDiscussionID else { return }
                                    store.saveDraft(
                                        inputText,
                                        for: selectionDiscussionID,
                                        expectedWorkspaceID: draftWorkspaceID
                                    )
                                    Task {
                                        do {
                                            let replacement = try await store.replaceMissingSelectionDiscussion(
                                                id: selectionDiscussionID,
                                                appModel: appModel
                                            )
                                            onSelectionDiscussionReplaced(replacement)
                                        } catch {
                                            let replacementErrorMessage = error.localizedDescription
                                            store.selectionDiscussionErrors[selectionDiscussionID] =
                                                replacementErrorMessage
                                        }
                                    }
                                },
                                onDismiss: dismissDisplayedError,
                                allowsDismissal:
                                    CourseHermesRecoveryProgressPolicy.allowsErrorDismissal(
                                        hasRecoveryPresentation: recoveryPresentation != nil
                                    )
                            )
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("course-chat-bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 22)
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
                } action: { _, distance in
                    updateDistanceFromBottom(distance)
                }
                .onScrollPhaseChange { _, newPhase in
                    switch newPhase {
                    case .tracking, .interacting:
                        userIsDraggingScroll = true
                        if isAgentWorking {
                            autoFollowStreaming = false
                        }
                    case .decelerating:
                        userIsDraggingScroll = true
                    default:
                        userIsDraggingScroll = false
                        if isNearBottom {
                            autoFollowStreaming = true
                        }
                    }
                }
                .onChange(of: localMessages.count) { _, _ in
                    guard CourseAgentProvider.usesLocalMessages(displayedAgentID) else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        if store.showsBrief {
                            proxy.scrollTo("course-brief", anchor: .bottom)
                        } else if let last = localMessages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: remoteTimelineItems.count) { _, _ in
                    guard CourseAgentProvider.usesAppServer(displayedAgentID) else { return }
                    requestFollowScrollAfterLayout(proxy)
                }
                .onChange(of: localStreamingTextLength) { _, _ in
                    guard CourseAgentProvider.usesLocalMessages(displayedAgentID),
                          isAgentWorking else { return }
                    requestFollowScrollAfterLayout(proxy)
                }
                .onChange(of: store.showsBrief) { _, isShown in
                    guard isShown,
                          CourseChatScrollPolicy.shouldFollow(
                              autoFollowEnabled: autoFollowStreaming,
                              userIsDragging: userIsDraggingScroll
                          ) else { return }
                    withAnimation(.easeOut(duration: 0.35)) {
                        proxy.scrollTo("course-brief", anchor: .top)
                    }
                }
                .onChange(of: isAgentWorking) { wasWorking, working in
                    if wasWorking || working {
                        requestFollowScrollAfterLayout(proxy)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-request-lifecycle")
        .accessibilityValue(requestLifecycle?.rawValue ?? "")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            courseChatComposerInset
        }
        .litterFontFamily(.system)
        // Course surfaces use native Dynamic Type. The classic conversation
        // zoom is a separate preference and otherwise makes this screen's
        // messages larger than its surrounding controls and guidance.
        .environment(\.textScale, 1.0)
        .navigationTitle(selectionContext == nil ? (store.generatedCourseID == nil ? "New Course" : "Course Agent") : "Ask about this passage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let draft = store.takeDraft(for: selectionDiscussionID) {
                inputText = draft
            }
            hasSentSelectionContext =
                selectionDiscussionID.map {
                    store.selectionDiscussionHasSubmittedQuestion(id: $0)
                } ?? false
        }
        .onDisappear {
            store.saveDraft(
                inputText,
                for: selectionDiscussionID,
                expectedWorkspaceID: draftWorkspaceID
            )
        }
        .onChange(of: store.lastAcceptedSelectionContextID) { _, acceptedID in
            if acceptedID == selectionContext?.id {
                hasSentSelectionContext = true
            }
        }
        .onChange(of: restoredDraftText) { _, restoredDraft in
            guard let restoredDraft,
                  !restoredDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  restoredDraft != inputText else { return }
            inputText = restoredDraft
        }
        .onChange(of: inputText) { _, draft in
            store.saveDraft(
                draft,
                for: selectionDiscussionID,
                expectedWorkspaceID: draftWorkspaceID
            )
        }
        .task {
            if let selectionDiscussionID {
                await store.refreshSelectionDiscussionReadiness(
                    id: selectionDiscussionID,
                    appModel: appModel
                )
                await store.prepareSelectionDiscussionThread(
                    id: selectionDiscussionID,
                    appModel: appModel,
                    appState: appState
                )
                hasSentSelectionContext =
                    store.selectionDiscussionHasSubmittedQuestion(
                        id: selectionDiscussionID
                    )
            } else {
                await store.refreshAgentReadiness(appModel: appModel)
                await store.hydrateCourseThread(appModel: appModel, appState: appState)
            }
        }
        .toolbar {
            if showsDismissButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 6) {
                    if selectionDiscussionID != nil {
                        Button("Resolve") {
                            resolveDiscussion()
                        }
                        .font(.subheadline.weight(.semibold))
                        .disabled(
                            isResolvingDiscussion ||
                                isPreparingSelectionDiscussion ||
                                isAgentWorking ||
                                blocksNewSubmissionForHermesRecovery
                        )
                        .accessibilityIdentifier("course-chat-resolve")
                    }
                    if selectionDiscussionID == nil,
                       CourseAgentProvider.isApple(displayedAgentID) {
                        Menu {
                            Button {
                                store.switchCurrentAppleProvider(
                                    to: CourseAgentProvider.applePrivateCloud
                                )
                            } label: {
                                Label(
                                    "Private Cloud Compute",
                                    systemImage: displayedAgentID == CourseAgentProvider.applePrivateCloud
                                        ? "checkmark.circle.fill"
                                        : "cloud"
                                )
                            }
                            .disabled(
                                !store.canSwitchCurrentThread(
                                    to: CourseAgentProvider.applePrivateCloud
                                )
                            )

                            Button {
                                store.switchCurrentAppleProvider(
                                    to: CourseAgentProvider.appleOnDevice
                                )
                            } label: {
                                Label(
                                    "On‑Device",
                                    systemImage: displayedAgentID == CourseAgentProvider.appleOnDevice
                                        ? "checkmark.circle.fill"
                                        : "iphone"
                                )
                            }
                            .disabled(
                                !store.canSwitchCurrentThread(
                                    to: CourseAgentProvider.appleOnDevice
                                )
                            )
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .disabled(isAgentWorking)
                        .accessibilityLabel("Switch Apple model")
                        .accessibilityIdentifier("course-chat-apple-provider-switch")
                    }
                    agentStatusControl
                }
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    do {
                        try await store.importDocumentSources(
                            urls,
                            selectionDiscussionID: selectionDiscussionID
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        attachmentError = CourseSourceAttachmentErrorPresentation(
                            error: error
                        )
                    }
                }
            case .failure(let error):
                attachmentError = CourseSourceAttachmentErrorPresentation(
                    error: error
                )
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                defer { selectedPhoto = nil }
                let data: Data
                do {
                    guard let loadedData = try await item.loadTransferable(type: Data.self) else {
                        attachmentError = CourseSourceAttachmentErrorPresentation(
                            kind: .parse
                        )
                        return
                    }
                    data = loadedData
                } catch is CancellationError {
                    return
                } catch {
                    attachmentError = CourseSourceAttachmentErrorPresentation(
                        error: error,
                        fallbackKind: .parse
                    )
                    return
                }
                do {
                    try await store.importImageSource(
                        data: data,
                        selectionDiscussionID: selectionDiscussionID
                    )
                } catch is CancellationError {
                    return
                } catch {
                    attachmentError = CourseSourceAttachmentErrorPresentation(
                        error: error
                    )
                }
            }
        }
        .courseSourceAttachmentErrorAlert(error: $attachmentError)
        .alert("Couldn’t Resolve Discussion", isPresented: Binding(
            get: { resolveError != nil },
            set: { if !$0 { resolveError = nil } }
        )) {
            Button("OK", role: .cancel) { resolveError = nil }
        } message: {
            Text(resolveError ?? "The discussion is still open.")
        }
    }

    @ViewBuilder
    private var courseChatComposerInset: some View {
        VStack(spacing: 0) {
            if displayedAgentError == nil,
               !isAgentWorking,
               let recoveryState = displayedSubmissionRecoveryState {
                CourseSubmissionRecoveryStrip(
                    state: recoveryState,
                    allowsUnknownSubmissionAbandon: store.canAbandonUnconfirmedSubmission(
                        selectionDiscussionID: selectionDiscussionID
                    ),
                    onCheckStatus: checkSubmissionStatus,
                    onDiscardDraft: discardRecoveredSubmission,
                    onAbandonUnknownSubmission: abandonUnconfirmedSubmission
                )
            }
            CourseChatComposer(
                inputText: $inputText,
                prompt: selectionDiscussionID == nil
                    ? "Message your course agent"
                    : "Ask a question",
                sources: displayedSources,
                isFocused: $composerFocused,
                onRemoveSource: { store.removeSource($0, for: selectionDiscussionID) },
                onSend: sendCurrentMessage,
                isAgentWorking: isAgentWorking,
                isPreparing: isPreparingSelectionDiscussion || isPreparingDisplayedSource,
                preparationLabel: isPreparingSelectionDiscussion
                    ? "Starting focused discussion…"
                    : "Preparing source…",
                isEditingEnabled: displayedSubmissionRecoveryState?.blocksNewSubmission != true,
                isAgentReady: isAgentReady
                    && displayedSubmissionRecoveryState?.blocksNewSubmission != true
                    && !blocksNewSubmissionForHermesRecovery,
                isStopping: isStoppingAgent,
                onStop: {
                    store.interruptAgent(
                        appModel: appModel,
                        selectionDiscussionID: selectionDiscussionID
                    )
                },
                supportsBinarySources: CourseAgentProvider.supportsBinarySources(displayedAgentID),
                selectedPhoto: $selectedPhoto,
                onChooseFile: { showsFileImporter = true },
                onPasteLink: pasteLink
            )
        }
    }

    private func sendCurrentMessage() {
        guard !isPreparingSelectionDiscussion,
              !isPreparingDisplayedSource,
              isAgentReady,
              !isAgentWorking,
              !blocksNewSubmissionForHermesRecovery else { return }
        let text = inputText
        let reference = hasSentSelectionContext ? nil : selectionContext
        let accepted = store.sendMessage(
            text,
            reference: reference,
            selectionDiscussionID: selectionDiscussionID,
            appModel: appModel,
            appState: appState
        )
        guard accepted else { return }
        inputText = ""
        composerFocused = false
        autoFollowStreaming = true
        isNearBottom = true
    }

    private func retryCurrentSubmission() {
        Task { @MainActor in
            if let selectionDiscussionID {
                await store.refreshSelectionDiscussionReadiness(
                    id: selectionDiscussionID,
                    appModel: appModel
                )
            } else {
                await store.refreshAgentReadiness(appModel: appModel)
            }
            _ = store.retryRecoveredSubmission(
                selectionDiscussionID: selectionDiscussionID,
                appModel: appModel,
                appState: appState
            )
        }
    }

    private func resolveDiscussion() {
        guard let selectionDiscussionID else { return }
        isResolvingDiscussion = true
        Task {
            defer { isResolvingDiscussion = false }
            do {
                try await store.resolveSelectionDiscussion(
                    id: selectionDiscussionID,
                    appModel: appModel
                )
                dismiss()
            } catch {
                resolveError = "The agent discussion could not be closed, so the passage remains highlighted. \(error.localizedDescription)"
            }
        }
    }

    private func dismissDisplayedError() {
        if let selectionDiscussionID {
            store.selectionDiscussionErrors[selectionDiscussionID] = nil
        } else {
            store.agentError = nil
        }
    }

    private func stopHermesRecovery(preserveWorkspace: Bool) {
        Task {
            do {
                try await store.abandonPendingHermesRecovery(
                    selectionDiscussionID: selectionDiscussionID,
                    preserveWorkspace: preserveWorkspace,
                    appModel: appModel
                )
            } catch {
                let recoveryErrorMessage = error.localizedDescription
                if let selectionDiscussionID {
                    store.selectionDiscussionErrors[selectionDiscussionID] =
                        recoveryErrorMessage
                } else {
                    store.agentError = recoveryErrorMessage
                }
            }
        }
    }

    private func checkSubmissionStatus() {
        Task {
            await store.checkSubmissionStatus(
                selectionDiscussionID: selectionDiscussionID,
                appModel: appModel,
                appState: appState
            )
        }
    }

    private func discardRecoveredSubmission() {
        guard store.discardRecoveredSubmission(
            selectionDiscussionID: selectionDiscussionID
        ) else { return }
        inputText = store.takeDraft(for: selectionDiscussionID) ?? ""
        selectedPhoto = nil
        composerFocused = false
    }

    private func abandonUnconfirmedSubmission() {
        guard store.abandonUnconfirmedSubmission(
            selectionDiscussionID: selectionDiscussionID
        ) else { return }
        inputText = store.takeDraft(for: selectionDiscussionID) ?? ""
        selectedPhoto = nil
        composerFocused = false
    }

    @ViewBuilder
    private var agentStatusControl: some View {
        if codexNeedsSignIn {
            Button(action: reconnectAgent) {
                agentStatusLabel(color: .orange)
            }
            .accessibilityLabel("Sign in to \(displayedAgentID.displayLabel)")
        } else {
            agentStatusLabel(color: isAgentReady ? .green : .gray)
                .accessibilityLabel(
                    isAgentReady
                        ? "\(displayedAgentID.displayLabel) connected"
                        : "\(displayedAgentID.displayLabel) unavailable"
                )
        }
    }

    private func agentStatusLabel(color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            AgentIconView(kind: displayedAgentID, size: 23)
        }
        .frame(minWidth: 44, minHeight: 44)
        .padding(.horizontal, 4)
        .background(.thinMaterial, in: Capsule())
    }

    private func reconnectAgent() {
        Task {
            guard !isReconnectingAgent else { return }
            isReconnectingAgent = true
            defer { isReconnectingAgent = false }
            if let selectionDiscussionID {
                await store.reconnectSelectionDiscussion(
                    id: selectionDiscussionID,
                    appModel: appModel
                )
            } else {
                let localServerID = appModel.snapshot?.servers.first(where: \.isLocal)?.serverId
                switch CourseAgentReconnectPolicy.action(
                    effectiveTargetServerID: store.effectiveMainCourseServerID(),
                    localServerID: localServerID
                ) {
                case .reconnectServer(let serverID):
                    await AppRuntimeController.shared.reconnectServer(serverId: serverID)
                    await store.refreshAgentReadiness(appModel: appModel)
                case .connectAgent:
                    await store.connectLocalAgent(
                        appModel: appModel,
                        agentID: displayedAgentID,
                        modelID: store.selectionDiscussionModelID(id: nil),
                        reasoningEffortID: store.selectedReasoningEffortID
                    )
                }
            }
        }
    }

    private func requestFollowScrollAfterLayout(_ proxy: ScrollViewProxy) {
        guard !followScrollScheduled else { return }
        followScrollScheduled = true
        DispatchQueue.main.async {
            followScrollScheduled = false
            guard CourseChatScrollPolicy.shouldFollow(
                autoFollowEnabled: autoFollowStreaming,
                userIsDragging: userIsDraggingScroll
            ) else { return }
            proxy.scrollTo("course-chat-bottom", anchor: .bottom)
        }
    }

    private func updateDistanceFromBottom(_ distance: CGFloat) {
        let clampedDistance = max(0, distance)
        let nextIsNearBottom =
            clampedDistance <= CourseChatScrollPolicy.nearBottomDistance
        if nextIsNearBottom != isNearBottom {
            isNearBottom = nextIsNearBottom
        }

        let nextAutoFollow = CourseChatScrollPolicy.updatedAutoFollow(
            currentValue: autoFollowStreaming,
            distanceFromBottom: clampedDistance,
            userIsDragging: userIsDraggingScroll,
            isAgentWorking: isAgentWorking
        )
        if nextAutoFollow != autoFollowStreaming {
            autoFollowStreaming = nextAutoFollow
        }
    }

    private func pasteLink() {
        guard let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: pasted),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            attachmentError = CourseSourceAttachmentErrorPresentation(
                kind: .parse
            )
            return
        }
        store.addSource(
            CourseSource(
                name: pasted,
                detail: url.host?.uppercased() ?? "LINK",
                kind: .link
            ),
            for: selectionDiscussionID
        )
    }
}

private enum CourseAgentErrorInitialConfirmation {
    case none
    case discardDraft
    case abandonRecovery
    case abandonUnknownDraft
    case startNewDiscussion
}

private struct CourseRecoveredDraftProvenanceView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "arrow.uturn.backward.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("course-recovered-draft-provenance")
    }
}

private enum CourseRecoveryVisualStyle {
    static let supportingText = Color.primary.opacity(0.78)
    static let technicalText = Color.primary.opacity(0.72)
    static let destructiveAction = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return traits.accessibilityContrast == .high
                ? UIColor(red: 1, green: 0.82, blue: 0.80, alpha: 1)
                : UIColor(red: 1, green: 0.70, blue: 0.67, alpha: 1)
        }
        return traits.accessibilityContrast == .high
            ? UIColor(red: 0.38, green: 0, blue: 0.04, alpha: 1)
            : UIColor(red: 0.55, green: 0, blue: 0.08, alpha: 1)
    })
}

private enum CourseHermesRecoveryCopy {
    static let stopTitle = "Stop Hermes recovery?"
    static let stopAndKeepAction = "Stop & Keep Workspace"
    static let resolveTitle = "Resolve Hermes recovery?"
    static let keepWorkspaceAction = "Keep Workspace"
    static let archiveAndDeleteAction = "Archive Evidence & Delete Draft"

    static func stopMessage(allowsWorkspaceDeletion: Bool) -> String {
        if allowsWorkspaceDeletion {
            return "Recovery will stop and its evidence will be kept. You can keep the draft workspace or permanently delete it after the evidence is archived. Deleting the workspace cannot be undone."
        }
        return "Recovery will stop and its evidence will be kept. The course workspace will stay intact so you can review or continue it later."
    }

    static func resolveMessage(allowsWorkspaceDeletion: Bool) -> String {
        if allowsWorkspaceDeletion {
            return "Recovery is already stopped and its evidence is kept. Choose whether to keep the draft workspace or archive the evidence and permanently delete the draft. Deleting the workspace cannot be undone."
        }
        return "Recovery is already stopped and its evidence is kept. Keep the course workspace to clear this recovery block so you can review or continue it later."
    }
}

private struct CourseHermesRecoveryStopAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    let allowsWorkspaceDeletion: Bool
    let onStopRecovery: (Bool) -> Void

    func body(content: Content) -> some View {
        content.alert(
            CourseHermesRecoveryCopy.stopTitle,
            isPresented: $isPresented
        ) {
            Button(CourseHermesRecoveryCopy.stopAndKeepAction) {
                onStopRecovery(true)
            }
            .accessibilityIdentifier("course-agent-error.confirm.keep-workspace")
            if allowsWorkspaceDeletion {
                Button(
                    CourseHermesRecoveryCopy.archiveAndDeleteAction,
                    role: .destructive
                ) {
                    onStopRecovery(false)
                }
                .accessibilityIdentifier("course-agent-error.confirm.delete-workspace")
            }
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier(
                    "course-agent-error.confirm.cancel-abandon-recovery"
                )
        } message: {
            Text(
                CourseHermesRecoveryCopy.stopMessage(
                    allowsWorkspaceDeletion: allowsWorkspaceDeletion
                )
            )
        }
    }
}

private extension View {
    func courseHermesRecoveryStopAlert(
        isPresented: Binding<Bool>,
        allowsWorkspaceDeletion: Bool,
        onStopRecovery: @escaping (Bool) -> Void
    ) -> some View {
        modifier(CourseHermesRecoveryStopAlertModifier(
            isPresented: isPresented,
            allowsWorkspaceDeletion: allowsWorkspaceDeletion,
            onStopRecovery: onStopRecovery
        ))
    }
}

private struct CourseHermesRecoveryProgressView: View {
    let agentID: String
    let provenance: CourseHermesRecoveryProvenance
    let progressState: CourseHermesRecoveryProgressState
    let allowsWorkspaceDeletion: Bool
    let onStopRecovery: (Bool) -> Void
    @State private var showsStopConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                AgentIconView(kind: agentID, size: 27)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermes recovery in progress")
                        .font(.subheadline.weight(.semibold))
                    Text("Your draft, course workspace, and recovery evidence are protected while Learnfold safely resumes unfinished work.")
                        .font(.caption)
                        .foregroundStyle(CourseRecoveryVisualStyle.supportingText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            ProgressView()
                .progressViewStyle(.linear)
                .tint(.primary)
                .accessibilityIdentifier("course-hermes-recovery.progress")
                .accessibilityLabel("Hermes recovery progress")
                .accessibilityValue("In progress")

            Button {
                showsStopConfirmation = true
            } label: {
                Text("Stop Recovery…")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .accessibilityIdentifier("course-hermes-recovery.action.stop")

            CourseHermesRecoveryProvenanceView(provenance: provenance)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.24))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-hermes-recovery-progress")
        .accessibilityLabel("Hermes recovery in progress")
        .accessibilityValue(progressState.rawValue)
        .courseHermesRecoveryStopAlert(
            isPresented: $showsStopConfirmation,
            allowsWorkspaceDeletion: allowsWorkspaceDeletion,
            onStopRecovery: onStopRecovery
        )
    }
}

private struct CourseHermesRecoveryProvenanceView: View {
    let provenance: CourseHermesRecoveryProvenance
    @State private var showsTechnicalDetails = false

    var body: some View {
        DisclosureGroup(isExpanded: $showsTechnicalDetails) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Workspace · Protected local course data")
                    .accessibilityIdentifier("course-hermes-recovery-provenance.workspace")
                Text("Discussion · \(discussionKindText)")
                    .accessibilityIdentifier("course-hermes-recovery-provenance.discussion")
                Text("Journal · \(journalStateText)")
                    .accessibilityIdentifier("course-hermes-recovery-provenance.journal")
                Text(
                    CourseHermesRecoveryProgressPolicy.correlationLabel(
                        for: provenance.journalState
                    )
                )
                    .accessibilityIdentifier("course-hermes-recovery-provenance.correlation")
            }
            .font(.caption.monospaced())
            .foregroundStyle(CourseRecoveryVisualStyle.technicalText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
        } label: {
            Label("Technical recovery details", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityIdentifier(
                    "course-hermes-recovery-provenance.toggle"
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.16))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-hermes-recovery-provenance")
    }

    private var discussionKindText: String {
        switch provenance.discussionKind {
        case .course:
            "Course conversation"
        case .selection:
            "Passage discussion"
        }
    }

    private var journalStateText: String {
        switch provenance.journalState {
        case .submissionIntent:
            "Submission intent saved"
        case .acceptedTurn:
            "Accepted turn awaiting completion"
        case .toolLifecyclePending:
            "Native tool lifecycle recovery pending"
        case .toolExecuting:
            "Native tool execution interrupted"
        case .toolExecuted:
            "Native tool result preserved"
        case .resultSubmitting:
            "Native tool result delivery pending"
        case .resultSubmitted:
            "Native tool result delivered; completion pending"
        case .terminalFailure:
            "Terminal recovery failure preserved"
        case .unreadableEvidence:
            "Recovery evidence could not be read safely"
        }
    }
}

private struct CourseDraftDeletionScopeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Review before deleting", systemImage: "doc.text.magnifyingglass")
                .font(.caption.weight(.semibold))

            LabeledContent("Will delete") {
                Text("Remaining draft workspace data")
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("course-agent-error.deletion.will-delete")

            LabeledContent("Will keep") {
                Text("Archived recovery evidence")
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("course-agent-error.deletion.will-keep")

            Text("Permanent deletion cannot be undone. The kept recovery evidence remains available for review.")
                .foregroundStyle(CourseRecoveryVisualStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.20))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-agent-error.deletion.scope")
    }
}

private struct CourseAgentErrorCard: View {
    let agentName: String
    let message: String
    let needsAuthentication: Bool
    let isConnecting: Bool
    let showsReconnectAction: Bool
    let blockingAction: CourseAgentErrorBlockingAction
    let abandonMode: CourseHermesRecoveryAbandonMode
    let allowsWorkspaceDeletion: Bool
    let allowsUnknownSubmissionAbandon: Bool
    let submissionRecoveryState: CourseAgentSubmissionRecoveryState?
    let hermesRecoveryProvenance: CourseHermesRecoveryProvenance?
    let onReconnect: () -> Void
    let onRetrySubmission: () -> Void
    let onCheckStatus: () -> Void
    let onDiscardSubmission: () -> Void
    let onAbandonUnknownSubmission: () -> Void
    let onRetryRecovery: () -> Void
    let onAbandonRecovery: (Bool) -> Void
    let onStartNewDiscussion: () -> Void
    let onDismiss: () -> Void
    var allowsDismissal = true
    var initialConfirmation: CourseAgentErrorInitialConfirmation = .none
    @State private var showsAbandonConfirmation = false
    @State private var showsStartNewConfirmation = false
    @State private var showsDiscardConfirmation = false
    @State private var showsUnknownAbandonConfirmation = false
    @State private var didPresentInitialConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(errorTitle, systemImage: errorSystemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(errorTitleColor)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(errorTitle)
                .accessibilityIdentifier("course-agent-error.title")

            Text(message)
                .font(.subheadline)
                .foregroundStyle(CourseRecoveryVisualStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("course-agent-error.message")

            if isFinishDraftDeletion {
                CourseDraftDeletionScopeView()
            }

            if let provenance = submissionRecoveryState?.draftProvenanceText {
                CourseRecoveredDraftProvenanceView(text: provenance)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    actionButtons(expandsHorizontally: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    actionButtons(expandsHorizontally: true)
                }
            }
            .controlSize(.large)

            if let hermesRecoveryProvenance {
                CourseHermesRecoveryProvenanceView(
                    provenance: hermesRecoveryProvenance
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-agent-error")
        .confirmationDialog(
            "Discard the restored draft?",
            isPresented: $showsDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Draft", role: .destructive, action: onDiscardSubmission)
                .accessibilityIdentifier("course-agent-error.confirm.discard-draft")
            Button("Keep Draft") {}
                .accessibilityIdentifier("course-agent-error.confirm.keep-draft")
        } message: {
            Text("The restored message and its attached sources will be removed. The course and conversation will stay intact.")
        }
        .alert(
            isFinishDraftDeletion
                ? "Permanently delete the remaining draft?"
                : usesHermesRecoveryResolutionCopy
                    ? CourseHermesRecoveryCopy.resolveTitle
                    : CourseHermesRecoveryCopy.stopTitle,
            isPresented: $showsAbandonConfirmation
        ) {
            if isFinishDraftDeletion {
                Button("Permanently Delete Remaining Draft", role: .destructive) {
                    onAbandonRecovery(false)
                }
                .accessibilityIdentifier(
                    "course-agent-error.confirm.finish-delete-draft"
                )
                Button("Not Now", role: .cancel) {}
                    .accessibilityIdentifier(
                        "course-agent-error.confirm.cancel-abandon-recovery"
                    )
            } else {
                Button(
                    usesHermesRecoveryResolutionCopy
                        ? CourseHermesRecoveryCopy.keepWorkspaceAction
                        : CourseHermesRecoveryCopy.stopAndKeepAction
                ) {
                    onAbandonRecovery(true)
                }
                .accessibilityIdentifier("course-agent-error.confirm.keep-workspace")
                if allowsWorkspaceDeletion {
                    Button(
                        CourseHermesRecoveryCopy.archiveAndDeleteAction,
                        role: .destructive
                    ) {
                        onAbandonRecovery(false)
                    }
                    .accessibilityIdentifier("course-agent-error.confirm.delete-workspace")
                }
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier(
                        "course-agent-error.confirm.cancel-abandon-recovery"
                    )
            }
        } message: {
            Text(
                isFinishDraftDeletion
                    ? "Will delete: remaining draft workspace data.\n\nWill keep: archived recovery evidence.\n\nPermanent deletion cannot be undone. Review these consequences before continuing."
                    : usesHermesRecoveryResolutionCopy
                        ? CourseHermesRecoveryCopy.resolveMessage(
                            allowsWorkspaceDeletion: allowsWorkspaceDeletion
                        )
                        : CourseHermesRecoveryCopy.stopMessage(
                            allowsWorkspaceDeletion: allowsWorkspaceDeletion
                        )
            )
        }
        .confirmationDialog(
            "Abandon the unconfirmed local draft?",
            isPresented: $showsUnknownAbandonConfirmation,
            titleVisibility: .visible
        ) {
            Button("Abandon Local Draft", role: .destructive, action: onAbandonUnknownSubmission)
                .accessibilityIdentifier("course-agent-error.confirm.abandon-local-draft")
            Button("Keep Checking") {}
                .accessibilityIdentifier("course-agent-error.confirm.keep-checking")
        } message: {
            Text("Learnfold cannot prove whether the agent received this message. Abandoning removes the local recovered copy and unlocks the composer. Review the conversation before sending the same request again, because doing so could create a duplicate.")
        }
        .alert(
            "Start a new discussion?",
            isPresented: $showsStartNewConfirmation
        ) {
            Button("Start New Discussion", action: onStartNewDiscussion)
                .accessibilityIdentifier("course-agent-error.confirm.close-start-new")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("course-agent-error.confirm.cancel-close-start-new")
        } message: {
            Text("Your old annotation and recovery evidence will be kept. The new discussion will use your currently selected agent in the same course workspace.")
        }
        .onAppear {
            guard !didPresentInitialConfirmation else { return }
            didPresentInitialConfirmation = true
            switch initialConfirmation {
            case .none:
                break
            case .discardDraft:
                showsDiscardConfirmation = true
            case .abandonRecovery:
                showsAbandonConfirmation = true
            case .abandonUnknownDraft:
                showsUnknownAbandonConfirmation = true
            case .startNewDiscussion:
                showsStartNewConfirmation = true
            }
        }
    }

    private var isFinishDraftDeletion: Bool {
        abandonMode == .finishDraftDeletion
    }

    private var isHermesRecoveryError: Bool {
        if case .recovery = blockingAction { return true }
        return false
    }

    private var usesHermesRecoveryResolutionCopy: Bool {
        guard let hermesRecoveryProvenance else { return false }
        return CourseHermesRecoveryProgressPolicy.usesResolutionCopy(
            for: hermesRecoveryProvenance.journalState,
            abandonMode: abandonMode
        )
    }

    private var errorTitle: String {
        if isFinishDraftDeletion {
            return "Draft deletion is incomplete"
        }
        if isHermesRecoveryError {
            return "Hermes recovery needs attention"
        }
        if blockingAction == .missingThread {
            return "Discussion thread missing"
        }
        if agentName == CourseAgentProvider.hosted.displayLabel,
           submissionRecoveryState == .acceptedReplyIncomplete {
            return "Reply interrupted"
        }
        return "\(agentName) couldn’t continue"
    }

    private var errorSystemImage: String {
        isFinishDraftDeletion
            ? "trash.slash.fill"
            : "exclamationmark.triangle.fill"
    }

    private var errorTitleColor: Color {
        isHermesRecoveryError || blockingAction == .missingThread
            ? CourseRecoveryVisualStyle.destructiveAction
            : .red
    }

    @ViewBuilder
    private func actionButtons(expandsHorizontally: Bool) -> some View {
        switch blockingAction {
        case .missingThread:
            recoveryActionButton(
                "Start New Discussion",
                identifier: "course-agent-error.action.close-start-new",
                expandsHorizontally: expandsHorizontally
            ) {
                showsStartNewConfirmation = true
            }
        case .recovery(let allowsRetry):
            if isFinishDraftDeletion {
                recoveryActionButton(
                    "Review Permanent Deletion…",
                    identifier: "course-agent-error.action.finish-delete-draft",
                    expandsHorizontally: expandsHorizontally
                ) {
                    showsAbandonConfirmation = true
                }
            } else {
                if allowsRetry {
                    recoveryActionButton(
                        "Retry Recovery",
                        identifier: "course-agent-error.action.retry-recovery",
                        expandsHorizontally: expandsHorizontally,
                        action: onRetryRecovery
                    )
                }
                recoveryActionButton(
                    usesHermesRecoveryResolutionCopy
                        ? "Resolve Recovery…"
                        : "Stop Recovery…",
                    identifier: "course-agent-error.action.abandon-recovery",
                    expandsHorizontally: expandsHorizontally
                ) {
                    showsAbandonConfirmation = true
                }
            }
        case .none:
            standardActionButtons(expandsHorizontally: expandsHorizontally)
        }

        if allowsDismissal {
            recoveryActionButton(
                dismissalTitle,
                identifier: "course-agent-error.action.dismiss",
                expandsHorizontally: expandsHorizontally,
                action: onDismiss
            )
        }
    }

    @ViewBuilder
    private func standardActionButtons(expandsHorizontally: Bool) -> some View {
        if needsAuthentication {
            Button(action: onReconnect) {
                Group {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .frame(
                    maxWidth: expandsHorizontally ? .infinity : nil,
                    minHeight: 44
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting)
            .accessibilityIdentifier("course-agent-error.action.sign-in")
        } else if showsReconnectAction {
            Button(action: onReconnect) {
                Group {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                }
                .frame(
                    maxWidth: expandsHorizontally ? .infinity : nil,
                    minHeight: 44
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting)
            .accessibilityIdentifier("course-agent-error.action.reconnect")
        } else if let submissionRecoveryState {
            switch submissionRecoveryState {
            case .preparing, .knownNotAccepted:
                Button(action: onRetrySubmission) {
                    actionLabel("Try Again", expandsHorizontally: expandsHorizontally)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("course-agent-error.action.retry-submission")
                Button(role: .destructive) {
                    showsDiscardConfirmation = true
                } label: {
                    actionLabel("Discard Draft", expandsHorizontally: expandsHorizontally)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("course-agent-error.action.discard-draft")
            case .acceptanceUnknown:
                Button(action: onCheckStatus) {
                    actionLabel("Check Status", expandsHorizontally: expandsHorizontally)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("course-agent-error.action.check-status")
                if allowsUnknownSubmissionAbandon {
                    Button(role: .destructive) {
                        showsUnknownAbandonConfirmation = true
                    } label: {
                        actionLabel(
                            "Abandon Local Draft…",
                            expandsHorizontally: expandsHorizontally
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(
                        "course-agent-error.action.abandon-local-draft"
                    )
                }
            case .acceptedReplyIncomplete:
                Button(action: onCheckStatus) {
                    actionLabel(
                        agentName == CourseAgentProvider.hosted.displayLabel ? "Reload Conversation" : "Check Status",
                        expandsHorizontally: expandsHorizontally
                    )
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("course-agent-error.action.check-status")
            }
        }
    }

    private func recoveryActionButton(
        _ title: String,
        identifier: String,
        expandsHorizontally: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            actionLabel(
                title,
                expandsHorizontally: expandsHorizontally,
                emphasized: true
            )
        }
        .buttonStyle(.bordered)
        .tint(.primary)
        .accessibilityIdentifier(identifier)
    }

    private func actionLabel(
        _ title: String,
        expandsHorizontally: Bool,
        emphasized: Bool = false
    ) -> some View {
        Text(title)
            .font(.subheadline.weight(emphasized ? .semibold : .regular))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: !expandsHorizontally, vertical: false)
            .frame(
                maxWidth: expandsHorizontally ? .infinity : nil,
                minHeight: 44
            )
            .contentShape(Rectangle())
    }

    private var dismissalTitle: String {
        if blockingAction == .missingThread {
            return "Hide Notice"
        }
        return submissionRecoveryState == nil ? "Dismiss" : "Not Now"
    }
}

private struct CourseSubmissionRecoveryStrip: View {
    let state: CourseAgentSubmissionRecoveryState
    let allowsUnknownSubmissionAbandon: Bool
    let onCheckStatus: () -> Void
    let onDiscardDraft: () -> Void
    let onAbandonUnknownSubmission: () -> Void
    @State private var showsDiscardConfirmation = false
    @State private var showsUnknownAbandonConfirmation = false

    var body: some View {
        HStack(spacing: 10) {
            Label(statusText, systemImage: statusIcon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if state.blocksNewSubmission {
                Button("Check Status", action: onCheckStatus)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                if state == .acceptanceUnknown, allowsUnknownSubmissionAbandon {
                    Button("Abandon…", role: .destructive) {
                        showsUnknownAbandonConfirmation = true
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                }
            } else if state.canDiscardDraft {
                Button("Discard Draft", role: .destructive) {
                    showsDiscardConfirmation = true
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-submission-recovery")
        .confirmationDialog(
            "Discard the restored draft?",
            isPresented: $showsDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Draft", role: .destructive, action: onDiscardDraft)
            Button("Keep Draft") {}
        } message: {
            Text("The restored message and its attached sources will be removed. The course and conversation will stay intact.")
        }
        .confirmationDialog(
            "Abandon the unconfirmed local draft?",
            isPresented: $showsUnknownAbandonConfirmation,
            titleVisibility: .visible
        ) {
            Button("Abandon Local Draft", role: .destructive, action: onAbandonUnknownSubmission)
            Button("Keep Checking") {}
        } message: {
            Text("Learnfold cannot prove whether the agent received this message. Abandoning unlocks the composer, but sending the same request again could duplicate work. Review the conversation first.")
        }
    }

    private var statusText: String {
        switch state {
        case .preparing, .knownNotAccepted:
            "Message not sent · Draft restored"
        case .acceptanceUnknown:
            "Status unknown · Draft preserved"
        case .acceptedReplyIncomplete:
            "Reply incomplete · Conversation preserved"
        }
    }

    private var statusIcon: String {
        switch state {
        case .preparing, .knownNotAccepted:
            "arrow.uturn.backward.circle"
        case .acceptanceUnknown, .acceptedReplyIncomplete:
            "arrow.clockwise.circle"
        }
    }
}

private struct CourseSelectionContextCard: View {
    let reference: CourseTextReference
    let agentName: String
    let focusedQAState: CourseFocusedQAState
    @State private var showsFullPassage = false
    @AccessibilityFocusState private var passageButtonFocused: Bool

    private var preview: String {
        let limit = 600
        guard reference.selectedText.count > limit else { return reference.selectedText }
        return String(reference.selectedText.prefix(limit)) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Selected from \(reference.pageTitle)", systemImage: "text.quote")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                Spacer()
                Text(agentName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.1), in: Capsule())
                    .accessibilityLabel("Discussion agent: \(agentName)")
            }

            Text(preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Passage preview. \(preview)")

            if reference.selectedText.count > 600 {
                Button("Read full selected passage") {
                    showsFullPassage = true
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityFocused($passageButtonFocused)
                .accessibilityIdentifier("focused-qa-open-reader")
            }

            if reference.wasTruncated {
                Text("The first \(CourseTextReference.maximumLength.formatted()) characters will be sent as context.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.blue.opacity(0.14))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("focused-qa-state")
        .accessibilityValue(focusedQAState.rawValue)
        .sheet(isPresented: $showsFullPassage, onDismiss: {
            passageButtonFocused = true
        }) {
            CourseSelectedPassageReader(reference: reference)
        }
    }
}

private struct CourseSelectedPassageReader: View {
    @Environment(\.dismiss) private var dismiss
    let reference: CourseTextReference

    private var chunks: [String] {
        reference.selectedText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .flatMap { paragraph -> [String] in
                let text = String(paragraph)
                return stride(from: 0, to: text.count, by: 800).map { offset in
                    let start = text.index(text.startIndex, offsetBy: offset)
                    let end = text.index(start, offsetBy: min(800, text.distance(from: start, to: text.endIndex)))
                    return String(text[start..<end])
                }
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                        Text(chunk)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if reference.wasTruncated {
                        Text("Only the first \(CourseTextReference.maximumLength.formatted()) characters were captured from the original selection.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Selected passage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("focused-qa-reader")
    }
}

private struct CourseChatIntro: View {
    var agentID: String = CourseAgentProvider.appleOnDevice
    let supportsBinarySources: Bool

    private var description: String {
        if supportsBinarySources {
            return "Talk naturally. Your course agent can work from files, images, and URLs just like a desktop agent."
        }
        if agentID == CourseAgentProvider.hosted {
            return "Talk naturally. Hosted can answer questions, use web links, and build native course pages after you approve its plan."
        }
        return "Talk naturally. Your Apple course agent can answer questions, use web links, and build native course pages after you approve its plan."
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(.blue.opacity(0.1))
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 58, height: 58)

            Text("Build something worth learning")
                .font(.title3.weight(.bold))
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

private struct CourseMessageRow: View {
    let message: CourseChatMessage
    let agentID: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            if message.role == .learner { Spacer(minLength: 40) }

            if message.role == .agent {
                AgentIconView(kind: agentID, size: 27)
                    .padding(.bottom, 5)
            }

            VStack(alignment: message.role == .learner ? .trailing : .leading, spacing: 8) {
                if !message.sources.isEmpty {
                    VStack(spacing: 7) {
                        ForEach(message.sources) { source in
                            CourseSourceTile(source: source, compact: false)
                        }
                    }
                }

                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(message.role == .learner ? .white : .primary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                message.role == .learner ? AnyShapeStyle(Color.blue) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                if message.role == .agent {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.black.opacity(0.05))
                }
            }

            if message.role == .agent { Spacer(minLength: 34) }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CourseSourceTile: View {
    let source: CourseSource
    var compact: Bool

    private var symbol: String {
        switch source.kind {
        case .document: "doc.fill"
        case .image: "photo.fill"
        case .link: "link"
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            if let image = source.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: compact ? 30 : 38, height: compact ? 30 : 38)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: compact ? 30 : 38, height: compact ? 30 : 38)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(source.detail)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 7 : 9)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
        .foregroundStyle(.primary)
    }
}

private struct CourseChatComposer: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var inputText: String
    let prompt: String
    let sources: [CourseSource]
    var isFocused: FocusState<Bool>.Binding
    let onRemoveSource: (CourseSource) -> Void
    let onSend: () -> Void
    let isAgentWorking: Bool
    let isPreparing: Bool
    var preparationLabel: String = "Preparing source…"
    let isEditingEnabled: Bool
    let isAgentReady: Bool
    let isStopping: Bool
    let onStop: () -> Void
    let supportsBinarySources: Bool
    var checkpointPhotoAction: (() -> Void)? = nil
    @Binding var selectedPhoto: PhotosPickerItem?
    let onChooseFile: () -> Void
    let onPasteLink: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if isPreparing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(preparationLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(preparationLabel)
                .accessibilityIdentifier("course-chat-source-preparing")
            }

            if !sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sources) { source in
                            HStack(spacing: 5) {
                                CourseSourceTile(source: source, compact: true)
                                    .frame(width: 164)
                                    // Keep the sticky composer from consuming
                                    // most of the viewport at the largest
                                    // accessibility sizes. The full source
                                    // name remains available to VoiceOver.
                                    .dynamicTypeSize(.xSmall ... .accessibility1)
                                Button {
                                    onRemoveSource(source)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(!isEditingEnabled)
                            }
                            .padding(4)
                            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            HStack(alignment: .bottom, spacing: 9) {
                Menu {
                    if supportsBinarySources {
                        if let checkpointPhotoAction {
                            Button(action: checkpointPhotoAction) {
                                Label("Photo", systemImage: "photo")
                            }
                        } else {
                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                Label("Photo", systemImage: "photo")
                            }
                        }
                        Button(action: onChooseFile) {
                            Label("File", systemImage: "doc")
                        }
                    }
                    Button(action: onPasteLink) {
                        Label("Paste Link", systemImage: "link")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("Add a source")
                .accessibilityIdentifier("course-chat-add-source")
                .disabled(isPreparing || !isEditingEnabled)

                TextField(prompt, text: $inputText, axis: .vertical)
                    .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 2 : 5))
                    .focused(isFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .accessibilityLabel(prompt)
                    .accessibilityIdentifier("course-chat-composer")
                    .disabled(isPreparing || !isEditingEnabled)

                Button(action: isAgentWorking ? onStop : onSend) {
                    Group {
                        if isPreparing || isStopping {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: isAgentWorking ? "stop.fill" : "arrow.up")
                                .font(.headline.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(sendButtonColor, in: Circle())
                }
                .disabled(
                    isPreparing || isStopping ||
                        (!isAgentWorking && (!isAgentReady || !canSend))
                )
                .accessibilityLabel(
                    isPreparing
                        ? preparationLabel
                        : (isStopping
                            ? "Stopping agent"
                            : (isAgentWorking
                            ? "Stop agent"
                            : (isAgentReady ? "Send message" : "Agent unavailable")))
                )
                .accessibilityIdentifier(isAgentWorking ? "course-chat-stop" : "course-chat-send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !sources.isEmpty
    }

    private var sendButtonColor: Color {
        if isPreparing { return .gray.opacity(0.5) }
        if isStopping { return .gray.opacity(0.5) }
        if isAgentWorking { return .primary }
        return isAgentReady && canSend ? .blue : .gray.opacity(0.35)
    }
}

#if DEBUG
struct CourseSourceCheckpointUITestHarnessView: View {
    let scenario: ProviderSettingsSourceCheckpointScenario
    let onMemoryOnlyAction: () -> Void

    @State private var inputText = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var attachmentError: CourseSourceAttachmentErrorPresentation?
    @State private var actionResult: String?
    @FocusState private var composerFocused: Bool

    init(
        scenario: ProviderSettingsSourceCheckpointScenario,
        onMemoryOnlyAction: @escaping () -> Void
    ) {
        self.scenario = scenario
        self.onMemoryOnlyAction = onMemoryOnlyAction
        _attachmentError = State(initialValue: Self.errorPresentation(for: scenario))
    }

    private var sources: [CourseSource] { [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if scenario == .lf30PassageContext {
                        CourseSelectionContextCard(
                            reference: Self.passageReference,
                            agentName: "Codex",
                            focusedQAState: .initialSheet
                        )
                        .accessibilityIdentifier("lf30-passage-context")
                    } else {
                        CourseChatIntro(supportsBinarySources: true)
                    }

                    if let actionResult {
                        Label(actionResult, systemImage: "checkmark.shield")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                "lf30-memory-only-action-result"
                            )
                    }

                    Text("Attached sources · \(sources.count)")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("lf30-source-count")
                        .accessibilityValue("sources=\(sources.count)")

                    if Self.errorPresentation(for: scenario) != nil {
                        Text("No source was added. The composer remains available after dismissing the error.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("lf30-error-recovery-note")
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                CourseChatComposer(
                    inputText: $inputText,
                    prompt: "Message your course agent",
                    sources: sources,
                    isFocused: $composerFocused,
                    onRemoveSource: { _ in },
                    onSend: recordMemoryOnlySend,
                    isAgentWorking: false,
                    isPreparing: scenario == .lf30Preparing,
                    isEditingEnabled: true,
                    isAgentReady: true,
                    isStopping: false,
                    onStop: {},
                    supportsBinarySources: true,
                    checkpointPhotoAction: {
                        recordMemoryOnlyAction("Photo action stayed in memory")
                    },
                    selectedPhoto: $selectedPhoto,
                    onChooseFile: {
                        recordMemoryOnlyAction("File action stayed in memory")
                    },
                    onPasteLink: {
                        recordMemoryOnlyAction("Paste action did not read the pasteboard")
                    }
                )
            }
            .navigationTitle(
                scenario == .lf30PassageContext
                    ? "Ask about this passage"
                    : "New Course"
            )
            .navigationBarTitleDisplayMode(.inline)
        }
        .courseSourceAttachmentErrorAlert(error: $attachmentError)
        .accessibilityIdentifier("lf30-source-checkpoint")
        .accessibilityValue(scenario.substate)
    }

    private func recordMemoryOnlySend() {
        recordMemoryOnlyAction("Send action stayed in memory")
    }

    private func recordMemoryOnlyAction(_ result: String) {
        onMemoryOnlyAction()
        actionResult = result
    }

    private static func errorPresentation(
        for scenario: ProviderSettingsSourceCheckpointScenario
    ) -> CourseSourceAttachmentErrorPresentation? {
        switch scenario {
        case .lf30PermissionError:
            CourseSourceAttachmentErrorPresentation(kind: .permission)
        case .lf30ParseError:
            CourseSourceAttachmentErrorPresentation(kind: .parse)
        case .lf30PreparationError:
            CourseSourceAttachmentErrorPresentation(kind: .preparation)
        default:
            nil
        }
    }

    private static let passageReference: CourseTextReference = {
        guard let reference = CourseTextReference(
            id: UUID(uuidString: "1F300000-0000-4000-8000-000000000001")!,
            courseID: "checkpoint-course",
            pageID: "checkpoint-page",
            pageTitle: "Weather Systems",
            blockID: "checkpoint-block",
            pathIndices: [0, 1],
            rangeLocation: 0,
            selectedText: "Warm ocean air rises, cools, and condenses into clouds. The released heat can strengthen circulation while surrounding pressure patterns steer the system."
        ) else {
            preconditionFailure("The fixed LF-30 passage fixture must be valid.")
        }
        return reference
    }()
}
#endif

private struct CourseBriefCard: View {
    let brief: CourseBrief
    let agentName: String
    let isAgentWorking: Bool
    let isApprovalEnabled: Bool
    let buildAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(.blue.gradient)
                    Image(systemName: "sparkles")
                        .foregroundStyle(.white)
                        .font(.headline)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Your Course Brief")
                        .font(.title3.bold())
                    Text(brief.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text("v\(brief.revision)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.blue.opacity(0.1), in: Capsule())
            }

            Text(brief.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                CourseBriefFact(icon: "target", title: "Outcome", detail: brief.outcome)
                Divider().padding(.leading, 40)
                CourseBriefFact(icon: "figure.walk", title: "Starting point", detail: brief.startingPoint)
                Divider().padding(.leading, 40)
                CourseBriefFact(icon: "scope", title: "Focus gap", detail: brief.focusGap)
                Divider().padding(.leading, 40)
                CourseBriefFact(icon: "clock", title: "Estimated time", detail: brief.estimatedDuration)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("COURSE PATH")
                    .font(.caption2.bold())
                    .tracking(1.2)
                    .foregroundStyle(.secondary)

                ForEach(CoursePlanHierarchyPolicy.outlineEntries(for: brief)) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Text(entry.ordinal)
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                            .frame(minWidth: 30, minHeight: 30)
                            .padding(.horizontal, entry.ordinal.count > 2 ? 5 : 0)
                            .background(.blue.opacity(0.1), in: Capsule())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(entry.role.displayName)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.leading, CGFloat(entry.depth) * 18)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(entry.ordinal), \(entry.role.displayName), \(entry.title)"
                    )
                    .accessibilityIdentifier("course-plan-node-\(entry.id)")
                }
            }

            Button(action: buildAction) {
                Label(
                    isAgentWorking ? "Finishing Plan…" : "Create Course & First Page",
                    systemImage: isAgentWorking ? "ellipsis" : "wand.and.stars"
                )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .foregroundStyle(.white)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isAgentWorking || !isApprovalEnabled)
            .accessibilityIdentifier("build-course-button")

            Text(
                isApprovalEnabled
                    ? "This creates the full course map and writes its first learning page. Later pages adapt as you learn. Want a change? Message \(agentName) first."
                    : "Resolve the preserved message before approving this plan."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.blue.opacity(0.14)))
        .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    }
}

private struct CourseBriefFact: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(.blue.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.bold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }
}

#if DEBUG
struct CourseDraftRecoveryUITestHarnessView: View {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-test-course-draft-recovery")
            || LearnfoldStrictHarnessPolicy.isRecoveryCheckpointActive()
    }

    @State private var inputText = "Please make the laboratory simulations runnable on my Mac."
    @State private var sources = [
        CourseSource(
            name: "longevity-research-notes.pdf",
            detail: "PDF",
            kind: .document
        ),
    ]
    @State private var retryResult: String?
    @FocusState private var composerFocused: Bool
    private let strictLaunchScenario: CourseRecoveryCheckpointUITestScenario?

    init(strictLaunchScenario: CourseRecoveryCheckpointUITestScenario? = nil) {
        self.strictLaunchScenario = strictLaunchScenario
    }

    private var brief: CourseBrief {
        var value = CourseBrief()
        value.planID = "longevity-research-core"
        value.revision = 1
        value.title = "Computational Longevity Research"
        value.summary = "A rigorous, self-contained research path that rebuilds the required biology and chemistry before progressing into computational longevity work."
        value.outcome = "Design, simulate, and evaluate a reproducible longevity-research capstone on a Mac."
        value.startingPoint = "Computer science and electrical engineering fundamentals."
        value.focusGap = "Biology, chemistry, experimental design, and statistical inference."
        value.estimatedDuration = "Expandable"
        value.structureVersion = CoursePlanHierarchyPolicy.currentStructureVersion
        value.chapters = [
            CourseChapter(
                id: "foundations",
                title: "Biology and Chemistry Foundations Without Hidden Prerequisites",
                objective: "Build the molecular and cellular vocabulary required to reason about ageing mechanisms.",
                deliverables: [
                    "Interactive molecular-biology notebook",
                    "Cellular ageing concept map",
                ]
            ),
            CourseChapter(
                id: "simulation",
                title: "Mac-Ready Computational Experiments",
                objective: "Turn research questions into reproducible simulations and measurable hypotheses.",
                deliverables: [
                    "Runnable simulation project",
                    "Final research protocol with analysis plan",
                ]
            ),
        ]
        value.learningPath = [
            CourseLearningNode(
                id: "foundations",
                title: "Biology and Chemistry Foundations Without Hidden Prerequisites",
                kind: .folder,
                status: .pendingGeneration,
                role: .chapter,
                children: [
                    CourseLearningNode(
                        id: "molecular-foundations",
                        title: "Molecular foundations",
                        kind: .folder,
                        status: .pendingGeneration,
                        role: .subchapter,
                        children: [
                            CourseLearningNode(
                                id: "molecular-notebook",
                                title: "Interactive molecular-biology notebook",
                                kind: .markdown,
                                status: .pendingGeneration,
                                role: .lesson
                            ),
                            CourseLearningNode(
                                id: "ageing-concept-map",
                                title: "Cellular ageing concept map",
                                kind: .markdown,
                                status: .pendingGeneration,
                                role: .explainer
                            ),
                        ]
                    ),
                ]
            ),
            CourseLearningNode(
                id: "simulation",
                title: "Mac-Ready Computational Experiments",
                kind: .folder,
                status: .pendingGeneration,
                role: .chapter,
                children: [
                    CourseLearningNode(
                        id: "simulation-project",
                        title: "Runnable simulation project",
                        kind: .markdown,
                        status: .pendingGeneration,
                        role: .module
                    ),
                    CourseLearningNode(
                        id: "final-protocol",
                        title: "Final research protocol with analysis plan",
                        kind: .markdown,
                        status: .pendingGeneration,
                        role: .lesson
                    ),
                ]
            ),
        ]
        return value
    }

    var body: some View {
        if strictLaunchScenario != nil {
            strictRecoveryCheckpointRoot
        } else {
            legacyDraftRecoveryFixture
        }
    }

    private var strictRecoveryCheckpointRoot: some View {
        Group {
            if let scenario = strictLaunchScenario {
                CourseRecoveryCheckpointUITestHarnessView(scenario: scenario)
            } else {
                CourseRecoveryCheckpointConfigurationErrorView()
            }
        }
        .learnfoldStrictHarnessBoundary(.courseRecovery)
    }

    private var legacyDraftRecoveryFixture: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("Plan ready for review · Revision 1 · Not approved")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("courseDraftRecoveryHarness.status")

                    CourseBriefCard(
                        brief: brief,
                        agentName: "Codex",
                        isAgentWorking: false,
                        isApprovalEnabled: false,
                        buildAction: {}
                    )

                    CourseAgentErrorCard(
                        agentName: "Codex",
                        message: "Message not sent. Your message and sources are restored below—edit them or try again.",
                        needsAuthentication: false,
                        isConnecting: false,
                        showsReconnectAction: false,
                        blockingAction: .none,
                        abandonMode: .chooseWorkspaceDisposition,
                        allowsWorkspaceDeletion: false,
                        allowsUnknownSubmissionAbandon: false,
                        submissionRecoveryState: .knownNotAccepted,
                        hermesRecoveryProvenance: nil,
                        onReconnect: {},
                        onRetrySubmission: {
                            retryResult = "Retry requested with restored message and 1 source."
                        },
                        onCheckStatus: {},
                        onDiscardSubmission: {
                            inputText = ""
                            sources = []
                        },
                        onAbandonUnknownSubmission: {},
                        onRetryRecovery: {},
                        onAbandonRecovery: { _ in },
                        onStartNewDiscussion: {},
                        onDismiss: {}
                    )
                    .accessibilityIdentifier("courseDraftRecoveryHarness.error")
                }
                .padding(16)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(retryResult ?? "Retry has not been requested.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(retryResult == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
                    .accessibilityIdentifier("courseDraftRecoveryHarness.retryResult")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                CourseChatComposer(
                    inputText: $inputText,
                    prompt: "Message your course agent",
                    sources: sources,
                    isFocused: $composerFocused,
                    onRemoveSource: { source in
                        sources.removeAll(where: { $0.id == source.id })
                    },
                    onSend: {},
                    isAgentWorking: false,
                    isPreparing: false,
                    isEditingEnabled: true,
                    isAgentReady: true,
                    isStopping: false,
                    onStop: {},
                    supportsBinarySources: true,
                    selectedPhoto: .constant(nil),
                    onChooseFile: {},
                    onPasteLink: {}
                )
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Course Draft")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            (UIApplication.shared.delegate as? AppDelegate)?.signalContentReady()
        }
    }
}

private struct CourseRecoveryCheckpointConfigurationErrorView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Recovery checkpoint not configured", systemImage: "wrench.adjustable")
        } description: {
            Text("Add exactly one documented LF-34, LF-35, LF-36, or LF-53 scenario argument.")
        }
        .accessibilityIdentifier("courseRecoveryCheckpoint.configurationError")
    }
}

private struct CourseRecoveryCheckpointUITestHarnessView: View {
    let scenario: CourseRecoveryCheckpointUITestScenario

    private static let fixtureSource = CourseSource(
        id: UUID(uuidString: "1F340000-0000-4000-8000-000000000001")!,
        name: "recovery-fixture-notes.pdf",
        detail: "LOCAL FIXTURE",
        kind: .document
    )

    @State private var fixtureState: CourseRecoveryCheckpointFixtureState
    @FocusState private var composerFocused: Bool

    init(scenario: CourseRecoveryCheckpointUITestScenario) {
        self.scenario = scenario
        _fixtureState = State(
            initialValue: CourseRecoveryCheckpointFixtureState(scenario: scenario)
        )
    }

    private var sources: [CourseSource] {
        guard fixtureState.sourceCount > 0 else { return [] }
        return [Self.fixtureSource]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    checkpointHeader
                    checkpointStateSummary
                    checkpointContent
                }
                .padding(16)
            }
            .accessibilityIdentifier("courseRecoveryCheckpoint.scroll")
            .safeAreaInset(edge: .top, spacing: 0) {
                actionResultBanner
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if scenario.issueID == "LF-34" {
                    CourseChatComposer(
                        inputText: $fixtureState.draftText,
                        prompt: "Message your course agent",
                        sources: sources,
                        isFocused: $composerFocused,
                        onRemoveSource: { _ in fixtureState.sourceCount = 0 },
                        onSend: { fixtureState.apply(.retrySubmission) },
                        isAgentWorking: false,
                        isPreparing: false,
                        isEditingEnabled: scenario.submissionRecoveryState?.blocksNewSubmission != true,
                        isAgentReady: scenario.submissionRecoveryState?.blocksNewSubmission != true,
                        isStopping: false,
                        onStop: {},
                        supportsBinarySources: true,
                        selectedPhoto: .constant(nil),
                        onChooseFile: {},
                        onPasteLink: {}
                    )
                }
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Recovery Checkpoint")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var checkpointHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "\(scenario.markerKind.rawValue) · \(scenario.issueID) · NO LIVE BACKEND",
                systemImage: scenario.markerKind == .fixture
                    ? "hammer.circle.fill"
                    : "exclamationmark.octagon.fill"
            )
            .font(.caption.weight(.bold))
            .foregroundStyle(scenario.markerKind == .fixture ? Color.blue : Color.red)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(scenario.markerKind.rawValue) · \(scenario.issueID) · NO LIVE BACKEND"
            )
            .accessibilityIdentifier("courseRecoveryCheckpoint.fixtureMarker")
            .accessibilityValue(scenario.markerKind.rawValue)

            Text(scenario.title)
                .font(.title2.bold())
                .accessibilityIdentifier(scenario.accessibilityIdentifier)

            Text(scenario.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("courseRecoveryCheckpoint.stateDetail")

            Text("Scenario argument: \(scenario.rawValue)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("courseRecoveryCheckpoint.scenarioArgument")

            Text("Deterministic local checkpoint. No server, agent runtime, thread, journal, keychain, network, or learner workspace is read or changed.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("courseRecoveryCheckpoint.evidenceBoundary")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("courseRecoveryCheckpoint.header")
    }

    private var checkpointStateSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Preserved local state", systemImage: "externaldrive.badge.checkmark")
                .font(.subheadline.weight(.semibold))

            Text(fixtureState.draftText.isEmpty ? "Draft empty" : "Draft preserved")
                .accessibilityIdentifier("courseRecoveryCheckpoint.draftDisposition")
            Text("Attached sources: \(fixtureState.sourceCount)")
                .accessibilityIdentifier("courseRecoveryCheckpoint.sourceCount")
            Text(fixtureState.workspaceDisposition.rawValue)
                .accessibilityIdentifier("courseRecoveryCheckpoint.workspaceDisposition")
            Text(fixtureState.discussionDisposition.rawValue)
                .accessibilityIdentifier("courseRecoveryCheckpoint.discussionDisposition")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("courseRecoveryCheckpoint.localState")
    }

    @ViewBuilder
    private var checkpointContent: some View {
        if scenario.usesConflictFixture {
            CourseSelectionConflictCheckpointView(
                scenario: scenario,
                fixtureState: $fixtureState
            )
        } else if let recoveryPresentation = checkpointRecoveryPresentation,
                  let progressState = CourseHermesRecoveryProgressPolicy.progressState(
                      for: recoveryPresentation.provenance.journalState
                  ) {
            CourseHermesRecoveryProgressView(
                agentID: "hermes",
                provenance: recoveryPresentation.provenance,
                progressState: progressState,
                allowsWorkspaceDeletion: scenario == .lf35Recovering,
                onStopRecovery: { preserveWorkspace in
                    fixtureState.apply(
                        preserveWorkspace ? .keepWorkspace : .deleteDraftWorkspace
                    )
                }
            )
        } else {
            recoveryErrorCard
        }
    }

    private var actionResultBanner: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(fixtureState.lastAction?.rawValue ?? "none")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("courseRecoveryCheckpoint.lastAction")
            Text(fixtureState.actionResultText)
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("courseRecoveryCheckpoint.actionResult")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var recoveryErrorCard: some View {
        CourseAgentErrorCard(
            agentName: agentName,
            message: errorMessage,
            needsAuthentication: scenario == .lf36AuthenticationRecovery,
            isConnecting: false,
            showsReconnectAction: scenario == .lf36TransportRecovery,
            blockingAction: CourseAgentErrorActionPolicy.blockingAction(
                recoveryActions: checkpointRecoveryActions,
                hasMissingBoundThread: scenario == .lf35MissingDiscussion,
                abandonMode: checkpointAbandonMode
            ),
            abandonMode: checkpointAbandonMode,
            allowsWorkspaceDeletion: scenario == .lf35Confirmation,
            allowsUnknownSubmissionAbandon: scenario == .lf34AcceptanceUnknown,
            submissionRecoveryState: scenario.submissionRecoveryState,
            hermesRecoveryProvenance: checkpointRecoveryPresentation?.provenance,
            onReconnect: {
                fixtureState.apply(
                    scenario == .lf36AuthenticationRecovery
                        ? .signIn
                        : .reconnectTransport
                )
            },
            onRetrySubmission: { fixtureState.apply(.retrySubmission) },
            onCheckStatus: { fixtureState.apply(.checkSubmissionStatus) },
            onDiscardSubmission: { fixtureState.apply(.discardDraft) },
            onAbandonUnknownSubmission: { fixtureState.apply(.abandonUnknownDraft) },
            onRetryRecovery: { fixtureState.apply(.retryHermesRecovery) },
            onAbandonRecovery: { preserveWorkspace in
                let action: CourseRecoveryCheckpointAction
                if preserveWorkspace {
                    action = .keepWorkspace
                } else if checkpointAbandonMode == .finishDraftDeletion {
                    action = .finishDraftDeletion
                } else {
                    action = .deleteDraftWorkspace
                }
                fixtureState.apply(action)
            },
            onStartNewDiscussion: {
                fixtureState.apply(.startReplacementDiscussion)
            },
            onDismiss: { fixtureState.apply(.dismiss) },
            allowsDismissal: checkpointRecoveryActions.isEmpty,
            initialConfirmation: initialErrorConfirmation
        )
        .accessibilityIdentifier("courseRecoveryCheckpoint.errorCard")
    }

    private var agentName: String {
        scenario.issueID == "LF-35" ? "Hermes" : "Codex"
    }

    private var checkpointRecoveryActions: Set<CourseHermesRecoveryAction> {
        switch scenario {
        case .lf35Recovering:
            CourseHermesRecoveryProgressPolicy.availableActions(for: .acceptedTurn)
        case .lf35RecoveryFailure, .lf35Confirmation, .lf35FinishDeletion:
            CourseHermesRecoveryProgressPolicy.availableActions(for: .terminalFailure)
        case .lf35UnreadableEvidence:
            CourseHermesRecoveryProgressPolicy.availableActions(for: .unreadableEvidence)
        case .lf35Provenance:
            CourseHermesRecoveryProgressPolicy.availableActions(for: .resultSubmitting)
        default:
            []
        }
    }

    private var checkpointAbandonMode: CourseHermesRecoveryAbandonMode {
        checkpointRecoveryPresentation?.abandonMode
            ?? .chooseWorkspaceDisposition
    }

    private var checkpointRecoveryPresentation: CourseHermesRecoveryPresentation? {
        let journalState: CourseHermesRecoveryProvenance.JournalState
        let abandonMode: CourseHermesRecoveryAbandonMode
        switch scenario {
        case .lf35Recovering:
            journalState = .acceptedTurn
            abandonMode = .chooseWorkspaceDisposition
        case .lf35RecoveryFailure, .lf35Confirmation:
            journalState = .terminalFailure
            abandonMode = .chooseWorkspaceDisposition
        case .lf35UnreadableEvidence:
            journalState = .unreadableEvidence
            abandonMode = .chooseWorkspaceDisposition
        case .lf35Provenance:
            journalState = .resultSubmitting
            abandonMode = .chooseWorkspaceDisposition
        case .lf35FinishDeletion:
            journalState = .terminalFailure
            abandonMode = .finishDraftDeletion
        default:
            return nil
        }
        return CourseHermesRecoveryPresentation(
            provenance: CourseHermesRecoveryProvenance(
                workspaceID: "lf35-fixture-workspace",
                threadID: "lf35-fixture-thread",
                discussionKind: .course,
                journalState: journalState,
                toolName: journalState == .resultSubmitting
                    ? "learnfold_generate_lesson"
                    : nil
            ),
            abandonMode: abandonMode
        )
    }

    private var initialErrorConfirmation: CourseAgentErrorInitialConfirmation {
        switch scenario {
        case .lf34DestructiveConfirmation:
            .discardDraft
        case .lf35Confirmation:
            .abandonRecovery
        default:
            .none
        }
    }

    private var errorMessage: String {
        switch scenario {
        case .lf34Preparing:
            "Your message is saved locally. Sending has not started, so it is safe to edit or try again."
        case .lf34KnownNotAccepted, .lf34DestructiveConfirmation:
            "Message not sent. Your message and source are restored below—edit them or try again."
        case .lf34AcceptanceUnknown:
            "Learnfold cannot yet prove whether the agent received this message. Check its status before sending it again."
        case .lf34AcceptedReplyIncomplete:
            "The agent accepted this message, but the reply did not finish loading. Check its status before continuing."
        case .lf35MissingDiscussion:
            "This discussion’s saved thread no longer exists. The annotation and recovery metadata remain preserved."
        case .lf35Recovering:
            "Hermes work for this course needs attention. Retry recovery from the preserved journal or explicitly abandon it."
        case .lf35RecoveryFailure, .lf35Confirmation:
            CourseHermesRecoveryProgressPolicy.blockingErrorMessage(
                for: .terminalFailure
            ) ?? scenario.detail
        case .lf35UnreadableEvidence:
            CourseHermesRecoveryProgressPolicy.blockingErrorMessage(
                for: .unreadableEvidence
            ) ?? scenario.detail
        case .lf35Provenance:
            "Hermes recovery evidence is preserved with the restored local draft and its original workspace identity."
        case .lf35FinishDeletion:
            CourseHermesRecoveryProgressPolicy.blockingErrorMessage(
                for: .terminalFailure,
                abandonMode: .finishDraftDeletion
            ) ?? scenario.detail
        case .lf36AuthenticationRecovery:
            "Your Codex session expired. Sign in again to continue; the course and local draft are preserved."
        case .lf36TransportRecovery:
            "The selected agent transport disconnected. Reconnect to continue; the course and local draft are preserved."
        case .lf53ConflictDialog, .lf53ContinueExisting,
             .lf53CloseAndStartNew, .lf53Cancel, .lf53ReplacementFailure:
            scenario.detail
        }
    }
}

private struct CourseSelectionConflictCheckpointView: View {
    let scenario: CourseRecoveryCheckpointUITestScenario
    @Binding var fixtureState: CourseRecoveryCheckpointFixtureState

    @State private var chatError: String?
    @State private var conflict: CourseSelectionDiscussionConflict?
    @State private var actionHandledForPresentation = false

    init(
        scenario: CourseRecoveryCheckpointUITestScenario,
        fixtureState: Binding<CourseRecoveryCheckpointFixtureState>
    ) {
        self.scenario = scenario
        _fixtureState = fixtureState
        _conflict = State(initialValue: Self.makeConflict())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Passage discussion", systemImage: "text.bubble.fill")
                .font(.subheadline.weight(.semibold))
            Text("Selected passage: “A durable explanation should preserve the learner’s notes.”")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("courseRecoveryCheckpoint.conflict.selection")
            Text("Existing agent: Hermes · Selected agent: Codex")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("courseRecoveryCheckpoint.conflict.agents")
            Text(fixtureState.discussionDisposition.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("courseRecoveryCheckpoint.conflict.disposition")

            Button("Show Agent Conflict") {
                actionHandledForPresentation = false
                conflict = Self.makeConflict()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("courseRecoveryCheckpoint.conflict.show")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("courseRecoveryCheckpoint.conflictFixture")
        .courseSelectionDiscussionAlerts(
            chatError: $chatError,
            conflict: conflictDecisionBinding,
            onContinueExisting: { _ in
                actionHandledForPresentation = true
                fixtureState.apply(.continueExistingDiscussion)
            },
            onReplaceConflict: replaceConflict
        )
    }

    private var conflictDecisionBinding: Binding<CourseSelectionDiscussionConflict?> {
        Binding(
            get: { conflict },
            set: { nextConflict in
                let dismissedAnOpenConflict = conflict != nil && nextConflict == nil
                conflict = nextConflict
                if dismissedAnOpenConflict && !actionHandledForPresentation {
                    fixtureState.apply(.cancelConflict)
                }
            }
        )
    }

    private func replaceConflict() {
        actionHandledForPresentation = true
        conflict = nil
        if scenario == .lf53ReplacementFailure {
            fixtureState.apply(.replacementFailed)
            chatError = CourseSelectionDiscussionOpenError
                .replacementBlocked
                .errorDescription
        } else {
            fixtureState.apply(.startReplacementDiscussion)
        }
    }

    private static func makeConflict() -> CourseSelectionDiscussionConflict {
        guard let reference = CourseTextReference(
            id: UUID(uuidString: "5F530000-0000-4000-8000-000000000001")!,
            courseID: "recovery-fixture-course",
            pageID: "recovery-fixture-page",
            pageTitle: "Durable Explanations",
            blockID: "recovery-fixture-block",
            pathIndices: [1, 0],
            rangeLocation: 0,
            selectedText: "A durable explanation should preserve the learner’s notes."
        ) else {
            preconditionFailure("The fixed LF-53 selection fixture must be valid.")
        }
        let existing = CourseSelectionDiscussion(
            reference: reference,
            target: CourseAgentExecutionTarget(
                runtimeID: "hermes",
                serverID: "redacted-fixture-server",
                modelID: "redacted-fixture-model"
            ),
            id: UUID(uuidString: "5F530000-0000-4000-8000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return CourseSelectionDiscussionConflict(
            id: UUID(uuidString: "5F530000-0000-4000-8000-000000000003")!,
            existing: existing,
            reference: reference,
            selectedTarget: CourseAgentExecutionTarget(
                runtimeID: "codex",
                serverID: "redacted-fixture-server",
                modelID: "redacted-fixture-model"
            )
        )
    }
}
#endif
