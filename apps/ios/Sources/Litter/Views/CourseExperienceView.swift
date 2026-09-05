import NativeEditorMCP
import SwiftUI

#if DEBUG
enum ProviderSettingsSourceCheckpointScenario: String, CaseIterable, Hashable {
    static let launchArgument =
        "--ui-test-provider-settings-source-checkpoint"
    static let lf03HookIdentifier = "lf-03-fixture-hook"

    case lf03PickerAvailable = "--ui-test-lf03-picker-available"
    case lf03PickerUnavailable = "--ui-test-lf03-picker-unavailable"

    case lf05Saving = "--ui-test-lf05-saving"
    case lf05SuccessReturn = "--ui-test-lf05-success-return"
    case lf05Error = "--ui-test-lf05-error"

    case lf06Connecting = "--ui-test-lf06-connecting"
    case lf06ConnectedTarget = "--ui-test-lf06-connected-target"
    case lf06Failed = "--ui-test-lf06-failed"

    case lf27ModelLoading = "--ui-test-lf27-model-loading"
    case lf27ModelEmpty = "--ui-test-lf27-model-empty"
    case lf27ModelDefault = "--ui-test-lf27-model-default"
    case lf27ModelPopulated = "--ui-test-lf27-model-populated"
    case lf27Checking = "--ui-test-lf27-checking"
    case lf27Cancel = "--ui-test-lf27-cancel"
    case lf27FailureRollback = "--ui-test-lf27-failure-rollback"
    case lf27AgentError = "--ui-test-lf27-agent-error"

    case lf28Synced = "--ui-test-lf28-synced"
    case lf28OnThisDevice = "--ui-test-lf28-on-this-device"
    case lf28SignInRequired = "--ui-test-lf28-sign-in-required"
    case lf28NeedsAttention = "--ui-test-lf28-needs-attention"
    case lf28Retry = "--ui-test-lf28-retry"

    case lf30SourceMenu = "--ui-test-lf30-source-menu"
    case lf30Preparing = "--ui-test-lf30-preparing"
    case lf30PassageContext = "--ui-test-lf30-passage-context"
    case lf30PermissionError = "--ui-test-lf30-permission-error"
    case lf30ParseError = "--ui-test-lf30-parse-error"
    case lf30PreparationError = "--ui-test-lf30-preparation-error"

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Self? {
        guard arguments.filter({ $0 == launchArgument }).count == 1 else {
            return nil
        }
        let stateArguments = arguments.filter {
            $0.hasPrefix("--ui-test-lf")
        }
        guard stateArguments.count == 1,
              let scenario = Self(rawValue: stateArguments[0]) else {
            return nil
        }
        return scenario
    }

    var checkpointID: String {
        switch self {
        case .lf03PickerAvailable, .lf03PickerUnavailable:
            "LF-03"
        case .lf05Saving, .lf05SuccessReturn, .lf05Error:
            "LF-05"
        case .lf06Connecting, .lf06ConnectedTarget, .lf06Failed:
            "LF-06"
        case .lf27ModelLoading, .lf27ModelEmpty, .lf27ModelDefault,
             .lf27ModelPopulated, .lf27Checking, .lf27Cancel,
             .lf27FailureRollback, .lf27AgentError:
            "LF-27"
        case .lf28Synced, .lf28OnThisDevice, .lf28SignInRequired,
             .lf28NeedsAttention, .lf28Retry:
            "LF-28"
        case .lf30SourceMenu, .lf30Preparing, .lf30PassageContext,
             .lf30PermissionError, .lf30ParseError, .lf30PreparationError:
            "LF-30"
        }
    }

    var substate: String {
        switch self {
        case .lf03PickerAvailable: "picker-available"
        case .lf03PickerUnavailable: "picker-unavailable"
        case .lf05Saving: "saving"
        case .lf05SuccessReturn: "success-return"
        case .lf05Error: "error"
        case .lf06Connecting: "connecting"
        case .lf06ConnectedTarget: "connected-target"
        case .lf06Failed: "failed"
        case .lf27ModelLoading: "model-loading"
        case .lf27ModelEmpty: "model-empty"
        case .lf27ModelDefault: "model-default"
        case .lf27ModelPopulated: "model-populated"
        case .lf27Checking: "checking"
        case .lf27Cancel: "cancel"
        case .lf27FailureRollback: "failure-rollback"
        case .lf27AgentError: "agent-error"
        case .lf28Synced: "synced"
        case .lf28OnThisDevice: "on-this-device"
        case .lf28SignInRequired: "sign-in-required"
        case .lf28NeedsAttention: "needs-attention"
        case .lf28Retry: "retry"
        case .lf30SourceMenu: "source-menu"
        case .lf30Preparing: "preparing"
        case .lf30PassageContext: "passage-context"
        case .lf30PermissionError: "permission-error"
        case .lf30ParseError: "parse-error"
        case .lf30PreparationError: "preparation-error"
        }
    }

    var nonLiveBoundary: String {
        switch checkpointID {
        case "LF-03":
            "NON-LIVE PICKER FIXTURE · LIVE-FROZEN PRODUCT COMPANION STILL REQUIRED"
        case "LF-05", "LF-06":
            "NON-LIVE COMPONENT CHECKPOINT · LIVE-CONTROLLED EVIDENCE STILL REQUIRED"
        case "LF-28":
            "NON-LIVE FIXTURE · USE ONLY WHEN LIVE ACCOUNT STATE IS UNAVAILABLE"
        default:
            "NON-LIVE FAULT CHECKPOINT · LIVE-PRODUCT COMPANION STILL REQUIRED"
        }
    }

    var isSourceCheckpoint: Bool {
        checkpointID == "LF-30"
    }

    var deterministicHookIdentifier: String? {
        checkpointID == "LF-03" ? Self.lf03HookIdentifier : nil
    }
}

enum CourseGenerationCheckpointScenario: String, CaseIterable, Hashable {
    static let lf39Route = "--ui-test-lf-39-fixture-hook"
    static let lf40Route = "--ui-test-lf-40-fault-hook"
    static let lf44Route = "--ui-test-lf-44-fault-hook"

    case lf39Milestone1 = "--ui-test-lf39-milestone-1"
    case lf39Milestone2 = "--ui-test-lf39-milestone-2"
    case lf39Milestone3 = "--ui-test-lf39-milestone-3"
    case lf39Milestone4 = "--ui-test-lf39-milestone-4"
    case lf39Milestone5 = "--ui-test-lf39-milestone-5"
    case lf40GenerationError = "--ui-test-lf40-generation-error"
    case lf40ReturnedAgent = "--ui-test-lf40-returned-agent"
    case lf44Pending = "--ui-test-lf44-pending"
    case lf44Generating = "--ui-test-lf44-generating"
    case lf44PartialGenerated = "--ui-test-lf44-partial-generated"
    case lf44Error = "--ui-test-lf44-error"

    var route: String {
        switch self {
        case .lf39Milestone1, .lf39Milestone2, .lf39Milestone3,
             .lf39Milestone4, .lf39Milestone5:
            Self.lf39Route
        case .lf40GenerationError, .lf40ReturnedAgent:
            Self.lf40Route
        case .lf44Pending, .lf44Generating, .lf44PartialGenerated,
             .lf44Error:
            Self.lf44Route
        }
    }

    var checkpointID: String {
        switch self {
        case .lf39Milestone1, .lf39Milestone2, .lf39Milestone3,
             .lf39Milestone4, .lf39Milestone5:
            "LF-39"
        case .lf40GenerationError, .lf40ReturnedAgent:
            "LF-40"
        case .lf44Pending, .lf44Generating, .lf44PartialGenerated,
             .lf44Error:
            "LF-44"
        }
    }

    var substate: String {
        switch self {
        case .lf39Milestone1: "milestone-1"
        case .lf39Milestone2: "milestone-2"
        case .lf39Milestone3: "milestone-3"
        case .lf39Milestone4: "milestone-4"
        case .lf39Milestone5: "milestone-5"
        case .lf40GenerationError: "generation-error"
        case .lf40ReturnedAgent: "returned-agent"
        case .lf44Pending: "pending"
        case .lf44Generating: "generating"
        case .lf44PartialGenerated: "partial-generated"
        case .lf44Error: "error"
        }
    }

    var hookIdentifier: String {
        switch self {
        case .lf39Milestone1, .lf39Milestone2, .lf39Milestone3,
             .lf39Milestone4, .lf39Milestone5:
            "lf-39-fixture-hook"
        case .lf40GenerationError, .lf40ReturnedAgent:
            "lf-40-fault-hook"
        case .lf44Pending, .lf44Generating, .lf44PartialGenerated,
             .lf44Error:
            "lf-44-fault-hook"
        }
    }

    var nonLiveBoundary: String {
        switch checkpointID {
        case "LF-39":
            "NON-LIVE TRANSIENT CHECKPOINT · LIVE AI INFERENCE PROOF STILL REQUIRED"
        case "LF-44":
            "NON-LIVE GENERATION CHECKPOINT · LIVE AI COMPANION STILL REQUIRED"
        default:
            "NON-LIVE FAULT CHECKPOINT · DOES NOT PROVE A LIVE AGENT RETURN"
        }
    }
}

/// Debug-only controls for capturing the genuine LF-05 save lifecycle in the
/// live product. These do not select a fixture root: the user still navigates
/// the real setup sheet, enters valid settings, and presses its real Save
/// button. The saving control only lengthens the existing in-flight state; the
/// error control fails immediately before any credential or endpoint write.
enum LF05LiveAcceptanceControl: String, CaseIterable, Hashable {
    static let launchArgument = "--lf-05-live-acceptance-hook"

    case saving = "--lf-05-live-saving"
    case error = "--lf-05-live-error"

    static let savingDelayNanoseconds: UInt64 = 15_000_000_000
    static let forcedErrorDescription =
        "Controlled acceptance failure before provider settings were changed."

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Self? {
        guard arguments.filter({ $0 == launchArgument }).count == 1 else {
            return nil
        }
        let hookArguments = arguments.filter {
            $0.hasPrefix("--lf-05-live-") && $0 != launchArgument
        }
        let matches = arguments.compactMap(Self.init(rawValue:))
        guard matches.count == 1, hookArguments.count == 1 else { return nil }
        return matches[0]
    }
}

private struct LF05LiveAcceptanceError: LocalizedError {
    var errorDescription: String? {
        LF05LiveAcceptanceControl.forcedErrorDescription
    }
}

/// Debug-only controls for observing the genuine LF-06 setup connection
/// lifecycle. The connecting mode only lengthens the real in-flight state;
/// the failed mode returns through the real picker without persisting a
/// provider selection or marking setup complete.
enum LF06LiveAcceptanceControl: String, CaseIterable, Hashable {
    static let launchArgument = "--lf-06-live-acceptance-hook"

    case connecting = "--lf-06-live-connecting"
    case failed = "--lf-06-live-failed"

    static let connectingDelayNanoseconds: UInt64 = 15_000_000_000
    static let forcedFailureDescription =
        "Controlled acceptance failure before course-agent setup was changed."

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Self? {
        guard arguments.filter({ $0 == launchArgument }).count == 1 else {
            return nil
        }
        let hookArguments = arguments.filter {
            $0.hasPrefix("--lf-06-live-") && $0 != launchArgument
        }
        let matches = arguments.compactMap(Self.init(rawValue:))
        guard matches.count == 1, hookArguments.count == 1 else { return nil }
        return matches[0]
    }
}
#endif

enum CourseRouteUnavailableKind: String, Equatable {
    case course
    case page
    case file
}

enum CourseRouteRecoveryTarget: Equatable {
    case library
    case courseStructure
}

struct CourseRouteRecoveryAction: Equatable {
    let title: String
    let accessibilityIdentifier: String
    let target: CourseRouteRecoveryTarget
}

struct CourseRouteUnavailableContent: Equatable {
    let title: String
    let description: String
    let systemImage: String
    let primaryAction: CourseRouteRecoveryAction
    let secondaryAction: CourseRouteRecoveryAction?
}

enum CourseRouteFallbackPolicy {
    static func unavailableKind(
        for route: CourseRoute,
        courseExists: Bool,
        childExists: Bool? = nil
    ) -> CourseRouteUnavailableKind? {
        switch route {
        case .course:
            return courseExists ? nil : .course
        case .coursePage:
            guard courseExists else { return .course }
            return childExists == false ? .page : nil
        case .courseFile:
            guard courseExists else { return .course }
            return childExists == false ? .file : nil
        case .newCourse, .building:
            return nil
        }
    }

    static func content(
        for kind: CourseRouteUnavailableKind,
        courseTitle: String?,
        canOpenCourseStructure: Bool
    ) -> CourseRouteUnavailableContent {
        let library = CourseRouteRecoveryAction(
            title: "Return to Course Library",
            accessibilityIdentifier: "course-route-return-to-library",
            target: .library
        )
        let structure = CourseRouteRecoveryAction(
            title: "Open Course Structure",
            accessibilityIdentifier: "course-route-open-course-structure",
            target: .courseStructure
        )
        let resolvedTitle = courseTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let courseName = if let resolvedTitle, !resolvedTitle.isEmpty {
            resolvedTitle
        } else {
            "this course"
        }

        switch kind {
        case .course:
            return CourseRouteUnavailableContent(
                title: "Course unavailable",
                description: "This course is no longer available on this device. Return to your course library to continue.",
                systemImage: "book.closed",
                primaryAction: library,
                secondaryAction: nil
            )
        case .page:
            return CourseRouteUnavailableContent(
                title: "Page unavailable",
                description: canOpenCourseStructure
                    ? "This page is no longer available in \(courseName). Open the course structure to choose an available page."
                    : "This page is no longer available in \(courseName). Return to your course library to continue.",
                systemImage: "doc.questionmark",
                primaryAction: canOpenCourseStructure ? structure : library,
                secondaryAction: canOpenCourseStructure ? library : nil
            )
        case .file:
            return CourseRouteUnavailableContent(
                title: "File unavailable",
                description: canOpenCourseStructure
                    ? "This file is no longer available in \(courseName). Open the course structure to choose an available file."
                    : "This file is no longer available in \(courseName). Return to your course library to continue.",
                systemImage: "doc.questionmark",
                primaryAction: canOpenCourseStructure ? structure : library,
                secondaryAction: canOpenCourseStructure ? library : nil
            )
        }
    }

    static func pageIsUnavailable(after error: Error) -> Bool {
        guard let editorError = error as? NativeEditorMCPError else { return false }
        if case .pageNotFound = editorError { return true }
        return false
    }

    static func fileIsUnavailable(after error: Error) -> Bool {
        guard let workspaceError = error as? CourseWorkspaceError else { return false }
        switch workspaceError {
        case .unavailable, .invalidRelativePath, .fileNotFound:
            return true
        case .fileTooLarge, .unreadableText:
            return false
        }
    }
}

