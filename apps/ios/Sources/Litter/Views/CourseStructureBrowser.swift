import SwiftUI
import UIKit

struct CoursePageStructureBrowser: View {
    let nodes: [CourseLearningNode]
    let onOpenPage: (String) -> Void

    @State private var expandedNodeIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Course structure")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Every lesson and note is an editable page")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(nodes) { node in
                    CoursePageStructureNode(
                        node: node,
                        depth: 0,
                        expandedNodeIDs: $expandedNodeIDs,
                        onOpenPage: onOpenPage
                    )
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .onAppear {
            if expandedNodeIDs.isEmpty {
                expandedNodeIDs = Set(nodes.filter { !$0.children.isEmpty }.map(\.id))
            }
        }
    }
}

private struct CoursePageStructureNode: View {
    let node: CourseLearningNode
    let depth: Int
    @Binding var expandedNodeIDs: Set<String>
    let onOpenPage: (String) -> Void

    private var isExpanded: Bool { expandedNodeIDs.contains(node.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    guard !node.children.isEmpty else { return }
                    withAnimation(.snappy(duration: 0.22)) {
                        if isExpanded { expandedNodeIDs.remove(node.id) }
                        else { expandedNodeIDs.insert(node.id) }
                    }
                } label: {
                    Image(systemName: node.children.isEmpty ? "doc.text.fill" : (isExpanded ? "chevron.down" : "chevron.right"))
                        .font(node.children.isEmpty ? .body : .caption.weight(.bold))
                        .foregroundStyle(node.status == .pendingGeneration ? Color.secondary : Color.blue)
                        .frame(width: 24, height: 40)
                }
                .buttonStyle(.plain)
                .disabled(node.children.isEmpty)

                Button {
                    if let pageID = node.pageID { onOpenPage(pageID) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.title)
                                .font(.system(size: 15, weight: depth == 0 ? .semibold : .medium))
                                .foregroundStyle(.primary)
                            Text(statusLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "square.and.pencil")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, CGFloat(depth) * 22 + 10)
            .padding(.trailing, 12)
            .padding(.vertical, 8)

            if isExpanded {
                ForEach(node.children) { child in
                    CoursePageStructureNode(
                        node: child,
                        depth: depth + 1,
                        expandedNodeIDs: $expandedNodeIDs,
                        onOpenPage: onOpenPage
                    )
                }
            }
        }
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, CGFloat(depth) * 22 + 44)
        }
    }

    private var statusLabel: String {
        switch node.status {
        case .pendingGeneration: "Pending generation"
        case .generating: "Generating"
        case .partiallyGenerated: "Partially generated"
        case .generated: "Editable page"
        }
    }
}

struct CourseStructureBrowser: View {
    let snapshot: CourseWorkspaceSnapshot
    let recommendedFilePath: String?
    let onOpenFile: (CourseFileNode) -> Void

    @State private var expandedPaths: Set<String> = []
    @State private var hasInitializedExpansion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Course structure")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("\(snapshot.fileCount) files  •  \(snapshot.folderCount) folders")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    Button("Expand All", systemImage: "arrow.down.right.and.arrow.up.left") {
                        expandedPaths = snapshot.directoryPaths
                    }
                    Button("Collapse All", systemImage: "arrow.up.left.and.arrow.down.right") {
                        expandedPaths.removeAll()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("Course structure options")
            }

            VStack(spacing: 0) {
                ForEach(snapshot.nodes) { node in
                    CourseFileTreeNodeView(
                        node: node,
                        depth: 0,
                        expandedPaths: $expandedPaths,
                        recommendedFilePath: recommendedFilePath,
                        onOpenFile: onOpenFile
                    )
                }
            }
        }
        .onAppear {
            guard !hasInitializedExpansion else { return }
            hasInitializedExpansion = true
            expandedPaths = defaultExpandedPaths
        }
    }

    private var defaultExpandedPaths: Set<String> {
        var paths = Set(snapshot.nodes.filter(\.isDirectory).map(\.relativePath))

        if let sources = snapshot.nodes.first(where: { $0.relativePath == "sources" }) {
            paths.formUnion(sources.children.filter(\.isDirectory).map(\.relativePath))
        }

        if let chapters = snapshot.nodes.first(where: { $0.relativePath == "chapters" }),
           let firstChapter = chapters.children.first(where: \.isDirectory) {
            paths.insert(firstChapter.relativePath)
            paths.formUnion(firstChapter.children.filter(\.isDirectory).map(\.relativePath))
        }
        return paths
    }
}

private struct CourseFileTreeNodeView: View {
    let node: CourseFileNode
    let depth: Int
    @Binding var expandedPaths: Set<String>
    let recommendedFilePath: String?
    let onOpenFile: (CourseFileNode) -> Void

