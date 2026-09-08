import SwiftUI

/// Opens only the requested page after its durable generated status is confirmed.
struct CourseLessonActionButton: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    let course: LearningCourse
    let node: CourseLearningNode
    @Bindable var store: CourseExperienceStore
    let title: String
    var replacesCurrentPage = false

    @State private var requestID: UUID?
    @State private var isGenerating = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 8) {
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("course-reading-error")
            }
            Button {
                error = nil
                requestID = UUID()
            } label: {
                HStack(spacing: 12) {
                    if requestID != nil {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.right")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(requestID != nil ? (isGenerating ? "Generating next lesson…" : "Opening lesson…") : (error == nil ? title : "Try again"))
                            .font(.headline)
                        Text(node.title)
                            .font(.caption)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 13)
                .frame(maxWidth: 480, minHeight: 58)
                .background(.blue, in: RoundedRectangle(cornerRadius: 24))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(requestID != nil)
            .accessibilityIdentifier(replacesCurrentPage ? "course-next-lesson" : "course-continue")
        }
        .task(id: requestID) {
            guard let requestID else { return }
            await openLesson(request: requestID)
        }
        .onDisappear { requestID = nil }
    }

    @MainActor
    private func openLesson(request: UUID) async {
        defer {
            if requestID == request { requestID = nil; isGenerating = false }
        }
        do {
            let repository = try await store.documentRepository(for: course)
            var target = try await currentTarget(in: repository)
            guard !Task.isCancelled else { return }
            if target.status != .generated {
                isGenerating = true
                let alreadyGenerating = store.backgroundGeneratingCourseID == course.id
                    && store.backgroundGeneratingNodeID == target.id
                if !alreadyGenerating {
                    // A terminal interrupted attempt can leave a generating or partial
                    // page. The existing dispatcher still enforces runtime/busy guards.
                    target.status = .pendingGeneration
                    store.generateCourseNodeInBackground(
                        for: course, node: target, appModel: appModel, appState: appState
                    )
                }
                guard store.backgroundGeneratingCourseID == course.id,
                      store.backgroundGeneratingNodeID == target.id else {
                    throw ReadingError.unavailable(
                        store.backgroundGenerationError ?? "The course agent is busy. Try again when it finishes."
                    )
                }
                while store.backgroundGeneratingCourseID == course.id,
                      store.backgroundGeneratingNodeID == target.id {
                    try await Task.sleep(for: .milliseconds(300))
                }
                try Task.checkCancellation()
                target = try await currentTarget(in: repository)
                guard target.status == .generated else {
                    throw ReadingError.unavailable(
                        store.backgroundGenerationErrorCourseID == course.id
                            ? store.backgroundGenerationError ?? "This lesson is not ready yet. Try again."
                            : "This lesson is not ready yet. Try again."
                    )
                }
            }
            try Task.checkCancellation()
            guard let pageID = target.pageID else {
                throw ReadingError.unavailable("This lesson has no page yet. Open the course agent to repair it.")
            }
            guard requestID == request else { return }
            store.openReadingPage(
                courseID: course.id, pageID: pageID, replacingCurrentPage: replacesCurrentPage
            )
        } catch is CancellationError {
            // Leaving the reader cancels navigation, not the existing generation run.
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func currentTarget(in repository: CourseDocumentRepository) async throws -> CourseLearningNode {
        let outline = try await repository.outline()
        guard let target = CourseReadingOrder.lessons(in: outline.learningPages)
            .first(where: { $0.id == node.id }) else {
            throw ReadingError.unavailable("This lesson is no longer in the course. Reopen the course to choose a lesson.")
        }
        return target
    }

    private enum ReadingError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let message): message }
        }
    }
}