struct CourseRouteUnavailableView: View {
    let kind: CourseRouteUnavailableKind
    let courseTitle: String?
    let canOpenCourseStructure: Bool
    let onOpenCourseStructure: (() -> Void)?
    let onReturnToLibrary: () -> Void

    private var content: CourseRouteUnavailableContent {
        CourseRouteFallbackPolicy.content(
            for: kind,
            courseTitle: courseTitle,
            canOpenCourseStructure: canOpenCourseStructure
        )
    }

    var body: some View {
        ContentUnavailableView {
            Label(content.title, systemImage: content.systemImage)
                .accessibilityIdentifier("course-route-unavailable-title")
        } description: {
            Text(content.description)
                .accessibilityIdentifier("course-route-unavailable-description")
        } actions: {
            Button(content.primaryAction.title) {
                perform(content.primaryAction.target)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(content.primaryAction.title)
            .accessibilityIdentifier(content.primaryAction.accessibilityIdentifier)

            if let secondaryAction = content.secondaryAction {
                Button(secondaryAction.title) {
                    perform(secondaryAction.target)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(secondaryAction.title)
                .accessibilityIdentifier(secondaryAction.accessibilityIdentifier)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        // Keep the unavailable-route marker separate from its recovery
        // actions so their stable button identifiers survive in raw AX.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-route-unavailable-\(kind.rawValue)")
    }

    private func perform(_ target: CourseRouteRecoveryTarget) {
        switch target {
        case .library:
            onReturnToLibrary()
        case .courseStructure:
            onOpenCourseStructure?()
        }
    }
}

struct CourseExperienceRootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Bindable var store: CourseExperienceStore
    var onConnectRemoteAgent: () -> Void

    var body: some View {
        courseExperience
        .preferredColorScheme(.light)
        .task {
            store.installDocumentToolRouterIfNeeded(appModel: appModel)
            await store.recoverReadyCourses()
            if store.setupComplete, store.connectionState != .connected {
                await store.connectLocalAgent(appModel: appModel, agentID: store.selectedAgentID ?? "codex")
            }
        }
    }

    @ViewBuilder
    private var courseExperience: some View {
        Group {
            if !store.hasCompletedIntro {
                LearnfoldIntroView {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        store.completeIntro()
                    }
                }
                .transition(.opacity)
            } else if store.setupComplete {
                NavigationStack(path: $store.navigationPath) {
                    CourseHomeView(
                        store: store,
                        onConnectRemoteAgent: onConnectRemoteAgent
                    )
                    .navigationDestination(for: CourseRoute.self) { route in
                        CourseRouteDestinationView(route: route, store: store)
                    }
                }
                .tint(.blue)
            } else {
                CourseAgentSetupView(
                    store: store,
                    onConnectRemoteAgent: onConnectRemoteAgent
                )
            }
        }
    }
}

struct CourseRouteDestinationView: View {
    let route: CourseRoute
    @Bindable var store: CourseExperienceStore
    @State private var recoveredCourse: LearningCourse?

    var body: some View {
        Group {
            if let recoveredCourse {
                CourseDetailView(
                    course: recoveredCourse,
                    store: store,
                    initialSection: .structure
                )
            } else {
                routeDestination
            }
        }
    }

    @ViewBuilder
    private var routeDestination: some View {
        switch route {
        case .newCourse:
            CourseChatView(store: store)
                .id(store.draftWorkspaceID(for: nil))
        case .building:
            CourseBuildingView(store: store)
        case .course(let courseID):
            if let course = store.course(withID: courseID) {
                CourseDetailView(course: course, store: store)
            } else {
                missingCourseView
            }
        case .courseFile(let courseID, let relativePath):
            if let course = store.course(withID: courseID),
               let rootURL = store.courseDirectory(for: course) {
                CourseFileViewerView(
                    course: course,
                    relativePath: relativePath,
                    rootURL: rootURL,
                    store: store,
                    onOpenRelativePath: { linkedPath in
                        store.openCourseFile(courseID: courseID, relativePath: linkedPath)
                    },
                    onOpenCourseStructure: { recoveredCourse = course },
                    onReturnToLibrary: returnToLibrary
                )
            } else if let course = store.course(withID: courseID) {
                unavailableView(kind: .file, course: course)
            } else {
                missingCourseView
            }
        case .coursePage(let courseID, let pageID):
            if let course = store.course(withID: courseID), course.workspaceID != nil {
                CoursePageRouteView(
                    course: course,
                    pageID: pageID,
                    store: store,
                    onOpenCourseStructure: { recoveredCourse = course },
                    onReturnToLibrary: returnToLibrary
                )
            } else if let course = store.course(withID: courseID) {
                unavailableView(kind: .page, course: course)
            } else {
                missingCourseView
            }
        }
    }

    private var missingCourseView: some View {
        unavailableView(
            kind: CourseRouteFallbackPolicy.unavailableKind(
                for: route,
                courseExists: false
            ) ?? .course,
            course: nil
        )
    }

    private func unavailableView(
        kind: CourseRouteUnavailableKind,
        course: LearningCourse?
    ) -> some View {
        CourseRouteUnavailableView(
            kind: kind,
            courseTitle: course?.title,
            canOpenCourseStructure: course?.workspaceID != nil,
            onOpenCourseStructure: course.map { course in
                { recoveredCourse = course }
            },
            onReturnToLibrary: returnToLibrary
        )
    }

    private func returnToLibrary() {
        store.navigationPath.removeAll()
    }
}

private struct CoursePageRouteCheckID: Hashable {
    let courseID: String
    let workspaceID: String?
    let pageID: String
}

private struct CoursePageRouteView: View {
    private enum Availability {
        case checking
        case available
        case unavailable
    }

    let course: LearningCourse
    let pageID: String
    @Bindable var store: CourseExperienceStore
    let onOpenCourseStructure: () -> Void
    let onReturnToLibrary: () -> Void
    @State private var availability: Availability = .checking

    private var checkID: CoursePageRouteCheckID {
        CoursePageRouteCheckID(
            courseID: course.id,
            workspaceID: course.workspaceID,
            pageID: pageID
        )
    }

    var body: some View {
        Group {
            switch availability {
            case .checking:
                ProgressView("Checking course page…")
                    .accessibilityIdentifier("course-route-page-checking")
            case .available:
                CoursePageEditorView(course: course, pageID: pageID, store: store)
            case .unavailable:
                CourseRouteUnavailableView(
                    kind: .page,
                    courseTitle: course.title,
                    canOpenCourseStructure: true,
                    onOpenCourseStructure: onOpenCourseStructure,
                    onReturnToLibrary: onReturnToLibrary
                )
            }
        }
        .task(id: checkID) {
            await checkPageAvailability()
        }
    }

    private func checkPageAvailability() async {
        availability = .checking
        do {
            let repository = try await store.documentRepository(for: course)
            _ = try await repository.pageSnapshot(id: pageID)
            guard !Task.isCancelled else { return }
            availability = .available
        } catch {
            guard !Task.isCancelled else { return }
            availability = CourseRouteFallbackPolicy.pageIsUnavailable(after: error)
                ? .unavailable
                : .available
        }
    }
}

#if DEBUG
enum CourseRouteFallbackUITestScenario: String, CaseIterable {
    case missingCourse = "missing-course"
    case missingCoursePage = "missing-course-page"
    case missingCourseFile = "missing-course-file"
    case stalePage = "stale-page"
    case staleFile = "stale-file"

    static let argument = "--ui-test-course-route-fallback"
    static let validCourseID = "ui-route-recovery-course"
    static let workspaceID = "ui-route-recovery-workspace"

    var route: CourseRoute {
        switch self {
        case .missingCourse:
            .course("missing-course")
        case .missingCoursePage:
            .coursePage(courseID: "missing-course", pageID: "missing-page")
        case .missingCourseFile:
            .courseFile(courseID: "missing-course", relativePath: "missing-file.md")
        case .stalePage:
            .coursePage(courseID: Self.validCourseID, pageID: "stale-page")
        case .staleFile:
            .courseFile(courseID: Self.validCourseID, relativePath: "assets/stale-file.md")
        }
    }

    var hasExistingCourse: Bool {
        switch self {
        case .missingCourse, .missingCoursePage, .missingCourseFile:
            false
        case .stalePage, .staleFile:
            true
        }
    }
}

@MainActor
struct CourseRouteFallbackStrictCheckpointRoot: View {
    private enum Destination {
        case unavailable
        case library
        case courseStructure
    }

    let scenario: CourseRouteFallbackUITestScenario
    @State private var destination: Destination = .unavailable

    init(scenario: CourseRouteFallbackUITestScenario) {
        self.scenario = scenario
    }

    var body: some View {
        NavigationStack {
            destinationView
        }
        .tint(.blue)
        .preferredColorScheme(.light)
        .accessibilityIdentifier(
            "course-route-fallback-checkpoint-\(scenario.rawValue)"
        )
        .learnfoldStrictHarnessBoundary(.courseRouteFallback)
    }

    @ViewBuilder
    private var destinationView: some View {
        switch destination {
        case .unavailable:
            CourseRouteUnavailableView(
                kind: unavailableKind,
                courseTitle: scenario.hasExistingCourse ? Self.course.title : nil,
                canOpenCourseStructure: scenario.hasExistingCourse,
                onOpenCourseStructure: scenario.hasExistingCourse
                    ? { destination = .courseStructure }
                    : nil,
                onReturnToLibrary: { destination = .library }
            )
        case .library:
            CourseLibraryContent(
                courses: [Self.course],
                selectedAgentID: "codex",
                resumableDraft: nil,
                onOpenAppSettings: {},
                onOpenAgentSettings: {},
                onOpenCourse: { _ in },
                onResumeDraft: {},
                onNewCourse: {}
            )
            .navigationBarHidden(true)
        case .courseStructure:
            CourseDetailPresentation(
                course: Self.course,
                selectedSection: .constant(.structure),
                onTalkToCourseAgent: {},
                learnSection: { EmptyView() },
                structureSection: {
                    CourseDetailStructurePresentation(
                        structureError: nil,
                        documentOutline: Self.documentOutline,
                        workspaceSnapshot: nil,
                        onRetry: {},
                        onOpenPage: { _ in },
                        onOpenFile: { _ in }
                    )
                }
            )
        }
    }

    private var unavailableKind: CourseRouteUnavailableKind {
        CourseRouteFallbackPolicy.unavailableKind(
            for: scenario.route,
            courseExists: scenario.hasExistingCourse,
            childExists: false
        ) ?? .course
    }

    private static let course = LearningCourse(
        id: CourseRouteFallbackUITestScenario.validCourseID,
        title: "Route Recovery Course",
        subtitle: "Deterministic route recovery fixture",
        accentHex: "1F6FEB",
        progress: 0.5,
        lessonCount: 1,
        duration: "5 min",
        status: .ready,
        workspaceID: CourseRouteFallbackUITestScenario.workspaceID
    )

    private static let documentOutline: CourseDocumentOutline = {
        let lesson = CourseLearningNode(
            id: "route-recovery-lesson",
            title: "Choose a recovery destination",
            kind: .markdown,
            status: .generated,
            role: .lesson,
            pageID: "route-recovery-lesson"
        )
        let chapter = CourseLearningNode(
            id: "route-recovery-section",
            title: "Route Recovery",
            kind: .folder,
            status: .generated,
            role: .chapter,
            children: [lesson]
        )
        return CourseDocumentOutline(
            rootPageID: "route-recovery-root",
            bootstrapStatus: "ready_for_learning",
            allPages: [chapter],
            learningPages: [chapter]
        )
    }()
}
#endif

private struct CourseAgentCustomProviderButton: View {
    let hasCustomEndpoint: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        hasCustomEndpoint
                            ? "Custom provider connected"
                            : "Use an OpenAI-compatible provider"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    Text(
                        hasCustomEndpoint
                            ? "Change endpoint, key, or model"
                            : "Add a base URL, API key, and model ID"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.07))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("course-agent-custom-provider")
        .accessibilityValue(hasCustomEndpoint ? "connected" : "not-configured")
    }
}

private struct CourseAgentSetupConnectionControls: View {
    let agentID: String
    let connectionState: CourseExperienceStore.AgentConnectionState
    let isAgentAvailable: Bool
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onConnect) {
                HStack(spacing: 10) {
                    if connectionState == .connecting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "iphone.and.arrow.forward")
                    }
                    Text(
                        connectionState == .connecting
                            ? "Connecting…"
                            : agentID == CourseAgentProvider.hosted ? "Continue" : "Connect \(agentID.displayLabel)"
                    )
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(.white)
                .background(.blue, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("course-agent-connect")
            .disabled(connectionState == .connecting || !isAgentAvailable)

            Label {
                Text(agentID == CourseAgentProvider.hosted
                    ? "No login needed during the beta. Your prompts are processed in the cloud. Daily usage limits apply."
                    : "You can change your course agent later in Course Settings.")
                    .accessibilityIdentifier("course-agent-connection-lifecycle")
                    .accessibilityValue(statusValue)
            } icon: {
                Image(systemName: "lock.shield")
            }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if case .failed(let message) = connectionState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("course-agent-connection-error")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusValue: String {
        switch connectionState {
        case .idle: "idle"
        case .connecting: "connecting"
        case .connected: "connected"
        case .failed: "failed"
        }
    }
}

private struct CourseAgentSetupPickerContent: View {
    let agentOptions: [CourseAgentOption]
    let showsUnavailableOptions: Bool
    @Binding var selectedAgentID: String
    let hasCustomEndpoint: Bool
    let onSelectAgent: (String) -> Void
    let onAddServer: () -> Void
    let onOpenCustomProvider: () -> Void
    @State private var showsAgentChoices = false

    private var usesHostedDefault: Bool {
        selectedAgentID == CourseAgentProvider.hosted
            && agentOptions.contains { $0.id == CourseAgentProvider.hosted && $0.available }
    }

