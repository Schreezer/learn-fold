import NativeBlockEditorCore
import NativeBlockEditorUI
import SwiftUI

struct CoursePageEditorView: View {
    let course: LearningCourse
    let pageID: String
    @Bindable var store: CourseExperienceStore

    @State private var model: CoursePageEditorModel?
    @State private var loadingError: String?
    @State private var chatError: String?
    @State private var activeDiscussion: CourseSelectionDiscussion?

    var body: some View {
        Group {
            if let model, !model.isLoading {
                CoursePageEditorCanvas(
                    model: model,
                    textAnnotations: textAnnotations(in: model),
                    onAskAboutSelection: { selection in
                        askAboutSelection(selection, model: model)
                    },
                    onOpenTextAnnotation: { annotation in
                        openDiscussion(annotationID: annotation.id)
                    },
                    onOpenPage: { destination in
                        store.openCoursePage(courseID: course.id, pageID: destination.id)
                    }
                )
            } else if let loadingError {
                ContentUnavailableView(
                    "Couldn’t open this page",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadingError)
                )
            } else {
                ProgressView("Opening course page…")
            }
        }
        .navigationTitle(model?.title ?? "Course page")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: pageID) {
            do {
                let repository = try await store.documentRepository(for: course)
                let editorModel = CoursePageEditorModel(pageID: pageID, repository: repository)
                model = editorModel
                await editorModel.load()
            } catch {
                loadingError = error.localizedDescription
            }
        }
        .onDisappear {
            guard let model else { return }
            Task { await model.flush() }
        }
        .sheet(item: $activeDiscussion) { discussion in
            if let reference = discussion.reference {
                NavigationStack {
                    CourseChatView(
                        store: store,
                        selectionContext: reference,
                        selectionDiscussionID: discussion.id,
                        showsDismissButton: true
                    )
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .alert(
            "Can’t open the course agent",
            isPresented: Binding(
                get: { chatError != nil },
                set: { if !$0 { chatError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { chatError = nil }
        } message: {
            Text(chatError ?? "The course agent is unavailable.")
        }
    }

    private func askAboutSelection(
        _ selection: NativeBlockEditorSelection,
        model: CoursePageEditorModel
    ) {
        guard let reference = CourseSelectionAnchorResolver.reference(
            courseID: course.id,
            pageID: pageID,
            pageTitle: model.title,
            selection: selection,
            document: model.document
        ) else {
            chatError = "That selection could not be attached to this page. Select the passage again."
            return
        }
        guard let discussion = store.beginSelectionDiscussion(
            for: course,
            reference: reference
        ) else {
            chatError = "This course is no longer connected to its original agent thread."
            return
        }
        activeDiscussion = discussion
    }

    private func textAnnotations(
        in model: CoursePageEditorModel
    ) -> [NativeBlockEditorTextAnnotation] {
        store.unresolvedSelectionDiscussions(courseID: course.id, pageID: pageID)
            .compactMap {
                CourseSelectionAnchorResolver.annotation(
                    for: $0,
                    document: model.document
                )
            }
    }

    private func openDiscussion(annotationID: String) {
        guard let id = UUID(uuidString: annotationID),
              let discussion = store.selectionDiscussion(id: id),
              discussion.status == .unresolved else { return }
        activeDiscussion = discussion
    }
}

private struct CoursePageEditorCanvas: View {
    @Bindable var model: CoursePageEditorModel
    @AppStorage("coursePage.wrapsCodeLines") private var wrapsCodeLines = true
    let textAnnotations: [NativeBlockEditorTextAnnotation]
    let onAskAboutSelection: (NativeBlockEditorSelection) -> Void
    let onOpenTextAnnotation: (NativeBlockEditorTextAnnotation) -> Void
    let onOpenPage: (NativeBlockEditorPageDestination) -> Void

    var body: some View {
        NativeBlockEditorView(
            document: Binding(
                get: { model.document },
                set: { model.userChangedDocument($0) }
            ),
            configuration: NativeBlockEditorConfiguration(
                accentColor: .blue,
                contentMaxWidth: 760,
                horizontalPadding: 20,
                verticalPadding: 18,
                showsFormattingToolbar: true,
                showsDocumentToolbar: true,
                allowsBlockReordering: true
            ),
            header: AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Editable course page")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            ),
            pageResolver: { pageID in
                model.pageTitle(id: pageID).map {
                    NativeBlockEditorPageDestination(id: pageID, title: $0)
                }
            },
            onOpenPage: onOpenPage,
            onOpenURL: { url in
                guard let pageID = CoursePageLinkResolver.pageID(from: url) else {
                    return false
                }
                onOpenPage(
                    NativeBlockEditorPageDestination(
                        id: pageID,
                        title: model.pageTitle(id: pageID) ?? "Course page"
                    )
                )
                return true
            },
            onAskAboutSelection: onAskAboutSelection,
            textAnnotations: textAnnotations,
            onOpenTextAnnotation: onOpenTextAnnotation,
            wrapsCodeLines: $wrapsCodeLines
        )
        .overlay(alignment: .top) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
            }
        }
    }
}

enum CoursePageLinkResolver {
    static func pageID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "native-editor",
              url.host?.lowercased() == "page" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1 else { return nil }
        let pageID = components[0].removingPercentEncoding ?? components[0]
        return pageID.isEmpty ? nil : pageID
    }
}

enum CourseSelectionAnchorResolver {
    static func reference(
        courseID: String,
        pageID: String,
        pageTitle: String,
        selection: NativeBlockEditorSelection,
        document: BlockDocument
    ) -> CourseTextReference? {
        let selectedText = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty,
              let block = matchingBlock(
                blockID: selection.blockID,
                path: selection.path,
                document: document
              ),
              let range = anchoredRange(
                preferred: selection.range,
                selectedText: selectedText,
                blockText: block.node.delta?.plainText ?? ""
              ) else { return nil }

        return CourseTextReference(
            courseID: courseID,
            pageID: pageID,
            pageTitle: pageTitle,
            blockID: block.node.stableBlockID,
            pathIndices: block.path.indices,
            rangeLocation: range.location,
            rangeLength: range.length,
            selectedText: selectedText
        )
    }

    static func annotation(
        for discussion: CourseSelectionDiscussion,
        document: BlockDocument
    ) -> NativeBlockEditorTextAnnotation? {
        let storedPath = BlockPath(discussion.pathIndices)
        guard let block = matchingBlock(
            blockID: discussion.blockID,
            path: storedPath,
            document: document
        ) else { return nil }
        let preferred = NSRange(
            location: discussion.rangeLocation,
            length: discussion.rangeLength
        )
        guard let range = anchoredRange(
            preferred: preferred,
            selectedText: discussion.selectedText,
            blockText: block.node.delta?.plainText ?? "",
            acceptsSelectedTextPrefix: discussion.wasTruncated
        ) else { return nil }
        return NativeBlockEditorTextAnnotation(
            id: discussion.id.uuidString,
            blockID: block.node.stableBlockID,
            path: block.path,
            range: range
        )
    }

    private static func matchingBlock(
        blockID: String?,
        path: BlockPath,
        document: BlockDocument
    ) -> (path: BlockPath, node: BlockNode)? {
        let blocks = document.flattenedNodes()
        if let blockID,
           let stableMatch = blocks.first(where: { $0.node.stableBlockID == blockID }) {
            return stableMatch
        }
        return blocks.first(where: { $0.path == path })
    }

    private static func anchoredRange(
        preferred: NSRange,
        selectedText: String,
        blockText: String,
        acceptsSelectedTextPrefix: Bool = false
    ) -> NSRange? {
        let block = blockText as NSString
        let selected = selectedText as NSString
        guard selected.length > 0 else { return nil }

        if preferred.location >= 0,
           preferred.length > 0,
           NSMaxRange(preferred) <= block.length {
            let preferredText = block.substring(with: preferred)
            let relativeMatch = (preferredText as NSString).range(of: selectedText)
            if relativeMatch.location != NSNotFound {
                if acceptsSelectedTextPrefix {
                    return preferred
                }
                return NSRange(
                    location: preferred.location + relativeMatch.location,
                    length: relativeMatch.length
                )
            }
        }

        let recovered = block.range(of: selectedText)
        guard recovered.location != NSNotFound else { return nil }
        return NSRange(location: recovered.location, length: selected.length)
    }
}
