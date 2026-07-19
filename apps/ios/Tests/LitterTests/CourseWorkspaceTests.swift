import XCTest
@testable import Litter

final class CourseWorkspaceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testSnapshotBuildsLearnerFacingTreeAndSkipsInternalMetadata() throws {
        let root = try makeWorkspace()
        try write("# Course", to: root.appendingPathComponent("index.md"))
        try write("{}", to: root.appendingPathComponent("course.json"))
        try write("{}", to: root.appendingPathComponent(".course/build-manifest.json"))
        try write("pdf", to: root.appendingPathComponent("sources/originals/notes.pdf"))
        try write("# Lesson", to: root.appendingPathComponent("chapters/01-start/lesson.md"))
        try write("# Practice", to: root.appendingPathComponent("chapters/01-start/practice.md"))
        try write("print('hello')", to: root.appendingPathComponent("chapters/01-start/examples/pipeline.py"))

        let snapshot = try CourseWorkspaceSnapshot.load(from: root)

        XCTAssertEqual(snapshot.nodes.map(\.name), ["index.md", "course.json", "sources", "chapters"])
        XCTAssertEqual(snapshot.fileCount, 6)
        XCTAssertEqual(snapshot.folderCount, 5)
        XCTAssertEqual(snapshot.firstLessonPath, "chapters/01-start/lesson.md")
        XCTAssertFalse(snapshot.directoryPaths.contains(".course"))
        XCTAssertFalse(snapshot.flattenedFiles.contains(where: { $0.relativePath.contains("build-manifest") }))
    }

    func testValidatedFileURLRejectsTraversalAndResolvesCourseFile() throws {
        let root = try makeWorkspace()
        try write("# Lesson", to: root.appendingPathComponent("chapters/01-start/lesson.md"))

        let valid = try CourseWorkspaceSnapshot.validatedFileURL(
            relativePath: "chapters/01-start/lesson.md",
            rootURL: root
        )
        XCTAssertEqual(valid.lastPathComponent, "lesson.md")
        XCTAssertEqual(
            CourseWorkspaceSnapshot.relativePath(for: valid, rootURL: root),
            "chapters/01-start/lesson.md"
        )
        XCTAssertThrowsError(
            try CourseWorkspaceSnapshot.validatedFileURL(relativePath: "../outside.md", rootURL: root)
        ) { error in
            XCTAssertEqual(error as? CourseWorkspaceError, .invalidRelativePath)
        }
    }

    func testReadTextLoadsUTF8Markdown() throws {
        let root = try makeWorkspace()
        let markdown = "# Diffusion\n\n**Noise** becomes an image."
        try write(markdown, to: root.appendingPathComponent("lesson.md"))

        XCTAssertEqual(
            try CourseWorkspaceSnapshot.readText(relativePath: "lesson.md", rootURL: root),
            markdown
        )
    }

    func testProgressiveWorkspacePutsLearnerContextBeforeSourcesAndOutlinesBeforeLessons() throws {
        let root = try makeWorkspace()
        try write("# Profile", to: root.appendingPathComponent("context/learner-profile.md"))
        try write("# Source", to: root.appendingPathComponent("sources/extracted/source.md"))
        try write("# Lesson", to: root.appendingPathComponent("chapters/01-start/lesson.md"))
        try write("# Outline", to: root.appendingPathComponent("chapters/01-start/README.md"))

        let snapshot = try CourseWorkspaceSnapshot.load(from: root)
        let chaptersFolder = try XCTUnwrap(snapshot.nodes.first(where: { $0.name == "chapters" }))
        let firstChapter = try XCTUnwrap(chaptersFolder.children.first)
        let chapterFiles = firstChapter.children.map(\.name)

        XCTAssertEqual(snapshot.nodes.map(\.name), ["context", "sources", "chapters"])
        XCTAssertEqual(chapterFiles, ["README.md", "lesson.md"])
    }

    func testLearningPathKeepsHierarchyAndVerifiesGeneratedMarkdownExists() throws {
        let root = try makeWorkspace()
        try write("# Ready", to: root.appendingPathComponent("chapters/01-start/ready.md"))
        let snapshot = try CourseWorkspaceSnapshot.load(from: root)
        var brief = CourseBrief()
        brief.learningPath = [
            CourseLearningNode(
                id: "chapter-1",
                title: "Chapter 1",
                kind: .folder,
                status: .generated,
                children: [
                    CourseLearningNode(
                        id: "ready",
                        title: "Ready module",
                        kind: .markdown,
                        status: .generated,
                        relativePath: "chapters/01-start/ready.md"
                    ),
                    CourseLearningNode(
                        id: "missing",
                        title: "Missing module",
                        kind: .markdown,
                        status: .generated,
                        relativePath: "chapters/01-start/missing.md"
                    ),
                ]
            )
        ]

        let resolved = CourseLearningPathResolver.resolve(brief: brief, snapshot: snapshot)
        let chapter = try XCTUnwrap(resolved.first)

        XCTAssertEqual(chapter.status, .partiallyGenerated)
        XCTAssertEqual(chapter.children.map(\.status), [.generated, .pendingGeneration])
    }

    func testLegacyWorkspaceDerivesNestedMarkdownModules() throws {
        let root = try makeWorkspace()
        try write("# Chapter", to: root.appendingPathComponent("chapters/01-start/README.md"))
        try write("# Lesson", to: root.appendingPathComponent("chapters/01-start/basics/lesson.md"))
        let snapshot = try CourseWorkspaceSnapshot.load(from: root)
        var brief = CourseBrief()
        brief.chapters = [
            CourseChapter(id: "start", title: "Start here", objective: "Begin.", deliverables: [])
        ]

        let resolved = CourseLearningPathResolver.resolve(brief: brief, snapshot: snapshot)
        let nestedFolder = try XCTUnwrap(resolved.first?.children.first)

        XCTAssertEqual(resolved.first?.status, .generated)
        XCTAssertEqual(nestedFolder.kind, .folder)
        XCTAssertEqual(nestedFolder.children.first?.relativePath, "chapters/01-start/basics/lesson.md")
    }

    func testGeneratingOverlayMarksTargetAndAncestorWithoutChangingSiblings() throws {
        let nodes = [
            CourseLearningNode(
                id: "chapter-1",
                title: "Chapter 1",
                kind: .folder,
                status: .partiallyGenerated,
                children: [
                    CourseLearningNode(
                        id: "module-1",
                        title: "Module 1",
                        kind: .markdown,
                        status: .generated,
                        relativePath: "chapters/01/module-1.md"
                    ),
                    CourseLearningNode(
                        id: "module-2",
                        title: "Module 2",
                        kind: .folder,
                        status: .pendingGeneration
                    ),
                ]
            ),
            CourseLearningNode(
                id: "chapter-2",
                title: "Chapter 2",
                kind: .folder,
                status: .pendingGeneration
            ),
        ]

        let overlaid = CourseLearningPathResolver.overlayGeneratingStatus(
            in: nodes,
            targetNodeID: "module-2"
        )

        XCTAssertEqual(overlaid[0].status, .partiallyGenerated)
        XCTAssertEqual(overlaid[0].children[0].status, .generated)
        XCTAssertEqual(overlaid[0].children[1].status, .generating)
        XCTAssertEqual(overlaid[1].status, .pendingGeneration)
    }

    @MainActor
    func testRemodexCourseMarkdownRendererParsesStructuredDocument() throws {
        let markdown = """
        # Diffusion Models

        Learn the **forward process** and then implement it:

        1. Add noise
        2. Predict noise

        ```python
        sample = denoise(noise)
        ```
        """
        let rendered = try CourseMarkdownRenderer.attributedString(markdown: markdown)

        XCTAssertTrue(String(rendered.characters).contains("Diffusion Models"))
        XCTAssertTrue(String(rendered.characters).contains("sample = denoise(noise)"))
        XCTAssertTrue(rendered.runs.contains(where: { $0.presentationIntent != nil }))
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}