    private var showsAllAgents: Bool { showsAgentChoices || !usesHostedDefault }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .indigo],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 78, height: 78)
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text(usesHostedDefault && !showsAgentChoices ? "Ready to start learning" : "Choose your course agent")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .tracking(-1.1)
                    .accessibilityIdentifier("course-agent-setup-picker")
                    .accessibilityValue(availabilityValue)

                Text(usesHostedDefault && !showsAgentChoices
                    ? "Your Hosted course agent is ready. Start with a topic, a question, or a link."
                    : "Choose the agent you'd like to use for your courses. You can change it later.")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                ForEach(visibleAgentOptions) { choice in
                    CourseAgentChoiceRow(
                        id: choice.id,
                        title: choice.title,
                        subtitle: choice.subtitle,
                        available: choice.available,
                        selected: selectedAgentID == choice.id,
                        onSelect: {
                            selectedAgentID = choice.id
                            onSelectAgent(choice.id)
                        }
                    )
                }
            }

            if !showsAllAgents {
                Button("Change agent") { showsAgentChoices = true }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("course-agent-change")
            }

            if showsAllAgents {
                Button(action: onAddServer) {
                    HStack(spacing: 14) {
                        Image(systemName: "server.rack")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.indigo)
                            .frame(width: 42, height: 42)
                            .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connect Hermes on a server")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Pair with Learnfold Link. Connecting authorizes Hermes to use phone-side tools confined to this course. The shell is read-only until plan approval, read-write afterward, and has no outbound network access.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.black.opacity(0.07))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("course-agent-add-server")
            }

            if selectedAgentID == CourseAgentProvider.codex {
                CourseAgentCustomProviderButton(
                    hasCustomEndpoint: hasCustomEndpoint,
                    action: onOpenCustomProvider
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var visibleAgentOptions: [CourseAgentOption] {
        if !showsAllAgents {
            return agentOptions.filter { $0.id == CourseAgentProvider.hosted }
        }
        return showsUnavailableOptions
            ? agentOptions
            : agentOptions.filter(\.available)
    }

    private var availabilityValue: String {
        let availableCount = visibleAgentOptions.filter(\.available).count
        let unavailableCount = visibleAgentOptions.count - availableCount
        return "available=\(availableCount),unavailable=\(unavailableCount)"
    }
}

struct CourseAgentSetupSelectionResolution: Equatable {
    let agentID: String
    let isAutomatic: Bool
}

enum CourseAgentSetupSelectionPolicy {
    static func initialSelection(
        savedAgentID: String?,
        options: [CourseAgentOption],
        preferredAgentID: String
    ) -> CourseAgentSetupSelectionResolution {
        if let savedAgentID,
           options.first(where: { $0.id == savedAgentID })?.available == true {
            return CourseAgentSetupSelectionResolution(
                agentID: savedAgentID,
                isAutomatic: false
            )
        }
        return CourseAgentSetupSelectionResolution(
            agentID: preferredAgentID,
            isAutomatic: true
        )
    }

    static func reconciledSelection(
        currentAgentID: String,
        automaticAgentIDBeforeRefresh: String?,
        hasExplicitUserSelection: Bool,
        preferredAgentID: String
    ) -> String {
        guard !hasExplicitUserSelection,
              currentAgentID == automaticAgentIDBeforeRefresh else {
            return currentAgentID
        }
        return preferredAgentID
    }
}

private struct CourseAgentSetupView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var store: CourseExperienceStore
    let onConnectRemoteAgent: () -> Void
    @State private var selectedAgent: String
    @State private var selectedModelID = ""
    @State private var showsOpenAICompatibleSetup = false
    @State private var hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
    @State private var hasExplicitUserSelection = false

    init(
        store: CourseExperienceStore,
        onConnectRemoteAgent: @escaping () -> Void
    ) {
        self.store = store
        self.onConnectRemoteAgent = onConnectRemoteAgent
        _selectedAgent = State(initialValue: store.preferredSetupAgentID)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    CourseAgentSetupPickerContent(
                        // Hermes is connected through the dedicated server CTA
                        // below, not selected as a local course agent here.
                        agentOptions: store.agentOptions.filter {
                            $0.id != "hermes"
                        },
                        showsUnavailableOptions: true,
                        selectedAgentID: $selectedAgent,
                        hasCustomEndpoint: hasCustomEndpoint,
                        onSelectAgent: { _ in
                            hasExplicitUserSelection = true
                        },
                        onAddServer: onConnectRemoteAgent,
                        onOpenCustomProvider: {
                            hasExplicitUserSelection = true
                            showsOpenAICompatibleSetup = true
                        }
                    )

                    CourseAgentSetupConnectionControls(
                        agentID: selectedAgent,
                        connectionState: store.connectionState,
                        isAgentAvailable: store.agentOptions.first(where: {
                            $0.id == selectedAgent
                        })?.available == true,
                        onConnect: {
                            hasExplicitUserSelection = true
                            Task {
                                await store.connectLocalAgent(
                                    appModel: appModel,
                                    agentID: selectedAgent,
                                    modelID: selectedModelID.isEmpty ? nil : selectedModelID
                                )
                            }
                        }
                    )
                }
                .padding(.horizontal, 22)
                .padding(.top, 38)
                .padding(.bottom, 72)
            }
            .safeAreaPadding(.bottom, 16)
        }
        .task {
            // The Foundation Models availability seen during store construction
            // can be stale while the framework finishes initializing. Refresh it
            // before choosing the transient picker selection so the visible
            // default and its availability marker describe the same snapshot.
            store.refreshHostedAvailability()
            store.refreshAppleAvailability()
            selectedModelID = store.selectedModelID ?? ""
            let resolution = CourseAgentSetupSelectionPolicy.initialSelection(
                savedAgentID: store.selectedAgentID,
                options: store.agentOptions,
                preferredAgentID: store.preferredSetupAgentID
            )
            if !hasExplicitUserSelection {
                selectedAgent = resolution.agentID
            }
            let automaticAgentIDBeforeRefresh =
                resolution.isAutomatic && !hasExplicitUserSelection
                    ? selectedAgent
                    : nil
            if CourseAgentProvider.usesAppServer(selectedAgent) {
                await store.prepareLocalAgentCatalog(appModel: appModel)
                selectedAgent = CourseAgentSetupSelectionPolicy.reconciledSelection(
                    currentAgentID: selectedAgent,
                    automaticAgentIDBeforeRefresh: automaticAgentIDBeforeRefresh,
                    hasExplicitUserSelection: hasExplicitUserSelection,
                    preferredAgentID: store.preferredSetupAgentID
                )
            }
        }
        .onChange(of: selectedAgent) { _, agentID in
            guard CourseAgentProvider.usesAppServer(agentID) else { return }
            Task {
                await store.prepareLocalAgentCatalog(appModel: appModel)
            }
        }
        .onChange(of: store.selectedAgentID) { _, agentID in
            guard let agentID,
                  store.agentOptions.first(where: { $0.id == agentID })?.available == true else {
                return
            }
            selectedAgent = agentID
            selectedModelID = store.selectedModelID ?? ""
        }
        .sheet(isPresented: $showsOpenAICompatibleSetup) {
            OpenAICompatibleProviderSheet(initialModelID: selectedModelID) { modelID in
                selectedModelID = modelID
                hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
            }
            .environment(appModel)
        }
    }
}

private struct CourseHomeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Bindable var store: CourseExperienceStore
    var onConnectRemoteAgent: () -> Void
    @State private var showsCourseSettings = false
    @State private var showsAppSettings = false
    @State private var showsDraftReplacementConfirmation = false

    var body: some View {
        CourseLibraryContent(
            courses: store.courses,
            selectedAgentID: store.selectedAgentID ?? "codex",
            resumableDraft: store.resumableCourseDraft,
            onOpenAppSettings: { showsAppSettings = true },
            onOpenAgentSettings: { showsCourseSettings = true },
            onOpenCourse: { courseID in
                store.navigationPath.append(.course(courseID))
            },
            onResumeDraft: { store.resumeCourseDraft() },
            onNewCourse: requestNewCourse
        )
        .navigationBarHidden(true)
        .sheet(isPresented: $showsCourseSettings) {
            CourseAgentSettingsView(
                store: store,
                onConnectRemoteAgent: onConnectRemoteAgent
            )
                .environment(appModel)
        }
        .sheet(isPresented: $showsAppSettings) {
            SettingsView()
                .environment(appModel)
                .environment(appState)
        }
        .alert(
            "Start a new course?",
            isPresented: $showsDraftReplacementConfirmation
        ) {
            Button("Continue Draft") {
                store.resumeCourseDraft()
            }
            Button("Discard Draft and Start New", role: .destructive) {
                store.beginNewCourse()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "You already have an unfinished course conversation. Starting a new course will remove that workspace and anything saved in it."
            )
        }
    }

    private func requestNewCourse() {
        if store.requiresDraftReplacementConfirmation {
            showsDraftReplacementConfirmation = true
        } else {
            store.beginNewCourse()
        }
    }
}

private struct CourseLibraryContent: View {
    let courses: [LearningCourse]
    let selectedAgentID: String
    let resumableDraft: CourseDraftResumePresentation?
    let onOpenAppSettings: () -> Void
    let onOpenAgentSettings: () -> Void
    let onOpenCourse: (String) -> Void
    let onResumeDraft: () -> Void
    let onNewCourse: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .center) {
                        Text("My Courses")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .tracking(-1)
                            .accessibilityIdentifier("course-library-root")

                        Spacer()

                        HStack(spacing: 10) {
                            Button(action: onOpenAppSettings) {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(.blue)
                                    .frame(width: 46, height: 46)
                                    .background(.thinMaterial, in: Circle())
                                    .overlay(Circle().stroke(Color.black.opacity(0.07)))
                            }
                            .accessibilityLabel("App Settings")
                            .accessibilityIdentifier("course-home-app-settings")

                            Button(action: onOpenAgentSettings) {
                                ZStack {
                                    Circle().fill(.thinMaterial)
                                    AgentIconView(kind: selectedAgentID, size: 28)
                                }
                                .frame(width: 46, height: 46)
                                .overlay(Circle().stroke(Color.black.opacity(0.07)))
                            }
                            .accessibilityLabel("Course agent menu")
                            .accessibilityIdentifier("course-home-agent-settings")
                        }
                    }
                    .zIndex(10)

                    if let resumableDraft {
                        CourseDraftResumeCard(
                            presentation: resumableDraft,
                            onResume: onResumeDraft
                        )
                    }

                    if let featured = courses.first {
                        CourseFeaturedCard(course: featured) {
                            onOpenCourse(featured.id)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("All Courses")
                                    .font(.title3.weight(.bold))
                                Spacer()
                                Text("\(courses.count)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }

                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(Array(courses.dropFirst())) { course in
                                    CourseGridCard(course: course) {
                                        onOpenCourse(course.id)
                                    }
                                }
                            }
                        }
                    } else {
                        CourseLibraryEmptyState()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 112)
            }

            Button(action: onNewCourse) {
                Label("New Course", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 21)
                    .padding(.vertical, 15)
                    .foregroundStyle(.white)
                    .background(.blue, in: Capsule())
                    .shadow(color: .blue.opacity(0.25), radius: 18, y: 8)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 18)
            .padding(.bottom, 22)
            .accessibilityIdentifier("new-course-button")
        }
    }
}

private struct CourseDraftResumeCard: View {
    let presentation: CourseDraftResumePresentation
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.blue.opacity(0.12))
                    Image(
                        systemName: presentation.isAgentWorking
                            ? "ellipsis.message.fill"
                            : "bubble.left.and.text.bubble.right.fill"
                    )
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.blue)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue course draft")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let courseTitle = presentation.courseTitle {
                        Text(courseTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Text(presentation.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.blue.opacity(0.18))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("continue-course-draft-button")
        .accessibilityValue(presentation.isAgentWorking ? "agent-working" : "saved")
    }
}

private struct CourseLibraryEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 72, height: 72)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(spacing: 6) {
                Text("Your library is ready")
                    .font(.title3.weight(.bold))
                Text("Create a course with your agent. Only courses actually generated on this device will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 44)
        .background(.background, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.black.opacity(0.05))
        }
    }
}

struct CourseAgentSettingsDraft: Equatable {
    var agentID: String
    var modelID: String
    var effortID: String
}

enum CourseAgentSettingsDraftPolicy {
    static func afterSelection(
        proposed: CourseAgentSettingsDraft
    ) -> CourseAgentSettingsDraft {
        proposed
    }

    static func afterCatalogLoad(
        current: CourseAgentSettingsDraft,
        availableAgentIDs: Set<String>
    ) -> CourseAgentSettingsDraft {
        // An unavailable persisted provider is still the truthful saved value.
        // Never move the draft checkmark to an unvalidated fallback.
        current
    }

    static func afterSave(
        current: CourseAgentSettingsDraft,
        persisted: CourseAgentSettingsDraft,
        didSave: Bool
    ) -> CourseAgentSettingsDraft {
        didSave ? current : persisted
    }
}

private struct CourseCloudSyncStatusSection: View {
    let availability: CourseCloudSyncAvailability
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        Section {
            LabeledContent {
                if isRetrying {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Retrying…")
                    }
                } else {
                    Text(availability.label)
                        .foregroundStyle(availability.tint)
                }
            } label: {
                Label("Course iCloud Sync", systemImage: "icloud")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("course-cloud-sync-status")
            .accessibilityValue(isRetrying ? "retry" : availability.checkpointValue)

            if isRetrying {
                Text("Checking iCloud without changing local course data…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("course-cloud-sync-retrying")
            } else if availability.canRetry {
                Button("Retry iCloud Connection", action: onRetry)
                    .accessibilityIdentifier("course-cloud-sync-retry")
            }
        } footer: {
            Text(availability.explanation)
        }
    }
}

private struct CourseAgentModelSection: View {
    let agentID: String
    let models: [ModelInfo]
    let isLoading: Bool
    let selectedModel: String
    let onSelect: (ModelInfo) -> Void

