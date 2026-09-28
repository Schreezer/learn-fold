import NativeBlockEditorCore
import XCTest
@testable import Litter

final class CourseFollowUpQuestionsTests: XCTestCase {
    private func document(_ markdown: String) throws -> BlockDocument {
        try AppFlowyMarkdownCodec().decode(markdown)
    }

    func testExtractsTrailingKeepAskingSectionAndHidesItsBlocks() throws {
        let document = try document("""
        # Yeast

        Yeast makes gas.

        ## Exercise

        Watch dough rise.

        ## Keep asking

        - Why does cold dough rise more slowly?
        - What happens if I add too much salt?
        """)

        let extracted = try XCTUnwrap(CourseFollowUpQuestions.extract(from: document))
        XCTAssertEqual(extracted.questions, [
            "Why does cold dough rise more slowly?",
            "What happens if I add too much salt?",
        ])
        let blocks = document.root.children
        XCTAssertEqual(extracted.hiddenBlockIDs, Set(blocks.suffix(3).map(\.id)))
        XCTAssertFalse(extracted.hiddenBlockIDs.contains(blocks[0].id))
    }

    func testRecognizesAlternateHeadingsCaseInsensitively() throws {
        for heading in ["Questions to explore", "FOLLOW-UP QUESTIONS", "Ask next:", "keep asking?"] {
            let document = try document("""
            Body text.

            ## \(heading)

            1. One?
            """)
            XCTAssertEqual(CourseFollowUpQuestions.extract(from: document)?.questions, ["One?"], heading)
        }
    }

    func testCapsAtThreeQuestionsAndIgnoresEmptyItems() throws {
        let document = BlockDocument(root: BlockNode(type: "page", children: [
            .paragraph("Body."),
            .heading("Keep asking", level: 2),
            .bulletedList("A?"),
            .bulletedList("   "),
            .bulletedList("B?"),
            .bulletedList("C?"),
            .bulletedList("D?"),
        ]))
        let extracted = try XCTUnwrap(CourseFollowUpQuestions.extract(from: document))
        XCTAssertEqual(extracted.questions, ["A?", "B?", "C?"])
        XCTAssertEqual(extracted.hiddenBlockIDs.count, 6)
    }

    func testIgnoresSectionThatIsNotTrailing() throws {
        let document = try document("""
        ## Keep asking

        - Early question?

        ## Summary

        More prose after the list.
        """)
        XCTAssertNil(CourseFollowUpQuestions.extract(from: document))
    }

    func testAllowsChildPageLinksAfterTheSection() throws {
        var document = try document("""
        Body.

        ## Keep asking

        - Linked question?
        """)
        document.root.children.append(.childPage(pageID: "child", title: "Explainer", icon: "doc.text"))
        let extracted = try XCTUnwrap(CourseFollowUpQuestions.extract(from: document))
        XCTAssertEqual(extracted.questions, ["Linked question?"])
        XCTAssertFalse(extracted.hiddenBlockIDs.contains(document.root.children.last!.id))
    }

    func testReturnsNilWithoutAHeadingOrWithoutQuestions() throws {
        XCTAssertNil(CourseFollowUpQuestions.extract(from: try document("Just prose.\n\n- A list item")))
        XCTAssertNil(CourseFollowUpQuestions.extract(from: try document("## Keep asking\n\nNo list here.")))
    }

    func testStarterLessonsNoLongerEndWithAQuestionSection() throws {
        for lesson in LearnfoldStarterCourse.lessons {
            XCTAssertNil(
                CourseFollowUpQuestions.extract(from: try document(lesson.markdown)),
                lesson.title
            )
        }
    }

    func testAppleLessonMarkdownNeverAppendsAQuestionSection() throws {
        let markdown = AppleCourseLessonContentPolicy.markdown(
            content: AppleCourseGeneratedLessonContent(
                explanation: "Yeast makes gas.",
                example: "Two doughs, one warm.",
                exercise: "Compare them."
            ),
            exampleKind: .topicDemonstration
        )
        XCTAssertFalse(markdown.contains("Keep asking"))
        XCTAssertNil(CourseFollowUpQuestions.extract(from: try document(markdown)))

        // A model that volunteers the old key must not reintroduce the section.
        let decoded = try JSONDecoder().decode(
            AppleCourseGeneratedLessonContent.self,
            from: Data(#"{"explanation":"E","example":"X","exercise":"Q","visualization_html":"","follow_up_questions":["A?","B?"]}"#.utf8)
        )
        let fromDecoded = AppleCourseLessonContentPolicy.markdown(
            content: decoded,
            exampleKind: .topicDemonstration
        )
        XCTAssertFalse(fromDecoded.contains("Keep asking"))
    }

    func testPageChatContextCarriesTrimmedInitialQuestion() {
        let context = CoursePageChatContext(pageID: "p", pageTitle: "T", content: "c", initialQuestion: "  Why? ")
        XCTAssertEqual(context.initialQuestion, "Why?")
        XCTAssertNil(CoursePageChatContext(pageID: "p", pageTitle: "T", content: "c", initialQuestion: "  ").initialQuestion)
        XCTAssertNil(CoursePageChatContext(pageID: "p", pageTitle: "T", content: "c").initialQuestion)
    }
}