    private var isExpanded: Bool {
        expandedPaths.contains(node.relativePath)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if node.isDirectory {
                    withAnimation(.snappy(duration: 0.24)) {
                        if isExpanded {
                            expandedPaths.remove(node.relativePath)
                        } else {
                            expandedPaths.insert(node.relativePath)
                        }
                    }
                } else {
                    onOpenFile(node)
                }
            } label: {
                HStack(spacing: 0) {
                    ForEach(0..<depth, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 1, height: 48)
                            .frame(width: 22)
                    }

                    Group {
                        if node.isDirectory {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .foregroundStyle(.primary)
                        } else {
                            Color.clear
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 44)

                    Image(systemName: symbolName)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(symbolColor)
                        .frame(width: 28, height: 44)

                    Text(node.name)
                        .font(.system(size: 16, weight: node.isDirectory ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 8)

                    Spacer(minLength: 8)

                    if let detailText {
                        Text(detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if !node.isDirectory, node.relativePath == recommendedFilePath {
                        Image(systemName: "play.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.blue, in: Circle())
                            .padding(.leading, 9)
                    }
                }
                .frame(minHeight: 50)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .background {
                    if node.relativePath == recommendedFilePath {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.blue.opacity(0.09))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(node.isDirectory ? (isExpanded ? "Collapses folder" : "Expands folder") : "Opens file")
            .accessibilityIdentifier("course-file-\(node.relativePath)")

            if node.isDirectory, isExpanded {
                ForEach(node.children) { child in
                    CourseFileTreeNodeView(
                        node: child,
                        depth: depth + 1,
                        expandedPaths: $expandedPaths,
                        recommendedFilePath: recommendedFilePath,
                        onOpenFile: onOpenFile
                    )
                }
            }
        }
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, CGFloat(depth + 1) * 22 + 52)
        }
    }

    private var detailText: String? {
        if node.isDirectory {
            let files = node.immediateFileCount
            let folders = node.immediateFolderCount
            var parts: [String] = []
            if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
            if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
            return parts.isEmpty ? "Empty" : parts.joined(separator: ", ")
        }
        guard let byteCount = node.byteCount else { return nil }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private var symbolName: String {
        switch node.kind {
        case .folder: return "folder.fill"
        case .markdown: return "doc.text"
        case .json: return "curlybraces.square"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .sourceCode: return "chevron.left.forwardslash.chevron.right"
        case .text: return "doc.plaintext"
        case .other: return "doc"
        }
    }

    private var symbolColor: Color {
        switch node.kind {
        case .folder: return .yellow
        case .pdf: return .red
        case .image: return .green
        case .markdown, .json, .sourceCode, .text, .other: return .blue
        }
    }

    private var accessibilityLabel: String {
        node.isDirectory ? "\(node.name), folder" : "\(node.name), file"
    }
}

struct CourseFileViewerView: View {
    let course: LearningCourse
    let relativePath: String
    let rootURL: URL
    @Bindable var store: CourseExperienceStore
    let onOpenRelativePath: (String) -> Void

    @State private var loadState: LoadState = .loading
    @State private var fileURL: URL?

    private enum LoadState {
        case loading
        case text(String)
        case image(UIImage)
        case unsupported
        case failed(String)
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView("Opening file…")
            case .text(let text):
                if isMarkdown {
                    ScrollView {
                        Text(text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 22)
                        .padding(.bottom, 44)
                    }
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                }
            case .image(let image):
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                }
            case .unsupported:
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "doc",
                    description: Text("You can share this file or open it in another app.")
                )
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn’t open file",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(URL(fileURLWithPath: relativePath).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let fileURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share course file")
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.isFileURL,
                  let path = CourseWorkspaceSnapshot.relativePath(for: url, rootURL: rootURL) else {
                return .systemAction
            }
            onOpenRelativePath(path)
            return .handled
        })
        .task(id: relativePath) {
            loadFile()
        }
        .onChange(of: store.courseWorkspaceRefreshVersion) { _, _ in
            loadFile()
        }
    }

    private var isMarkdown: Bool {
        ["md", "markdown"].contains(URL(fileURLWithPath: relativePath).pathExtension.lowercased())
    }

    private func loadFile() {
        do {
            let resolved = try CourseWorkspaceSnapshot.validatedFileURL(
                relativePath: relativePath,
                rootURL: rootURL
            )
            fileURL = resolved
            switch resolved.pathExtension.lowercased() {
            case "md", "markdown", "json", "txt", "csv", "yaml", "yml", "toml", "xml",
                 "swift", "py", "js", "ts", "tsx", "jsx", "rs", "kt", "java", "c", "h", "cpp", "sh", "rb":
                loadState = .text(try CourseWorkspaceSnapshot.readText(relativePath: relativePath, rootURL: rootURL))
            case "png", "jpg", "jpeg", "gif", "webp", "heic":
                let data = try Data(contentsOf: resolved, options: [.mappedIfSafe])
                guard data.count <= 20_000_000, let image = UIImage(data: data) else {
                    throw CourseWorkspaceError.fileTooLarge
                }
                loadState = .image(image)
            default:
                loadState = .unsupported
            }
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

}