    var body: some View {
        Section {
            if isLoading {
                HStack {
                    ProgressView()
                    Text("Loading models…").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("course-settings-model-loading")
            } else if models.isEmpty {
                Text("This agent will choose its default model.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("course-settings-model-empty")
            } else {
                ForEach(models, id: \.id) { model in
                    let isSelected = modelMatchesSelection(
                        model,
                        selectedModel,
                        runtime: agentID
                    )
                    Button {
                        onSelect(model)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(modelPickerDisplayName(model))
                                        .foregroundStyle(.primary)
                                    if model.isDefault {
                                        Text("DEFAULT")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.blue)
                                            .accessibilityIdentifier(
                                                "course-settings-model-default-badge-\(model.id)"
                                            )
                                    }
                                }
                                if !model.description.isEmpty {
                                    Text(model.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .accessibilityIdentifier("course-settings-model-\(model.id)")
                    .accessibilityValue(isSelected ? "selected" : "not-selected")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        } header: {
            Text("Model")
                .accessibilityIdentifier("course-settings-model-state")
                .accessibilityValue(checkpointValue)
        }
    }

    private var checkpointValue: String {
        if isLoading { return "model-loading" }
        if models.isEmpty { return "model-empty" }
        if models.count == 1, models[0].isDefault { return "model-default" }
        return "model-populated"
    }
}

private struct CourseAgentSettingsErrorSection: View {
    let message: String

    var body: some View {
        Section {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(message)
                    .accessibilityIdentifier("course-settings-agent-error")
            }
            .foregroundStyle(.red)
        }
    }
}

private struct CourseAgentSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CourseExperienceStore
    let onConnectRemoteAgent: () -> Void
    @State private var selectedAgent: String
    @State private var selectedModel: String
    @State private var selectedEffort: String
    @State private var showsOpenAICompatibleSetup = false
    @State private var hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
    @State private var cloudSyncAvailability: CourseCloudSyncAvailability = .missingEntitlement
    @State private var isRetryingCloudSync = false
    @State private var saveTask: Task<Void, Never>?

    init(
        store: CourseExperienceStore,
        onConnectRemoteAgent: @escaping () -> Void
    ) {
        self.store = store
        self.onConnectRemoteAgent = onConnectRemoteAgent
        _selectedAgent = State(initialValue: store.selectedAgentID ?? "codex")
        _selectedModel = State(initialValue: store.selectedModelID ?? "")
        _selectedEffort = State(initialValue: store.selectedReasoningEffortID ?? "")
    }

    private var models: [ModelInfo] {
        store.presentedModels(for: selectedAgent)
    }

    private var selectedModelInfo: ModelInfo? {
        models.first(where: { $0.id == selectedModel || $0.model == selectedModel })
    }

    private var connectedHermesServer: AppServerSnapshot? {
        let connectedServers = appModel.snapshot?.servers.filter { server in
            !server.isLocal
                && server.isConnected
                && server.agentRuntimes.contains {
                    $0.kind == "hermes" && $0.available
                }
        } ?? []
        if let selectedServerID = store.selectedAgentServerID,
           let selected = connectedServers.first(where: { $0.serverId == selectedServerID }) {
            return selected
        }
        return connectedServers.first
    }

    var body: some View {
        NavigationStack {
            Form {
                CourseCloudSyncStatusSection(
                    availability: cloudSyncAvailability,
                    isRetrying: isRetryingCloudSync,
                    onRetry: retryCloudSync
                )

                Section {
                    ForEach(store.agentOptions.filter(\.available)) { option in
                        Button {
                            selectAgent(option)
                        } label: {
                            HStack(spacing: 14) {
                                AgentIconView(kind: option.id, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).foregroundStyle(.primary)
                                    Text(option.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedAgent == option.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                                }
                            }
                        }
                        .disabled(store.connectionState == .connecting)
                        .accessibilityIdentifier("course-settings-agent-\(option.id)")
                    }
                } header: {
                    Text("Course agent")
                } footer: {
                    Text("Only agents currently available through this device or the selected server are shown.")
                }

                if CourseAgentProvider.usesAppServer(selectedAgent) {
                    CourseAgentModelSection(
                        agentID: selectedAgent,
                        models: models,
                        isLoading: store.isLoadingAgentCatalog,
                        selectedModel: selectedModel,
                        onSelect: { model in
                            selectedModel = model.id
                            selectedEffort = model.defaultReasoningEffort.wireValue
                        }
                    )
                }

                if let selectedModelInfo, !selectedModelInfo.supportedReasoningEfforts.isEmpty {
                    Section("Reasoning") {
                        Picker("Effort", selection: $selectedEffort) {
                            ForEach(selectedModelInfo.supportedReasoningEfforts) { option in
                                Text(option.reasoningEffort.wireValue.capitalized)
                                    .tag(option.reasoningEffort.wireValue)
                            }
                        }
                    }
                }

                if selectedAgent == "codex" {
                    Section {
                        Button {
                            showsOpenAICompatibleSetup = true
                        } label: {
                            HStack {
                                Label(
                                    hasCustomEndpoint ? "Manage custom provider" : "Add custom provider",
                                    systemImage: "point.3.connected.trianglepath.dotted"
                                )
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        if hasCustomEndpoint {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("OpenAI-compatible endpoint active")
                                    .font(.subheadline.weight(.semibold))
                                if !selectedModel.isEmpty {
                                    Text("New courses will request model “\(selectedModel)”.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Custom provider")
                    } footer: {
                        Text("Uses Learnfold’s existing local Codex runtime. Endpoint changes are app-wide and affect existing Codex conversations too.")
                    }
                }

                Section {
                    Text("This changes the default for new courses only. Existing courses stay with the agent that created their conversation, so a Hermes course continues with Hermes. An Apple course can switch between On‑Device and Private Cloud Compute from its chat.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if let connectedHermesServer {
                        LabeledContent {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Hermes")
                                Text(connectedHermesServer.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Button {
                            cancelSaveAndDismiss()
                            Task { @MainActor in
                                await Task.yield()
                                onConnectRemoteAgent()
                            }
                        } label: {
                            Label("Connect Hermes", systemImage: "server.rack")
                        }
                        .accessibilityIdentifier("course-settings-add-server")
                    }
                } header: {
                    Text("Remote agent")
                } footer: {
                    Text("Connecting Hermes authorizes it to use Learnfold’s phone-side course tools for your course turns. The shell is confined to the active course folder, read-only until you approve the course plan and read-write afterward. It cannot access sibling courses or make outbound network connections.")
                }

                if let error = store.agentError {
                    CourseAgentSettingsErrorSection(message: error)
                }
            }
            .task {
                cloudSyncAvailability = await CourseCloudSyncEngine.shared.availability
            }
            .navigationTitle("Course Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelSaveAndDismiss() }
                        .accessibilityIdentifier("course-settings-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.connectionState == .connecting ? "Checking…" : "Save") {
                        startSave()
                    }
                    .disabled(store.connectionState == .connecting || saveTask != nil)
                    .accessibilityIdentifier("course-settings-save")
                }
            }
            .task {
                await store.prepareLocalAgentCatalog(appModel: appModel)
                let availableOptions = store.agentOptions.filter(\.available)
                applyDraft(CourseAgentSettingsDraftPolicy.afterCatalogLoad(
                    current: currentDraft,
                    availableAgentIDs: Set(availableOptions.map(\.id))
                ))
                if availableOptions.contains(where: { $0.id == selectedAgent }),
                   selectedModel.isEmpty {
                    selectedModel = store.presentedDefaultModelID(for: selectedAgent) ?? ""
                }
                hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
            }
            .sheet(isPresented: $showsOpenAICompatibleSetup) {
                OpenAICompatibleProviderSheet(initialModelID: selectedModel) { modelID in
                    selectedModel = modelID
                    selectedEffort = ""
                    hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
                }
                .environment(appModel)
            }
            .interactiveDismissDisabled(saveTask != nil)
            .onDisappear {
                saveTask?.cancel()
                saveTask = nil
            }
        }
    }

    @MainActor
    private func retryCloudSync() {
        guard !isRetryingCloudSync else { return }
        isRetryingCloudSync = true
        Task { @MainActor in
            await CourseCloudSyncEngine.shared.startIfAvailable()
            cloudSyncAvailability = await CourseCloudSyncEngine.shared.availability
            isRetryingCloudSync = false
        }
    }

    @MainActor
    private func startSave() {
        guard saveTask == nil else { return }
        let draft = currentDraft
        saveTask = Task { @MainActor in
            let didSave = await store.connectLocalAgent(
                appModel: appModel,
                agentID: draft.agentID,
                modelID: draft.modelID.isEmpty ? nil : draft.modelID,
                reasoningEffortID: draft.effortID.isEmpty ? nil : draft.effortID
            )
            guard !Task.isCancelled else { return }
            saveTask = nil
            if didSave {
                dismiss()
            } else {
                restoreDraftFromPersistedSelection()
            }
        }
    }

    @MainActor
    private func cancelSaveAndDismiss() {
        saveTask?.cancel()
        saveTask = nil
        dismiss()
    }

    private func selectAgent(_ option: CourseAgentOption) {
        let optionModels = store.presentedModels(for: option.id)
        let defaultModel = optionModels.first(where: \.isDefault) ?? optionModels.first
        let proposed = CourseAgentSettingsDraft(
            agentID: option.id,
            modelID: defaultModel?.id ?? "",
            effortID: defaultModel?.defaultReasoningEffort.wireValue ?? ""
        )
        applyDraft(CourseAgentSettingsDraftPolicy.afterSelection(proposed: proposed))
    }

    @MainActor
    private func restoreDraftFromPersistedSelection() {
        applyDraft(CourseAgentSettingsDraftPolicy.afterSave(
            current: currentDraft,
            persisted: CourseAgentSettingsDraft(
                agentID: store.selectedAgentID ?? "codex",
                modelID: store.selectedModelID ?? "",
                effortID: store.selectedReasoningEffortID ?? ""
            ),
            didSave: false
        ))
    }

    private var currentDraft: CourseAgentSettingsDraft {
        CourseAgentSettingsDraft(
            agentID: selectedAgent,
            modelID: selectedModel,
            effortID: selectedEffort
        )
    }

    private func applyDraft(_ draft: CourseAgentSettingsDraft) {
        selectedAgent = draft.agentID
        selectedModel = draft.modelID
        selectedEffort = draft.effortID
    }
}

private extension CourseCloudSyncAvailability {
    var checkpointValue: String {
        switch self {
        case .available: "synced"
        case .missingEntitlement: "on-this-device"
        case .noAccount: "sign-in-required"
        case .failed: "needs-attention"
        }
    }

    var label: String {
        switch self {
        case .available: "Synced"
        case .missingEntitlement: "On This Device"
        case .noAccount: "Sign In Required"
        case .failed: "Needs Attention"
        }
    }

    var explanation: String {
        switch self {
        case .available:
            "Generated courses and later edits are synced through your private iCloud database."
        case .missingEntitlement:
            "Courses remain on this device because the Learnfold iCloud container is not enabled in this build."
        case .noAccount:
            "Sign in to iCloud in Settings to sync generated courses."
        case .failed(let message):
            "Course sync paused without changing local data. \(message)"
        }
    }

    var tint: Color {
        switch self {
        case .available: .green
        case .missingEntitlement: .secondary
        case .noAccount, .failed: .orange
        }
    }

    var canRetry: Bool {
        switch self {
        case .noAccount, .failed: true
        case .available, .missingEntitlement: false
        }
    }
}

private struct OpenAICompatibleProviderForm: View {
    @Binding var baseURL: String
    @Binding var apiKey: String
    @Binding var modelID: String
    let hasStoredKey: Bool
    let hasStoredBaseURL: Bool
    let isSaving: Bool
    let errorMessage: String?
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    let onClearCustomEndpoint: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://provider.example/v1", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("custom-provider-base-url")

                    SecureField(
                        hasStoredKey
                            ? "API key saved — enter to replace"
                            : "API key",
                        text: $apiKey
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("custom-provider-api-key")

                    TextField("Model ID, for example gpt-oss-120b", text: $modelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("custom-provider-model-id")
                } header: {
                    Text("Connection")
                        .accessibilityIdentifier("custom-provider-form")
                        .accessibilityValue(
                            isSaving ? "saving" : (errorMessage == nil ? "ready" : "error")
                        )
                } footer: {
                    Text("The API key and base URL are stored securely on this iPhone. The model ID is sent exactly as entered.")
                }

                Section {
                    Label("Runs through the on-device Codex agent", systemImage: "iphone.gen3")
                    Label("Course files remain in the app’s local workspace", systemImage: "folder.badge.gearshape")
                    Label("Prompts and selected source content go to your endpoint", systemImage: "arrow.up.forward.app")
                } header: {
                    Text("How it works")
                } footer: {
                    Text("Compatibility requires the OpenAI Responses API, streaming, and tool calling. A chat-completions-only endpoint may not work with Codex. Changing this endpoint restarts local Codex and affects existing Codex conversations too.")
                }

                if isSaving {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Saving provider settings…")
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Saving provider settings…")
                        .accessibilityIdentifier("custom-provider-saving")
                    }
                }

                if hasStoredBaseURL {
                    Section {
                        Button(
                            "Use Default OpenAI Endpoint",
                            role: .destructive,
                            action: onClearCustomEndpoint
                        )
                        .disabled(isSaving)
                        .accessibilityIdentifier("custom-provider-use-default")
                    }
                }

                if let errorMessage {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .accessibilityHidden(true)
                            Text(errorMessage)
                                .accessibilityIdentifier("custom-provider-error")
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Custom Provider")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                        .accessibilityIdentifier("custom-provider-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save", action: onSave)
                        .disabled(!canSave || isSaving)
                        .accessibilityIdentifier("custom-provider-save")
                }
            }
        }
    }
}

private struct OpenAICompatibleProviderSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let onSaved: (String) -> Void

    @State private var baseURL: String
    @State private var apiKey = ""
    @State private var modelID: String
    @State private var hasStoredKey = OpenAIApiKeyStore.shared.hasStoredKey
    @State private var hasStoredBaseURL = OpenAIApiKeyStore.shared.hasStoredBaseURL
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(initialModelID: String, onSaved: @escaping (String) -> Void) {
        self.onSaved = onSaved
        _baseURL = State(initialValue: (try? OpenAIApiKeyStore.shared.loadBaseURL()) ?? "")
        _modelID = State(initialValue: initialModelID)
    }

    var body: some View {
        OpenAICompatibleProviderForm(
            baseURL: $baseURL,
            apiKey: $apiKey,
            modelID: $modelID,
            hasStoredKey: hasStoredKey,
            hasStoredBaseURL: hasStoredBaseURL,
            isSaving: isSaving,
            errorMessage: errorMessage,
            canSave: canSave,
            onCancel: { dismiss() },
            onSave: { Task { await save() } },
            onClearCustomEndpoint: {
                Task { await clearCustomEndpoint() }
            }
        )
    }

    private var canSave: Bool {
        OpenAICompatibleProviderConfiguration.normalizedBaseURL(baseURL) != nil
            && OpenAICompatibleProviderConfiguration.normalizedModelID(modelID) != nil
            && (hasStoredKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @MainActor
    private func save() async {
        guard let normalizedBaseURL = OpenAICompatibleProviderConfiguration.normalizedBaseURL(baseURL),
              let normalizedModelID = OpenAICompatibleProviderConfiguration.normalizedModelID(modelID) else {
            errorMessage = "Enter a valid http or https base URL and a model ID."
            return
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasStoredKey || !trimmedKey.isEmpty else {
            errorMessage = "Enter an API key. For a local endpoint that ignores authentication, use the placeholder key it recommends."
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            errorMessage = nil
            #if DEBUG
            switch LF05LiveAcceptanceControl.current() {
            case .saving:
                try await Task.sleep(
                    nanoseconds: LF05LiveAcceptanceControl
                        .savingDelayNanoseconds
                )
            case .error:
                throw LF05LiveAcceptanceError()
            case nil:
                break
            }
            #endif
            if !trimmedKey.isEmpty {
                try OpenAIApiKeyStore.shared.save(trimmedKey)
            }
            try OpenAIApiKeyStore.shared.saveBaseURL(normalizedBaseURL)
            try await appModel.restartLocalServer()
            hasStoredKey = OpenAIApiKeyStore.shared.hasStoredKey
            hasStoredBaseURL = OpenAIApiKeyStore.shared.hasStoredBaseURL
            onSaved(normalizedModelID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func clearCustomEndpoint() async {
        isSaving = true
        defer { isSaving = false }
        do {
            errorMessage = nil
            try OpenAIApiKeyStore.shared.clearBaseURL()
            try await appModel.restartLocalServer()
            hasStoredBaseURL = false
            onSaved("")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CourseFeaturedCard: View {
    let course: LearningCourse
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                CourseArtwork(
                    course: course,
                    symbolAlignment: .topTrailing,
                    symbolPadding: 24
                )
                    .frame(height: 236)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.88)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("CONTINUE LEARNING")
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.72))
                    Text(course.title)
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(spacing: 10) {
                        ProgressView(value: course.progress)
                            .tint(.white)
                            .frame(maxWidth: 130)
                        Text("\(Int(course.progress * 100))%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Image(systemName: "play.fill")
                            .font(.headline)
                            .foregroundStyle(.blue)
                            .frame(width: 46, height: 46)
                            .background(.white, in: Circle())
                    }
                }
                .padding(19)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 236)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
    }
}

private struct CourseGridCard: View {
    let course: LearningCourse
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                CourseArtwork(course: course)
                    .frame(maxWidth: .infinity)
                    .frame(height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(course.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(course.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.stack")
                        Text("\(course.lessonCount)")
                        Text("·")
                        Text(course.duration)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.black.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }
}

private struct CourseArtwork: View {
    let title: String
    let accentHex: String
    let symbolAlignment: Alignment
    let symbolPadding: CGFloat

    init(
        course: LearningCourse,
        symbolAlignment: Alignment = .center,
        symbolPadding: CGFloat = 0
    ) {
        title = course.title
        accentHex = course.accentHex
        self.symbolAlignment = symbolAlignment
        self.symbolPadding = symbolPadding
    }

    init(
        title: String,
        accentHex: String,
        symbolAlignment: Alignment = .center,
        symbolPadding: CGFloat = 0
    ) {
        self.title = title
        self.accentHex = accentHex
        self.symbolAlignment = symbolAlignment
        self.symbolPadding = symbolPadding
    }

    var body: some View {
        let accent = Color(hex: accentHex)
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.72), accent, .black.opacity(0.86)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 190, height: 190)
                .blur(radius: 2)
                .offset(x: 95, y: -60)

            Circle()
                .stroke(.white.opacity(0.2), lineWidth: 1)
                .frame(width: 118, height: 118)
                .offset(x: 82, y: -45)

        }
        .overlay(alignment: symbolAlignment) {
            Image(systemName: "book.pages.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                .padding(symbolPadding)
        }
        .accessibilityHidden(true)
    }
}

private enum CourseDetailSection: String, CaseIterable, Identifiable {
    case learn = "Learn"
    case structure = "Structure"

    var id: String { rawValue }
}

private enum CourseDetailLayout {
    static let stickyActionScrollClearance: CGFloat = 132
}

private struct CourseDetailPresentation<LearnSection: View, StructureSection: View>: View {
    let course: LearningCourse
    @Binding private var selectedSection: CourseDetailSection
    let onTalkToCourseAgent: () -> Void
    private let learnSection: LearnSection
    private let structureSection: StructureSection

    init(
        course: LearningCourse,
        selectedSection: Binding<CourseDetailSection>,
        onTalkToCourseAgent: @escaping () -> Void,
        @ViewBuilder learnSection: () -> LearnSection,
        @ViewBuilder structureSection: () -> StructureSection
    ) {
        self.course = course
        _selectedSection = selectedSection
        self.onTalkToCourseAgent = onTalkToCourseAgent
        self.learnSection = learnSection()
        self.structureSection = structureSection()
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    courseHeader

                    if course.workspaceID != nil {
                        Picker("Course view", selection: $selectedSection) {
                            ForEach(CourseDetailSection.allCases) { section in
                                Text(section.rawValue).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(4)
                        .background(.thinMaterial, in: Capsule())
                        .accessibilityIdentifier("course-detail-section-picker")
                        .accessibilityValue(selectedSection.rawValue)
                    }

                    switch selectedSection {
                    case .learn:
                        learnSection
                    case .structure:
                        structureSection
                    }

                    if course.workspaceID != nil {
                        Color.clear
                            .frame(height: CourseDetailLayout.stickyActionScrollClearance)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 32)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if course.workspaceID != nil {
                bottomActionBar
            }
        }
        .navigationTitle("Course")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("course-detail-root")
    }

    private var courseHeader: some View {
        HStack(spacing: 16) {
            CourseArtwork(course: course)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(course.title)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .lineLimit(2)
                Text(course.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Label(
                    course.status == .ready ? "Ready to learn" : "In progress",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(CourseCompletionLabelStyle())
            }

            Spacer(minLength: 0)
        }
    }

    private var bottomActionBar: some View {
        Button(action: onTalkToCourseAgent) {
            Label("Talk to Course Agent", systemImage: "bubble.left.and.bubble.right.fill")
                .font(.headline)
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("talk-to-course-agent-button")
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

private struct CourseDetailStructurePresentation: View {
    let structureError: String?
    let documentOutline: CourseDocumentOutline?
    let workspaceSnapshot: CourseWorkspaceSnapshot?
    let onRetry: () -> Void
    let onOpenPage: (String) -> Void
    let onOpenFile: (CourseFileNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let structureError {
                CourseStructureLoadFailureView(
                    error: structureError,
                    onRetry: onRetry
                )
            }

            if let documentOutline {
                CoursePageStructureBrowser(
                    nodes: documentOutline.allPages,
                    onOpenPage: onOpenPage
                )
            }

            if let workspaceSnapshot,
               workspaceSnapshot.nodes.contains(where: {
                   $0.relativePath == "sources" || $0.relativePath == "assets"
               }) {
                if documentOutline != nil {
                    Divider()
                }
                CourseStructureBrowser(
                    snapshot: workspaceSnapshot,
                    recommendedFilePath: nil,
                    onOpenFile: onOpenFile
                )
            }

            if documentOutline == nil, workspaceSnapshot == nil, structureError == nil {
                ProgressView("Reading course structure…")
                    .accessibilityIdentifier("course-structure-loading")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 64)
            }
        }
    }
}

private struct CourseDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    let course: LearningCourse
    @Bindable var store: CourseExperienceStore

    @State private var selectedSection: CourseDetailSection
    @State private var workspaceSnapshot: CourseWorkspaceSnapshot?
    @State private var documentOutline: CourseDocumentOutline?
    @State private var structureErrors = CourseStructureReloadErrors()
    @State private var structureReloadGeneration = 0
    @State private var expandedLearningNodeIDs: Set<String> = []
    @State private var courseAgentNavigationError: String?

    init(
        course: LearningCourse,
        store: CourseExperienceStore,
        initialSection: CourseDetailSection = .learn
    ) {
        self.course = course
        self.store = store
        _selectedSection = State(initialValue: initialSection)
    }

    private var chapters: [CourseChapter] {
        if let loaded = store.courseBrief(for: course) {
            return loaded.chapters
        }
        return [
            CourseChapter(id: "visual-map", title: "A visual map of the idea", objective: "See the complete idea first.", deliverables: []),
            CourseChapter(id: "core-intuition", title: "Build the core intuition", objective: "Understand the central concept.", deliverables: []),
            CourseChapter(id: "worked-example", title: "Follow one worked example", objective: "Make the idea concrete.", deliverables: []),
            CourseChapter(id: "practice", title: "Try it yourself", objective: "Practice independently.", deliverables: []),
            CourseChapter(id: "review", title: "Review and extend", objective: "Consolidate and continue.", deliverables: []),
        ]
    }

    private var learningNodes: [CourseLearningNode] {
        let resolved: [CourseLearningNode]
        if let documentOutline, !documentOutline.learningPages.isEmpty {
            resolved = documentOutline.learningPages
        } else if let loaded = store.courseBrief(for: course) {
            resolved = CourseLearningPathResolver.resolve(brief: loaded, snapshot: workspaceSnapshot)
        } else {
            resolved = chapters.map {
                CourseLearningNode(
                    id: $0.id,
                    title: $0.title,
                    kind: .folder,
                    status: .pendingGeneration
                )
            }
        }
        let activeNodeID = store.backgroundGeneratingCourseID == course.id
            ? store.backgroundGeneratingNodeID
            : nil
        return CourseLearningPathResolver.overlayGeneratingStatus(
            in: resolved,
            targetNodeID: activeNodeID
        )
    }

    private var isBackgroundGenerationActive: Bool {
        store.backgroundGeneratingCourseID == course.id && store.backgroundGeneratingNodeID != nil
    }

    private var structureReloadID: CourseStructureReloadID {
        CourseStructureReloadID(
            courseID: course.id,
            workspaceID: course.workspaceID,
            workspaceVersion: store.courseWorkspaceRefreshVersion,
            retryGeneration: structureReloadGeneration
        )
    }

    private var structureError: String? {
        structureErrors.combinedMessage
    }

    var body: some View {
        CourseDetailPresentation(
            course: course,
            selectedSection: $selectedSection,
            onTalkToCourseAgent: resumeCourseAgent,
            learnSection: { learnSection },
            structureSection: { structureSection }
        )
        .task(id: structureReloadID) {
            await reloadCourseStructure(requestID: structureReloadID)
        }
        .task(id: store.backgroundGeneratingNodeID) {
            guard isBackgroundGenerationActive else { return }
            while !Task.isCancelled, isBackgroundGenerationActive {
                refreshWorkspace()
                try? await Task.sleep(for: .milliseconds(500))
            }
            refreshWorkspace()
        }
        .alert(
            "Couldn’t Open Course Agent",
            isPresented: Binding(
                get: { courseAgentNavigationError != nil },
                set: { isPresented in
                    if !isPresented {
                        courseAgentNavigationError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                courseAgentNavigationError = nil
            }
        } message: {
            Text(courseAgentNavigationError ?? "The course agent is unavailable right now.")
        }
    }

    private var learnSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Learning path")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.headline)
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(.blue.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Learn at your own pace")
                        .font(.subheadline.weight(.semibold))
                    Text("Open any ready module. Generate a pending section when you want to continue, and your agent will adapt it to your progress.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            CourseLearningTreeView(
                nodes: learningNodes,
                expandedNodeIDs: $expandedLearningNodeIDs,
                generationDisabled: store.isCourseNodeGenerationDisabled,
                runtimeID: course.agentRuntimeKind ?? CourseAgentProvider.codex,
                onOpenMarkdown: { pageID in
                    store.openCoursePage(courseID: course.id, pageID: pageID)
                },
                onGenerate: { node in
                    store.generateCourseNodeInBackground(
                        for: course,
                        node: node,
                        appModel: appModel,
                        appState: appState
                    )
                }
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            if store.backgroundGenerationErrorCourseID == course.id,
               let error = store.backgroundGenerationError {
                CourseNodeGenerationErrorView(
                    error: error,
                    onOpenCourseAgent: resumeCourseAgent
                )
            }
        }
        .onAppear(perform: expandInitialLearningNode)
    }

    @ViewBuilder
    private var structureSection: some View {
        CourseDetailStructurePresentation(
            structureError: structureError,
            documentOutline: documentOutline,
            workspaceSnapshot: workspaceSnapshot,
            onRetry: {
                structureErrors = CourseStructureReloadErrors()
                structureReloadGeneration &+= 1
            },
            onOpenPage: { pageID in
                store.openCoursePage(courseID: course.id, pageID: pageID)
            },
            onOpenFile: { node in
                store.openCourseFile(courseID: course.id, relativePath: node.relativePath)
            }
        )
    }

    private func resumeCourseAgent() {
        courseAgentNavigationError = nil
        if case .blocked(let message) = store.resumeCourseAgent(for: course) {
            courseAgentNavigationError = message
        }
    }

    private func loadWorkspaceFiles() -> CourseStructureLoadResult<CourseWorkspaceSnapshot> {
        guard let rootURL = store.courseDirectory(for: course) else {
            return .failed(CourseWorkspaceError.unavailable.localizedDescription)
        }
        do {
            return .loaded(try CourseWorkspaceSnapshot.load(from: rootURL))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func loadDocumentPages() async -> CourseStructureLoadResult<CourseDocumentOutline> {
        do {
            let repository = try await store.documentRepository(for: course)
            return .loaded(try await repository.outline())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func reloadCourseStructure(requestID: CourseStructureReloadID) async {
        guard !Task.isCancelled, requestID == structureReloadID else { return }
        workspaceSnapshot = nil
        documentOutline = nil
        structureErrors = CourseStructureReloadErrors()
        let result = await CourseStructureReloadCoordinator.reload(
            loadWorkspaceFiles: { loadWorkspaceFiles() },
            loadDocumentPages: { await loadDocumentPages() }
        )
        guard !Task.isCancelled, requestID == structureReloadID else { return }
        workspaceSnapshot = result.workspaceFiles.value
        documentOutline = result.documentPages.value
        structureErrors = result.errors
    }

    private func refreshWorkspace() {
        let result = loadWorkspaceFiles()
        workspaceSnapshot = result.value
        structureErrors.workspaceFiles = result.errorMessage
    }

    private func expandInitialLearningNode() {
        guard expandedLearningNodeIDs.isEmpty,
              let firstReadyFolder = learningNodes.first(where: {
                  $0.kind == .folder && !$0.children.isEmpty && $0.status != .pendingGeneration
              }) else { return }
        expandedLearningNodeIDs.insert(firstReadyFolder.id)
    }
}

struct CourseStructureReloadID: Hashable {
    let courseID: String
    let workspaceID: String?
    let workspaceVersion: Int
    let retryGeneration: Int
}

enum CourseStructureLoadResult<Value: Sendable>: Sendable {
    case loaded(Value)
    case failed(String)

    var value: Value? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }

    var errorMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

struct CourseStructureReloadErrors: Equatable, Sendable {
    var workspaceFiles: String?
    var documentPages: String?

    var combinedMessage: String? {
        let messages = [
            workspaceFiles.map { "Source files: \($0)" },
            documentPages.map { "Course pages: \($0)" },
        ].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}

struct CourseStructureReloadResult<WorkspaceFiles: Sendable, DocumentPages: Sendable>: Sendable {
    let workspaceFiles: CourseStructureLoadResult<WorkspaceFiles>
    let documentPages: CourseStructureLoadResult<DocumentPages>

    var errors: CourseStructureReloadErrors {
        CourseStructureReloadErrors(
            workspaceFiles: workspaceFiles.errorMessage,
            documentPages: documentPages.errorMessage
        )
    }
}

enum CourseStructureReloadCoordinator {
    @MainActor
    static func reload<WorkspaceFiles: Sendable, DocumentPages: Sendable>(
        loadWorkspaceFiles: @escaping @MainActor @Sendable () async -> CourseStructureLoadResult<WorkspaceFiles>,
        loadDocumentPages: @escaping @MainActor @Sendable () async -> CourseStructureLoadResult<DocumentPages>
    ) async -> CourseStructureReloadResult<WorkspaceFiles, DocumentPages> {
        async let workspaceFiles = loadWorkspaceFiles()
        async let documentPages = loadDocumentPages()
        return await CourseStructureReloadResult(
            workspaceFiles: workspaceFiles,
            documentPages: documentPages
        )
    }
}

struct CourseStructureLoadFailureView: View {
    let error: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                "Course structure unavailable",
                systemImage: "folder.badge.questionmark"
            )
        } description: {
            Text(error)
                .accessibilityIdentifier("course-structure-error-message")
        } actions: {
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("course-structure-retry")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

private struct CourseCompletionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(.blue)
            configuration.title
        }
    }
}

private struct CourseAgentChoiceRow: View {
    let id: String
    let title: String
    let subtitle: String
    let available: Bool
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button {
            guard available else { return }
            onSelect()
        } label: {
            HStack(spacing: 16) {
                AgentIconView(kind: id, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(available ? Color.primary : Color.secondary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                trailingStatus
            }
            .padding(16)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(selected ? Color.blue : Color.black.opacity(0.06), lineWidth: selected ? 2 : 1)
            }
            .opacity(available ? 1 : 0.78)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityIdentifier("course-agent-option-\(id)")
        .accessibilityValue(accessibilityState)
    }

    private var accessibilityState: String {
        guard available else { return "unavailable" }
        return selected ? "available-selected" : "available-not-selected"
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if available {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(selected ? Color.blue : Color.secondary.opacity(0.5))
        } else {
            Text("Later")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
        }
    }
}

private struct CourseLearningTreeView: View {
    let nodes: [CourseLearningNode]
    @Binding var expandedNodeIDs: Set<String>
    let generationDisabled: Bool
    let runtimeID: String
    let onOpenMarkdown: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                CourseLearningTreeNodeView(
                    node: node,
                    depth: 0,
                    ordinal: String(index + 1),
                    expandedNodeIDs: $expandedNodeIDs,
                    generationDisabled: generationDisabled,
                    runtimeID: runtimeID,
                    onOpenMarkdown: onOpenMarkdown,
                    onGenerate: onGenerate
                )
                if index < nodes.count - 1 {
                    Divider().padding(.leading, 46)
                }
            }
        }
        // Keep the structural marker as a container.  Applying its identifier
        // to an implicit, combined accessibility element would cause it to
        // replace the identifiers of the node controls it contains.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-learning-tree")
    }
}

private struct CourseLearningTreeNodeView: View {
    let node: CourseLearningNode
    let depth: Int
    let ordinal: String
    @Binding var expandedNodeIDs: Set<String>
    let generationDisabled: Bool
    let runtimeID: String
    let onOpenMarkdown: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void

    private var isExpanded: Bool {
        expandedNodeIDs.contains(node.id)
    }

    private var canExpand: Bool {
        node.kind == .folder && !node.children.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: primaryAction) {
                    HStack(spacing: 10) {
                        if node.kind == .folder {
                            Image(systemName: canExpand ? (isExpanded ? "chevron.down" : "chevron.right") : "folder.fill")
                                .font(canExpand ? .caption.weight(.bold) : .body)
                                .foregroundStyle(node.status == .pendingGeneration ? Color.secondary : Color.blue)
                                .frame(width: 24)

                            if canExpand {
                                Image(systemName: "folder.fill")
                                    .font(.body)
                                    .foregroundStyle(.blue)
                            }
                        } else {
                            Image(systemName: "doc.text.fill")
                                .font(.body)
                                .foregroundStyle(node.status == .generated ? Color.blue : Color.secondary)
                                .frame(width: 24)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.title)
                                .font(.system(size: depth == 0 ? 16 : 15, weight: depth == 0 ? .semibold : .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            if node.kind == .folder, !node.children.isEmpty {
                                Text("\(node.children.count) \(node.children.count == 1 ? "item" : "items")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(node.kind == .markdown && node.status != .generated)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier(
                    CourseLearningTreeAccessibilityPolicy.rowIdentifier(for: node)
                )
                .accessibilityLabel(
                    CourseLearningTreeAccessibilityPolicy.rowLabel(
                        for: node,
                        ordinal: ordinal
                    )
                )
                .accessibilityHint(primaryAccessibilityHint)
                .accessibilityValue(node.status.rawValue)

                trailingControl
            }
            .padding(.leading, CGFloat(depth) * 22 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, depth == 0 ? 13 : 11)
            .opacity(node.status == .pendingGeneration ? 0.82 : 1)

            if canExpand, isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                        CourseLearningTreeNodeView(
                            node: child,
                            depth: depth + 1,
                            ordinal: "\(ordinal).\(index + 1)",
                            expandedNodeIDs: $expandedNodeIDs,
                            generationDisabled: generationDisabled,
                            runtimeID: runtimeID,
                            onOpenMarkdown: onOpenMarkdown,
                            onGenerate: onGenerate
                        )
                        if index < node.children.count - 1 {
                            Divider().padding(.leading, CGFloat(depth + 2) * 22 + 34)
                        }
                    }
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.blue.opacity(0.16))
                        .frame(width: 2)
                        .padding(.leading, CGFloat(depth + 1) * 22 + 18)
                }
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch node.status {
        case .pendingGeneration:
            if let generationRequest = CourseExperienceStore.directGenerationRequest(
                for: node,
                runtimeID: runtimeID
            ) {
                Button(generationRequest.controlTitle) { onGenerate(node) }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(.blue, in: Capsule())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "generate-course-node-\(node.id)"
                    )
                    .accessibilityValue(
                        generationDisabled
                            ? "pending_generation-disabled"
                            : "pending_generation"
                    )
                    .accessibilityLabel(generationRequest.accessibilityLabel)
                    .accessibilityHint(
                        generationDisabled
                            ? "Wait for the current course agent request to finish."
                            : generationRequest.accessibilityHint
                    )
                    .disabled(generationDisabled)
                    .opacity(generationDisabled ? 0.45 : 1)
            } else {
                Text("Pending")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "course-node-generation-status-\(node.id)"
                    )
                    .accessibilityValue(node.status.rawValue)
            }
        case .generating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Generating")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Generating")
            .accessibilityIdentifier(
                "course-node-generation-status-\(node.id)"
            )
            .accessibilityValue(node.status.rawValue)
        case .partiallyGenerated:
            Text("In progress")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.1), in: Capsule())
                .accessibilityIdentifier(
                    "course-node-generation-status-\(node.id)"
                )
                .accessibilityValue(node.status.rawValue)
        case .generated:
            if node.kind == .markdown {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Open \(node.title)")
                    .accessibilityIdentifier(
                        "course-node-generation-status-\(node.id)"
                    )
                    .accessibilityValue(node.status.rawValue)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Generated")
                    .accessibilityIdentifier(
                        "course-node-generation-status-\(node.id)"
                    )
                    .accessibilityValue(node.status.rawValue)
            }
        }
    }

    private func primaryAction() {
        if node.kind == .folder, canExpand {
            withAnimation(.snappy(duration: 0.24)) {
                if isExpanded {
                    expandedNodeIDs.remove(node.id)
                } else {
                    expandedNodeIDs.insert(node.id)
                }
            }
        } else if node.kind == .markdown,
                  node.status == .generated,
                  let pageID = node.pageID {
            onOpenMarkdown(pageID)
        }
    }

    private var primaryAccessibilityHint: String {
        if canExpand {
            return isExpanded ? "Collapses this section." : "Expands this section."
        }
        if node.kind == .markdown, node.status == .generated {
            return "Opens this editable course page."
        }
        return "This course page is not ready yet."
    }
}

struct CourseNodeGenerationErrorView: View {
    let error: String
    let onOpenCourseAgent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("course-node-generation-error")

            Button("Open Course Agent", action: onOpenCourseAgent)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .accessibilityIdentifier(
                    "course-node-generation-error-open-agent"
                )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .red.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

enum CourseLearningTreeAccessibilityPolicy {
    static func rowIdentifier(for node: CourseLearningNode) -> String {
        "course-learning-node-\(node.id)"
    }

    static func rowLabel(for node: CourseLearningNode, ordinal: String) -> String {
        let role = node.role?.displayName ?? (node.kind == .folder ? "Section" : "Page")
        return "\(ordinal), \(role), \(node.title), \(statusLabel(for: node.status))"
    }

    private static func statusLabel(
        for status: CourseLearningNode.GenerationStatus
    ) -> String {
        switch status {
        case .pendingGeneration: "Pending generation"
        case .generating: "Generating"
        case .partiallyGenerated: "Partially generated"
        case .generated: "Ready"
        }
    }
}

#if DEBUG
struct CourseGenerationControlUITestHarnessView: View {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-course-generation-control")
    }

    private static var usesAccessibility3XL: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-dynamic-type-ax3xl")
    }

    private static var submissionRecoveryState: CourseAgentSubmissionRecoveryState? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-generation-recovery-acceptance-unknown") {
            return .acceptanceUnknown
        }
        if arguments.contains("--ui-test-generation-recovery-accepted-reply-incomplete") {
            return .acceptedReplyIncomplete
        }
        return nil
    }

    @State private var expandedNodeIDs: Set<String> = [
        "ui-generation-folder",
        "ui-generation-section",
    ]
    @State private var lastRequestedNodeID = "none"
    @State private var lastOpenedPageID = "none"

    private let nodes = [
        CourseLearningNode(
            id: "ui-generation-folder",
            title: "Cellular ageing",
            kind: .folder,
            status: .pendingGeneration,
            role: .chapter,
            pageID: "ui-generation-folder-page",
            children: [
                CourseLearningNode(
                    id: "ui-generation-section",
                    title: "Cell repair mechanisms",
                    kind: .folder,
                    status: .pendingGeneration,
                    role: .subchapter,
                    pageID: "ui-generation-section-page",
                    children: [
                        CourseLearningNode(
                            id: "ui-generation-leaf",
                            title: "Cellular ageing concept map",
                            kind: .markdown,
                            status: .pendingGeneration,
                            role: .explainer,
                            pageID: "ui-generation-leaf-page"
                        ),
                    ]
                ),
            ]
        ),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Course Generation Control Test")
                        .font(.headline)
                        .accessibilityIdentifier("courseGenerationControlHarness.title")

                    CourseLearningTreeView(
                        nodes: nodes,
                        expandedNodeIDs: $expandedNodeIDs,
                        generationDisabled: CourseExperienceStore
                            .shouldDisableCourseNodeGeneration(
                                backgroundGenerationActive: false,
                                mainAgentPhase: .idle,
                                submissionRecoveryState: Self.submissionRecoveryState
                            ),
                        runtimeID: CourseAgentProvider.appleOnDevice,
                        onOpenMarkdown: { pageID in lastOpenedPageID = pageID },
                        onGenerate: { node in lastRequestedNodeID = node.id }
                    )
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 20))

                    Text(lastRequestedNodeID)
                        .font(.caption)
                        .accessibilityIdentifier(
                            "courseGenerationControlHarness.lastRequestedNodeID"
                        )

                    Text(Self.submissionRecoveryState?.rawValue ?? "none")
                        .font(.caption)
                        .accessibilityIdentifier(
                            "courseGenerationControlHarness.submissionRecoveryState"
                        )

                    CoursePageStructureBrowser(
                        nodes: nodes,
                        onOpenPage: { pageID in lastOpenedPageID = pageID }
                    )

                    Text(lastOpenedPageID)
                        .font(.caption)
                        .accessibilityIdentifier(
                            "courseGenerationControlHarness.lastOpenedPageID"
                        )

                    Spacer()
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Generate")
        }
        .environment(
            \.dynamicTypeSize,
            Self.usesAccessibility3XL ? .accessibility3 : .large
        )
        .onAppear {
            (UIApplication.shared.delegate as? AppDelegate)?.signalContentReady()
        }
    }
}
#endif

enum CourseBuildingProgressCopy {
    static func firstTargetMilestone(for brief: CourseBrief) -> String {
        guard let target = CoursePlanHierarchyPolicy.firstContentLeaf(in: brief) else {
            return "Writing your first learning page"
        }
        return "Writing \(target.role?.displayName ?? "Page"): \(target.title)"
    }

    static func subtitle(agentName: String, brief: CourseBrief) -> String {
        guard let target = CoursePlanHierarchyPolicy.firstContentLeaf(in: brief) else {
            return "\(agentName) is mapping the full course and writing only your first learning page."
        }
        return "\(agentName) is mapping the full course and writing only \(target.title), your first \(target.role?.rawValue ?? "learning page")."
    }
}

enum CourseBuildingMilestoneState: String, Equatable {
    case complete
    case active
    case failed
    case upcoming
}

struct CourseBuildingPresentationSnapshot {
    static let milestoneCount = 5

    let brief: CourseBrief
    let agentName: String
    let generationStep: Int
    let generationError: String?

    var isComplete: Bool {
        generationStep >= Self.milestoneCount && generationError == nil
    }

    var stateIdentifier: String {
        if generationError != nil { return "generation-error" }
        if isComplete { return "completion" }
        return "milestone-\(min(max(generationStep, 0), Self.milestoneCount - 1) + 1)"
    }

    var milestones: [(title: String, systemImage: String)] {
        [
            ("Saving your learner profile", "person.text.rectangle"),
            ("Creating your course map", "point.3.connected.trianglepath.dotted"),
            ("Preparing every chapter folder", "folder.fill.badge.plus"),
            (
                CourseBuildingProgressCopy.firstTargetMilestone(for: brief),
                "text.book.closed.fill"
            ),
            ("Ready to start learning", "sparkles"),
        ]
    }

    func milestoneState(at index: Int) -> CourseBuildingMilestoneState {
        if generationError != nil,
           index == min(max(generationStep, 0), Self.milestoneCount - 1) {
            return .failed
        }
        if index < generationStep { return .complete }
        if index == generationStep { return .active }
        return .upcoming
    }
}

struct CourseBuildingPresentation: View {
    let snapshot: CourseBuildingPresentationSnapshot
    let onOpenCourse: () -> Void
    let onReturnToCourseAgent: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.025, green: 0.07, blue: 0.17), Color(red: 0.05, green: 0.16, blue: 0.35)],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("Building Your Course")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(CourseBuildingProgressCopy.subtitle(
                            agentName: snapshot.agentName,
                            brief: snapshot.brief
                        ))
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    CourseArtwork(title: snapshot.brief.title, accentHex: "1F6FEB")
                        .frame(height: 255)
                        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 32, style: .continuous)
                                .stroke(.white.opacity(0.15))
                        }
                        .shadow(color: .blue.opacity(0.28), radius: 30, y: 16)

                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.milestones.enumerated()), id: \.offset) { index, milestone in
                            let milestoneState = snapshot.milestoneState(at: index)
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(
                                            milestoneState == .complete
                                                ? Color.green
                                                : milestoneState == .failed
                                                    ? Color.red.opacity(0.72)
                                                    : Color.white.opacity(0.1)
                                        )
                                    if milestoneState == .complete {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    } else if milestoneState == .failed {
                                        Image(systemName: "xmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    } else if milestoneState == .active {
                                        ProgressView().tint(.white)
                                    } else {
                                        Image(systemName: milestone.systemImage)
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.45))
                                    }
                                }
                                .frame(width: 34, height: 34)

                                Text(milestone.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(
                                        milestoneState == .upcoming
                                            ? .white.opacity(0.45)
                                            : milestoneState == .failed
                                                ? Color.yellow
                                                : .white
                                    )
                                Spacer()
                            }
                            .padding(.vertical, 13)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("course-building-milestone-\(index + 1)")
                            .accessibilityValue(milestoneState.rawValue)

                            if index < snapshot.milestones.count - 1 {
                                Rectangle()
                                    .fill(.white.opacity(0.12))
                                    .frame(height: 1)
                                    .padding(.leading, 48)
                            }
                        }
                    }
                    .padding(.horizontal, 17)
                    .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("YOUR COURSE PATH")
                            .font(.caption2.bold())
                            .tracking(1.3)
                            .foregroundStyle(.white.opacity(0.5))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(Array(snapshot.brief.chapters.enumerated()), id: \.element.id) { index, chapter in
                                    Text("\(index + 1)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                        .frame(width: 44, height: 36)
                                        .background(.white.opacity(index < max(snapshot.generationStep, 1) ? 0.18 : 0.07), in: Capsule())
                                        .accessibilityLabel("Chapter \(index + 1), \(chapter.title)")
                                }
                            }
                        }
                    }

                    if snapshot.isComplete {
                        Button("Open My Course", action: onOpenCourse)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .foregroundStyle(.blue)
                            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .accessibilityIdentifier("course-building-open-course")
                    } else if snapshot.generationError == nil {
                        Text("You can close this screen while generation continues with the app open.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.48))
                    }

                    if let generationError = snapshot.generationError {
                        VStack(spacing: 12) {
                            Label(generationError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("course-building-error")
                            Button("Return to Course Agent", action: onReturnToCourseAgent)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.white.opacity(0.14), in: Capsule())
                                .accessibilityIdentifier("course-building-return-agent")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 30)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close course generation")
                .accessibilityIdentifier("course-building-close")

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                LinearGradient(
                    colors: [
                        Color(red: 0.025, green: 0.07, blue: 0.17),
                        Color(red: 0.035, green: 0.105, blue: 0.24),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeInOut(duration: 0.35), value: snapshot.generationStep)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-building-state")
        .accessibilityValue(snapshot.stateIdentifier)
    }
}

private struct CourseBuildingView: View {
    @Bindable var store: CourseExperienceStore

    var body: some View {
        CourseBuildingPresentation(
            snapshot: CourseBuildingPresentationSnapshot(
                brief: store.brief,
                agentName: store.activeAgentID.displayLabel,
                generationStep: store.generationStep,
                generationError: store.generationError
            ),
            onOpenCourse: store.openGeneratedCourse,
            onReturnToCourseAgent: store.returnToCourseAgent,
            onClose: store.leaveBuildingScreen
        )
    }
}

#if DEBUG
struct CourseGenerationCheckpointUITestHarnessView: View {
    let scenario: CourseGenerationCheckpointScenario

    @State private var displayedScenario: CourseGenerationCheckpointScenario
    @State private var memoryOnlyActionCount = 0
    @State private var actionResult: String?

    init(scenario: CourseGenerationCheckpointScenario) {
        self.scenario = scenario
        _displayedScenario = State(initialValue: scenario)
    }

    var body: some View {
        Group {
            if displayedScenario == .lf40ReturnedAgent {
                CourseGenerationReturnedAgentCheckpointView()
            } else if let snapshot = buildingSnapshot {
                CourseBuildingPresentation(
                    snapshot: snapshot,
                    onOpenCourse: {
                        recordMemoryOnlyAction("Open course action stayed in memory")
                    },
                    onReturnToCourseAgent: {
                        recordMemoryOnlyAction("Returned to the non-live agent receipt")
                        displayedScenario = .lf40ReturnedAgent
                    },
                    onClose: {
                        recordMemoryOnlyAction("Close action stayed in memory")
                    }
                )
            } else {
                CourseNodeGenerationCheckpointView(
                    scenario: displayedScenario,
                    onMemoryOnlyAction: recordMemoryOnlyAction
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            checkpointHeader
        }
        .overlay(alignment: .bottom) {
            if let actionResult {
                Text(actionResult)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.indigo, in: Capsule())
                    .padding(.bottom, 8)
                    .accessibilityIdentifier(
                        "courseGenerationCheckpoint.memoryOnlyActionResult"
                    )
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("courseGenerationCheckpoint.root")
    }

    private var checkpointHeader: some View {
        VStack(spacing: 3) {
            Text(displayedScenario.nonLiveBoundary)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.indigo)
                .accessibilityIdentifier(
                    "courseGenerationCheckpoint.nonLiveBoundary"
                )

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Route · \(displayedScenario.checkpointID)")
                        .accessibilityIdentifier(
                            "courseGenerationCheckpoint.route"
                        )
                        .accessibilityValue(displayedScenario.route)
                    Text("State · \(displayedScenario.substate)")
                        .accessibilityIdentifier(
                            "courseGenerationCheckpoint.state"
                        )
                        .accessibilityValue(displayedScenario.rawValue)
                }
                Spacer(minLength: 4)
                Text("Persistent mutations · 0")
                    .accessibilityIdentifier(
                        "courseGenerationCheckpoint.persistentMutations"
                    )
                    .accessibilityValue(
                        "keychain=0,defaults=0,pasteboard=0,network=0,files=0"
                    )
            }

            HStack(spacing: 8) {
                Text("Hook · \(displayedScenario.hookIdentifier)")
                    .accessibilityIdentifier(
                        "courseGenerationCheckpoint.hook"
                    )
                    .accessibilityValue(displayedScenario.hookIdentifier)
                Spacer(minLength: 4)
                Text("Memory actions · \(memoryOnlyActionCount)")
                    .accessibilityIdentifier(
                        "courseGenerationCheckpoint.memoryOnlyActions"
                    )
                    .accessibilityValue(String(memoryOnlyActionCount))
            }
        }
        .font(.caption2.monospaced().weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.bottom, 5)
        .background(Color(uiColor: .systemBackground))
    }

    private var buildingSnapshot: CourseBuildingPresentationSnapshot? {
        let step: Int
        let error: String?
        switch displayedScenario {
        case .lf39Milestone1:
            step = 0
            error = nil
        case .lf39Milestone2:
            step = 1
            error = nil
        case .lf39Milestone3:
            step = 2
            error = nil
        case .lf39Milestone4:
            step = 3
            error = nil
        case .lf39Milestone5:
            step = 4
            error = nil
        case .lf40GenerationError:
            step = 3
            error = "The first learning page could not be written. Your course map and conversation are preserved."
        case .lf40ReturnedAgent, .lf44Pending, .lf44Generating,
             .lf44PartialGenerated, .lf44Error:
            return nil
        }
        return CourseBuildingPresentationSnapshot(
            brief: Self.fixtureBrief,
            agentName: "Course Agent",
            generationStep: step,
            generationError: error
        )
    }

    private func recordMemoryOnlyAction(_ result: String) {
        memoryOnlyActionCount += 1
        actionResult = result
    }

    private static let fixtureBrief: CourseBrief = {
        var brief = CourseBrief()
        brief.planID = "lf39-checkpoint-plan"
        brief.revision = 1
        brief.title = "Systems Thinking for Climate Resilience"
        brief.summary = "A practical course from core system models to a local resilience project."
        brief.outcome = "Model a local climate risk and design a defensible intervention."
        brief.startingPoint = "Comfortable with general science and basic charts."
        brief.focusGap = "Feedback loops, uncertainty, and intervention design."
        brief.estimatedDuration = "6 weeks"
        brief.chapters = [
            CourseChapter(
                id: "foundations",
                title: "Systems Foundations",
                objective: "Read causal structure clearly.",
                deliverables: ["Feedback-loop map"]
            ),
            CourseChapter(
                id: "risk",
                title: "Climate Risk",
                objective: "Reason under uncertainty.",
                deliverables: ["Risk model"]
            ),
            CourseChapter(
                id: "intervention",
                title: "Resilient Intervention",
                objective: "Turn analysis into action.",
                deliverables: ["Local intervention brief"]
            ),
        ]
        return brief
    }()
}

private struct CourseGenerationReturnedAgentCheckpointView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Returned to Course Agent", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.blue)

                    Text("Your course request and plan remain available. Adjust the request or ask the agent to try the failed page again.")
                        .font(.body)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("GENERATION RECOVERY")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.secondary)
                        Text("The first learning page could not be written. Your course map and conversation are preserved.")
                            .font(.subheadline)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

                    Label(
                        "Frozen component receipt — no runtime, conversation, or persistent course was started.",
                        systemImage: "shield.lefthalf.filled"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("course-building-returned-agent-boundary")
                }
                .padding(20)
            }
            .navigationTitle("Course Agent")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("course-building-returned-agent")
        .accessibilityValue("non-live-receipt")
    }
}

private struct CourseNodeGenerationCheckpointView: View {
    let scenario: CourseGenerationCheckpointScenario
    let onMemoryOnlyAction: (String) -> Void

    @State private var expandedNodeIDs: Set<String> = ["lf44-chapter"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Learning path")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text("Open any ready lesson. Generate a pending section when you want to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                CourseLearningTreeView(
                    nodes: nodes,
                    expandedNodeIDs: $expandedNodeIDs,
                    generationDisabled: scenario == .lf44Generating,
                    runtimeID: CourseAgentProvider.codex,
                    onOpenMarkdown: { pageID in
                        onMemoryOnlyAction("Opened \(pageID) in memory")
                    },
                    onGenerate: { node in
                        onMemoryOnlyAction("Requested \(node.id) in memory")
                    }
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    .background,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )

                if scenario == .lf44Error {
                    CourseNodeGenerationErrorView(
                        error: "The course agent couldn’t generate Feedback Loops. Your existing lessons are unchanged.",
                        onOpenCourseAgent: {
                            onMemoryOnlyAction(
                                "Opened the non-live course-agent recovery receipt"
                            )
                        }
                    )
                }
            }
            .padding(18)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .accessibilityIdentifier("course-node-generation-checkpoint")
        .accessibilityValue(scenario.substate)
    }

    private var nodes: [CourseLearningNode] {
        let firstLessonStatus: CourseLearningNode.GenerationStatus
        let secondLessonStatus: CourseLearningNode.GenerationStatus
        let chapterStatus: CourseLearningNode.GenerationStatus

        switch scenario {
        case .lf44Generating:
            chapterStatus = .partiallyGenerated
            firstLessonStatus = .generating
            secondLessonStatus = .pendingGeneration
        case .lf44PartialGenerated:
            chapterStatus = .partiallyGenerated
            firstLessonStatus = .generated
            secondLessonStatus = .pendingGeneration
        case .lf44Pending, .lf44Error:
            chapterStatus = .pendingGeneration
            firstLessonStatus = .pendingGeneration
            secondLessonStatus = .pendingGeneration
        case .lf39Milestone1, .lf39Milestone2, .lf39Milestone3,
             .lf39Milestone4, .lf39Milestone5, .lf40GenerationError,
             .lf40ReturnedAgent:
            return []
        }

        return [
            CourseLearningNode(
                id: "lf44-chapter",
                title: "Feedback Loops",
                kind: .folder,
                status: chapterStatus,
                role: .chapter,
                children: [
                    CourseLearningNode(
                        id: "lf44-lesson-ready",
                        title: "Reinforcing and balancing loops",
                        kind: .markdown,
                        status: firstLessonStatus,
                        role: .lesson,
                        relativePath: "chapters/feedback-loops/loops.md",
                        pageID: "lf44-page-ready"
                    ),
                    CourseLearningNode(
                        id: "lf44-lesson-next",
                        title: "Delays and unintended effects",
                        kind: .markdown,
                        status: secondLessonStatus,
                        role: .lesson,
                        relativePath: "chapters/feedback-loops/delays.md",
                        pageID: "lf44-page-next"
                    ),
                ]
            ),
        ]
    }
}

struct ProviderSettingsSourceCheckpointUITestHarnessView: View {
    let scenario: ProviderSettingsSourceCheckpointScenario?

    /// Central strict-root dispatch must use this initializer so the one
    /// authoritative launch parse is injected instead of repeated here.
    init(scenario: ProviderSettingsSourceCheckpointScenario) {
        self.scenario = scenario
    }

    /// Compatibility only for callers that have not migrated to the central
    /// typed strict root. This path is not used by strict-root dispatch.
    init() {
        scenario = ProviderSettingsSourceCheckpointScenario.current()
    }

    var body: some View {
        Group {
            if let scenario {
                ProviderSettingsSourceCheckpointValidHarnessView(
                    scenario: scenario
                )
            } else {
                ProviderSettingsSourceCheckpointConfigurationErrorView()
            }
        }
    }
}

private struct ProviderSettingsSourceCheckpointConfigurationErrorView: View {
    var body: some View {
        ContentUnavailableView {
            Label(
                "Provider checkpoint not configured",
                systemImage: "wrench.and.screwdriver"
            )
        } description: {
            Text(
                "Add exactly one documented LF-03, LF-05, LF-06, LF-27, LF-28, or LF-30 state argument."
            )
        }
        .accessibilityIdentifier(
            "providerSettingsSourceCheckpoint.configurationError"
        )
    }
}

private struct ProviderSettingsSourceCheckpointValidHarnessView: View {
    let scenario: ProviderSettingsSourceCheckpointScenario

    @State private var baseURL = "https://checkpoint.invalid/v1"
    @State private var apiKey = ""
    @State private var modelID = "checkpoint-model"
    @State private var selectedAgentID: String
    @State private var selectedModelID: String
    @State private var selectedEffortID: String
    @State private var didCancel = false
    @State private var didAttemptSave = false
    @State private var didRetry = false
    @State private var memoryOnlyActionCount = 0

    init(scenario: ProviderSettingsSourceCheckpointScenario) {
        self.scenario = scenario
        let initialDraft = switch scenario {
        case .lf27Cancel, .lf27FailureRollback:
            Self.proposedSettings
        default:
            Self.persistedSettings
        }
        _selectedAgentID = State(initialValue: initialDraft.agentID)
        _selectedModelID = State(initialValue: initialDraft.modelID)
        _selectedEffortID = State(initialValue: initialDraft.effortID)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if scenario.isSourceCheckpoint {
                    CourseSourceCheckpointUITestHarnessView(
                        scenario: scenario,
                        onMemoryOnlyAction: recordMemoryOnlyAction
                    )
                } else {
                    checkpointContent
                }
            }
            .frame(maxHeight: .infinity)

            checkpointHeader
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providerSettingsSourceCheckpoint.root")
    }

    private var checkpointHeader: some View {
        VStack(spacing: 4) {
            Text(scenario.nonLiveBoundary)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.indigo)
                .accessibilityIdentifier(
                    "providerSettingsSourceCheckpoint.nonLiveBoundary"
                )

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Route · \(scenario.checkpointID)")
                        .accessibilityIdentifier(
                            "providerSettingsSourceCheckpoint.route"
                        )
                        .accessibilityValue(
                            ProviderSettingsSourceCheckpointScenario
                                .launchArgument
                        )
                    Text("State · \(scenario.substate)")
                        .accessibilityIdentifier(
                            "providerSettingsSourceCheckpoint.state"
                        )
                        .accessibilityValue(scenario.rawValue)
                }
                Spacer()
                Text("Persistent mutations · 0")
                    .accessibilityIdentifier(
                        "providerSettingsSourceCheckpoint.persistentMutations"
                    )
                    .accessibilityValue(
                        "keychain=0,defaults=0,pasteboard=0,network=0,files=0"
                    )
            }
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)

            if let hookIdentifier = scenario.deterministicHookIdentifier {
                Text("Hook · \(hookIdentifier)")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .accessibilityIdentifier(
                        "providerSettingsSourceCheckpoint.hook"
                    )
                    .accessibilityValue(hookIdentifier)
            }

            Text("Fixture actions · memory only · \(memoryOnlyActionCount)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .accessibilityIdentifier(
                    "providerSettingsSourceCheckpoint.memoryOnlyActions"
                )
                .accessibilityValue(String(memoryOnlyActionCount))
        }
        .padding(.bottom, 5)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var checkpointContent: some View {
        switch scenario {
        case .lf03PickerAvailable, .lf03PickerUnavailable:
            setupPickerAvailabilityCheckpoint
        case .lf05Saving, .lf05Error:
            providerFormCheckpoint
        case .lf05SuccessReturn:
            providerSuccessReturnCheckpoint
        case .lf06Connecting, .lf06Failed:
            setupConnectionCheckpoint
        case .lf06ConnectedTarget:
            connectedLibraryCheckpoint
        case .lf27ModelLoading, .lf27ModelEmpty, .lf27ModelDefault,
             .lf27ModelPopulated, .lf27Checking, .lf27Cancel,
             .lf27FailureRollback, .lf27AgentError:
            settingsLifecycleCheckpoint
        case .lf28Synced, .lf28OnThisDevice, .lf28SignInRequired,
             .lf28NeedsAttention, .lf28Retry:
            cloudSyncCheckpoint
        case .lf30SourceMenu, .lf30Preparing, .lf30PassageContext,
             .lf30PermissionError, .lf30ParseError, .lf30PreparationError:
            EmptyView()
        }
    }

    private var setupPickerAvailabilityCheckpoint: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                CourseAgentSetupPickerContent(
                    agentOptions: setupPickerAgentOptions,
                    showsUnavailableOptions:
                        scenario == .lf03PickerUnavailable,
                    selectedAgentID: $selectedAgentID,
                    hasCustomEndpoint: false,
                    onSelectAgent: { _ in recordMemoryOnlyAction() },
                    onAddServer: recordMemoryOnlyAction,
                    onOpenCustomProvider: recordMemoryOnlyAction
                )
                .padding(.horizontal, 22)
                .padding(.top, 38)
                .padding(.bottom, 72)
            }
            .safeAreaPadding(.bottom, 16)
        }
    }

    private var setupPickerAgentOptions: [CourseAgentOption] {
        let appleOptions: [CourseAgentOption]
        if scenario == .lf03PickerUnavailable {
            appleOptions = [
                CourseAgentOption(
                    id: CourseAgentProvider.applePrivateCloud,
                    title: "Apple Private Cloud Compute",
                    available: false,
                    availabilityDescription:
                        "Requires an eligible iPhone and supported region"
                ),
                CourseAgentOption(
                    id: CourseAgentProvider.appleOnDevice,
                    title: "Apple On-Device",
                    available: false,
                    availabilityDescription:
                        "Requires Apple Intelligence on this iPhone"
                ),
            ]
        } else {
            appleOptions = [
                CourseAgentOption(
                    id: CourseAgentProvider.applePrivateCloud,
                    title: "Apple Private Cloud Compute",
                    available: true,
                    availabilityDescription:
                        "Available with Private Cloud Compute"
                ),
                CourseAgentOption(
                    id: CourseAgentProvider.appleOnDevice,
                    title: "Apple On-Device",
                    available: true,
                    availabilityDescription: "Available on this iPhone"
                ),
            ]
        }

        return appleOptions + [
            CourseAgentOption(
                id: CourseAgentProvider.codex,
                title: "Codex",
                available: true,
                availabilityDescription:
                    "Available with the configured provider"
            ),
        ]
    }

    @ViewBuilder
    private var providerFormCheckpoint: some View {
        if didCancel {
            NavigationStack {
                VStack(spacing: 18) {
                    Label(
                        "Provider setup cancelled",
                        systemImage: "xmark.circle"
                    )
                    .font(.title3.weight(.bold))
                    .accessibilityIdentifier("lf05-cancelled")
                    Text("No provider setting changed.")
                        .foregroundStyle(.secondary)
                    CourseAgentCustomProviderButton(
                        hasCustomEndpoint: false,
                        action: recordMemoryOnlyAction
                    )
                }
                .padding(20)
                .navigationTitle("Choose your course agent")
            }
        } else {
            OpenAICompatibleProviderForm(
                baseURL: $baseURL,
                apiKey: $apiKey,
                modelID: $modelID,
                hasStoredKey: true,
                hasStoredBaseURL: true,
                isSaving: scenario == .lf05Saving,
                errorMessage: scenario == .lf05Error
                    ? "The provider could not be verified. Check the endpoint and try again."
                    : nil,
                canSave: true,
                onCancel: {
                    recordMemoryOnlyAction()
                    didCancel = true
                },
                onSave: recordMemoryOnlyAction,
                onClearCustomEndpoint: recordMemoryOnlyAction
            )
        }
    }

    private var providerSuccessReturnCheckpoint: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(
                        "Provider activated",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("lf05-provider-activated")

                    CourseAgentCustomProviderButton(
                        hasCustomEndpoint: true,
                        action: recordMemoryOnlyAction
                    )

                    CourseAgentSetupConnectionControls(
                        agentID: "codex",
                        connectionState: .idle,
                        isAgentAvailable: true,
                        onConnect: recordMemoryOnlyAction
                    )
                }
                .padding(20)
            }
            .navigationTitle("Choose your course agent")
        }
    }

    private var setupConnectionCheckpoint: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Choose your course agent")
                        .font(.largeTitle.bold())

                    CourseAgentChoiceRow(
                        id: "codex",
                        title: "Codex",
                        subtitle: "Runs on this device with the selected provider",
                        available: true,
                        selected: true,
                        onSelect: recordMemoryOnlyAction
                    )

                    CourseAgentSetupConnectionControls(
                        agentID: "codex",
                        connectionState: setupConnectionState,
                        isAgentAvailable: true,
                        onConnect: {
                            recordMemoryOnlyAction()
                            didRetry = true
                        }
                    )
                }
                .padding(20)
            }
        }
    }

    private var setupConnectionState: CourseExperienceStore.AgentConnectionState {
        if didRetry { return .connecting }
        switch scenario {
        case .lf06Connecting:
            return .connecting
        case .lf06Failed:
            return .failed(
                "Couldn’t reach the selected provider. Check the connection and try again."
            )
        default:
            return .idle
        }
    }

    private var connectedLibraryCheckpoint: some View {
        NavigationStack {
            CourseLibraryContent(
                courses: [],
                selectedAgentID: "codex",
                resumableDraft: nil,
                onOpenAppSettings: recordMemoryOnlyAction,
                onOpenAgentSettings: recordMemoryOnlyAction,
                onOpenCourse: { _ in recordMemoryOnlyAction() },
                onResumeDraft: recordMemoryOnlyAction,
                onNewCourse: recordMemoryOnlyAction
            )
            .navigationBarHidden(true)
        }
    }

    @ViewBuilder
    private var settingsLifecycleCheckpoint: some View {
        if scenario == .lf27Cancel, didCancel {
            NavigationStack {
                VStack(spacing: 18) {
                    HStack {
                        Image(systemName: "checkmark.shield")
                            .accessibilityHidden(true)
                        Text("Settings unchanged")
                            .accessibilityIdentifier("lf27-cancel-result")
                    }
                    .font(.title3.weight(.bold))
                    restoredSettingsMarkers
                    CourseLibraryEmptyState()
                }
                .padding(20)
                .navigationTitle("My Courses")
            }
        } else {
            NavigationStack {
                Form {
                    Section("Course agent") {
                        LabeledContent(
                            "Selected",
                            value: selectedAgentID.displayLabel
                        )
                            .accessibilityIdentifier(
                                "lf27-selected-agent"
                            )
                            .accessibilityValue(selectedAgentID)
                    }

                    CourseAgentModelSection(
                        agentID: selectedAgentID,
                        models: settingsModels,
                        isLoading: scenario == .lf27ModelLoading,
                        selectedModel: selectedModelID,
                        onSelect: { model in
                            recordMemoryOnlyAction()
                            selectedModelID = model.id
                            selectedEffortID = model.defaultReasoningEffort.wireValue
                        }
                    )

                    Section("Reasoning") {
                        LabeledContent(
                            "Effort",
                            value: selectedEffortID.capitalized
                        )
                        .accessibilityIdentifier("course-settings-effort")
                        .accessibilityValue(selectedEffortID)
                    }

                    if hasDivergentSettingsDraft {
                        Section {
                            HStack {
                                Image(systemName: "pencil.and.list.clipboard")
                                    .accessibilityHidden(true)
                                Text("Unsaved draft · Fast model · Low effort")
                                    .accessibilityIdentifier("lf27-divergent-draft")
                                    .accessibilityValue(settingsDraftValue)
                            }
                        } footer: {
                            Text("Saved settings remain Codex, Recommended model, Medium effort until Save succeeds.")
                        }
                    }

                    if scenario == .lf27FailureRollback, didAttemptSave {
                        Section {
                            HStack {
                                Image(systemName: "arrow.uturn.backward.circle")
                                    .accessibilityHidden(true)
                                Text("Changes weren’t saved. Previous settings restored.")
                                    .accessibilityIdentifier(
                                        "lf27-failure-rollback"
                                    )
                            }
                            .foregroundStyle(.orange)
                            restoredSettingsMarkers
                        }
                    }

                    if scenario == .lf27AgentError {
                        CourseAgentSettingsErrorSection(
                            message: "The selected agent’s model catalog could not be loaded. Try again."
                        )
                    }
                }
                .navigationTitle("Course Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            recordMemoryOnlyAction()
                            restorePersistedSettings()
                            didCancel = true
                        }
                        .accessibilityIdentifier("course-settings-cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(
                            scenario == .lf27Checking ? "Checking…" : "Save"
                        ) {
                            recordMemoryOnlyAction()
                            if scenario == .lf27FailureRollback {
                                restorePersistedSettings()
                                didAttemptSave = true
                            }
                        }
                        .disabled(scenario == .lf27Checking)
                        .accessibilityIdentifier("course-settings-save")
                    }
                }
                .interactiveDismissDisabled(scenario == .lf27Checking)
                .accessibilityIdentifier("course-settings-checkpoint-form")
                .accessibilityValue(
                    scenario == .lf27Checking ? "checking" : scenario.substate
                )
            }
        }
    }

    private var settingsModels: [ModelInfo] {
        switch scenario {
        case .lf27ModelLoading, .lf27ModelEmpty:
            []
        case .lf27ModelDefault:
            [Self.defaultModel]
        default:
            [Self.defaultModel, Self.secondaryModel]
        }
    }

    private var hasDivergentSettingsDraft: Bool {
        currentSettingsDraft != Self.persistedSettings
    }

    private var currentSettingsDraft: CourseAgentSettingsDraft {
        CourseAgentSettingsDraft(
            agentID: selectedAgentID,
            modelID: selectedModelID,
            effortID: selectedEffortID
        )
    }

    private var settingsDraftValue: String {
        "agent=\(selectedAgentID),model=\(selectedModelID),effort=\(selectedEffortID)"
    }

    private var restoredSettingsMarkers: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(
                "Restored agent",
                value: selectedAgentID.displayLabel
            )
                .accessibilityIdentifier("lf27-restored-agent")
                .accessibilityValue(selectedAgentID)
            LabeledContent(
                "Restored model",
                value: selectedModelID == Self.persistedSettings.modelID
                    ? "Recommended model"
                    : selectedModelID
            )
                .accessibilityIdentifier("lf27-restored-model")
                .accessibilityValue(selectedModelID)
            LabeledContent(
                "Restored effort",
                value: selectedEffortID.capitalized
            )
                .accessibilityIdentifier("lf27-restored-effort")
                .accessibilityValue(selectedEffortID)
        }
    }

    private var cloudSyncCheckpoint: some View {
        NavigationStack {
            Form {
                CourseCloudSyncStatusSection(
                    availability: cloudAvailability,
                    isRetrying: scenario == .lf28Retry || didRetry,
                    onRetry: {
                        recordMemoryOnlyAction()
                        didRetry = true
                    }
                )
            }
            .navigationTitle("Course Settings")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("lf28-cloud-status-form")
        }
    }

    private var cloudAvailability: CourseCloudSyncAvailability {
        switch scenario {
        case .lf28Synced:
            .available
        case .lf28OnThisDevice:
            .missingEntitlement
        case .lf28SignInRequired:
            .noAccount
        case .lf28NeedsAttention, .lf28Retry:
            .failed(
                "The iCloud account needs attention. Local courses remain available."
            )
        default:
            .missingEntitlement
        }
    }

    private func recordMemoryOnlyAction() {
        memoryOnlyActionCount += 1
    }

    private func restorePersistedSettings() {
        let restored = CourseAgentSettingsDraftPolicy.afterSave(
            current: currentSettingsDraft,
            persisted: Self.persistedSettings,
            didSave: false
        )
        selectedAgentID = restored.agentID
        selectedModelID = restored.modelID
        selectedEffortID = restored.effortID
    }

    private static let persistedSettings = CourseAgentSettingsDraft(
        agentID: "codex",
        modelID: "checkpoint-default",
        effortID: "medium"
    )

    private static let proposedSettings = CourseAgentSettingsDraft(
        agentID: "codex",
        modelID: "checkpoint-fast",
        effortID: "low"
    )

    private static let defaultModel = ModelInfo(
        id: "checkpoint-default",
        model: "checkpoint-default",
        displayName: "Recommended model",
        description: "Balanced for course creation",
        hidden: false,
        supportedReasoningEfforts: [
            ReasoningEffortOption(
                reasoningEffort: .medium,
                description: "Balanced"
            ),
        ],
        defaultReasoningEffort: .medium,
        inputModalities: [.text],
        isDefault: true,
        agentRuntimeKind: "codex"
    )

    private static let secondaryModel = ModelInfo(
        id: "checkpoint-fast",
        model: "checkpoint-fast",
        displayName: "Fast model",
        description: "Lower latency for short questions",
        hidden: false,
        supportedReasoningEfforts: [
            ReasoningEffortOption(
                reasoningEffort: .low,
                description: "Fast"
            ),
        ],
        defaultReasoningEffort: .low,
        inputModalities: [.text],
        isDefault: false,
        agentRuntimeKind: "codex"
    )
}
#endif
