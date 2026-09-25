import XCTest
@testable import Litter

@MainActor
final class CourseChatQuestionTests: XCTestCase {
    private let block = """
    ```learnfold-question
    What experience do you already have with cryptography?
    - New to cryptography and blockchain
    - I understand basic cryptography
    - I've built blockchain or smart-contract applications
    - I've studied zero-knowledge proofs
    ```
    """

    func testExtractsListBlockAndKeepsQuestionSentenceInText() {
        let extraction = CourseChatQuestion.extract(from: "Great topic. Let's tailor it.\n\n\(block)")

        XCTAssertEqual(extraction.question?.prompt, "What experience do you already have with cryptography?")
        XCTAssertEqual(extraction.question?.options, [
            "New to cryptography and blockchain",
            "I understand basic cryptography",
            "I've built blockchain or smart-contract applications",
            "I've studied zero-knowledge proofs",
        ])
        XCTAssertEqual(
            extraction.text,
            "Great topic. Let's tailor it.\n\nWhat experience do you already have with cryptography?"
        )
        XCTAssertFalse(extraction.text.contains("```"))
        XCTAssertFalse(extraction.isIncomplete)
    }

    func testLeavesMessagesWithoutAFenceUntouched() {
        let text = "Plain reply with a ```swift\nlet x = 1\n``` code block."
        let extraction = CourseChatQuestion.extract(from: text)
        XCTAssertEqual(extraction.text, text)
        XCTAssertNil(extraction.question)
    }

    func testAcceptsJSONNumberedAndTildeVariants() {
        let json = """
        ```learnfold-question
        {"question": "How deep?", "options": ["Overview", "Hands-on", "Research level"]}
        ```
        """
        XCTAssertEqual(CourseChatQuestion.extract(from: json).question, CourseChatQuestion(
            prompt: "How deep?",
            options: ["Overview", "Hands-on", "Research level"]
        ))

        let numbered = """
        ~~~ Learnfold-Question
        Pace?
        1. Slow
        2) Fast
        ~~~
        """
        XCTAssertEqual(
            CourseChatQuestion.extract(from: numbered).question,
            CourseChatQuestion(prompt: "Pace?", options: ["Slow", "Fast"])
        )
    }

    func testHidesAnUnclosedFenceWhileStreaming() {
        let streaming = "Quick check first.\n\n```learnfold-question\nWhat do you know?\n- Nothing\n- A bit"
        let extraction = CourseChatQuestion.extract(from: streaming)
        XCTAssertEqual(extraction.text, "Quick check first.")
        XCTAssertNil(extraction.question)
        XCTAssertTrue(extraction.isIncomplete)
    }

    func testUnwrapsBlocksWithTooFewOptionsAsPlainText() {
        let single = "Intro.\n\n```learnfold-question\nReady?\n- Yes\n```"
        let extraction = CourseChatQuestion.extract(from: single)
        XCTAssertNil(extraction.question)
        XCTAssertEqual(extraction.text, "Intro.\n\nReady?\n- Yes")
    }

    func testCapsDedupesAndTrimsOptions() {
        let block = """
        ```learnfold-question
        Which?
        - "A"
        -  a
        - B
        - C
        - D
        - E
        - F
        ```
        """
        XCTAssertEqual(
            CourseChatQuestion.extract(from: block).question?.options,
            ["A", "B", "C", "D", "E"]
        )
    }

    func testLastCompleteBlockWinsAndEveryFenceIsRemoved() {
        let first = CourseChatQuestion.markdownBlock(prompt: "First?", options: ["1", "2"])
        let second = CourseChatQuestion.markdownBlock(prompt: "Second?", options: ["3", "4"])
        let extraction = CourseChatQuestion.extract(from: "\(first)\n\nBetween.\n\n\(second)")
        XCTAssertEqual(extraction.question?.prompt, "Second?")
        XCTAssertEqual(extraction.text, "Between.\n\nSecond?")
    }

    func testMarkdownBlockRoundTripsAndPromptExampleParses() {
        let block = CourseChatQuestion.markdownBlock(prompt: " Goal? ", options: ["Ship", " Learn ", ""])
        XCTAssertEqual(
            CourseChatQuestion.extract(from: block).question,
            CourseChatQuestion(prompt: "Goal?", options: ["Ship", "Learn"])
        )

        let example = CourseChatQuestion.extract(from: CourseChatQuestionPromptPolicy.instructions)
        XCTAssertEqual(example.question?.options.count, 4)
        XCTAssertTrue(CourseChatQuestionPromptPolicy.compactInstructions.contains(CourseChatQuestion.fenceLanguage))
        XCTAssertTrue(CourseExperienceStore.courseAgentInstructions.contains(CourseChatQuestion.fenceLanguage))
        XCTAssertTrue(CourseExperienceStore.courseAgentInstructions.contains("not a tool call"))
        XCTAssertTrue(CourseExperienceStore.courseAgentInstructions.contains("works in New Course and course-building chat"))
    }

    func testQuestionPolicyTravelsOutsideLearnerText() {
        let firstTurn = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondTurn = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let policy = CourseExperienceStore.codexQuestionApplicationContext(attemptID: firstTurn)
        let payload = AppComposerPayload(
            text: "Explain OLED.",
            additionalInputs: [],
            approvalPolicy: nil,
            sandboxPolicy: nil,
            model: nil,
            effort: nil,
            serviceTier: nil,
            applicationContext: policy
        )

        let request = payload.turnStartRequest(threadId: "course-thread")
        XCTAssertLessThan(policy.utf8.count, 3_000)
        XCTAssertTrue(policy.contains(CourseChatQuestionPromptPolicy.instructions))
        XCTAssertNotEqual(
            policy,
            CourseExperienceStore.codexQuestionApplicationContext(attemptID: secondTurn)
        )
        XCTAssertEqual(request.applicationContext, policy)
        XCTAssertEqual(request.input, [.text(text: "Explain OLED.", textElements: [])])
    }

    func testEveryCourseQuestionPromptRequiresOneAssessmentQuestionPerTurn() {
        for guidance in [CourseChatQuestionPromptPolicy.instructions, CourseChatQuestionPromptPolicy.compactInstructions] {
            XCTAssertTrue(guidance.contains("one question per reply") || guidance.contains("one assessment question in each reply"))
            XCTAssertTrue(guidance.contains("wait for the learner's answer"))
            XCTAssertTrue(guidance.contains("numbered questions"))
            XCTAssertTrue(guidance.contains("bounded"))
            XCTAssertTrue(guidance.contains("genuinely distinct, non-overlapping"))
            XCTAssertTrue(guidance.contains("separate reply") || guidance.contains("own reply"))
            XCTAssertTrue(guidance.contains(CourseChatQuestion.fenceLanguage))
        }
    }

    func testPendingQuestionOnlyForTheNewestAgentMessage() {
        let agent = CourseChatMessage(role: .agent, text: "Lead-in.\n\n\(block)")
        XCTAssertEqual(CourseChatQuestionPolicy.pendingQuestion(in: [agent])?.options.count, 4)

        let answered = [agent, CourseChatMessage(role: .learner, text: "I understand basic cryptography")]
        XCTAssertNil(CourseChatQuestionPolicy.pendingQuestion(in: answered))

        let plain = [agent, CourseChatMessage(role: .agent, text: "Thanks!")]
        XCTAssertNil(CourseChatQuestionPolicy.pendingQuestion(in: plain))
        XCTAssertNil(CourseChatQuestionPolicy.pendingQuestion(in: [CourseChatMessage]()))
    }

    func testRemoteTimelinePendingQuestionAndStripping() {
        let assistant = ConversationItem(
            id: "a1",
            content: .assistant(ConversationAssistantMessageData(
                text: "Lead-in.\n\n\(block)",
                agentNickname: nil,
                agentRole: nil,
                phase: nil
            ))
        )
        let learner = ConversationItem(
            id: "u1",
            content: .user(ConversationUserMessageData(text: "Nothing yet", images: []))
        )

        XCTAssertEqual(CourseChatQuestionPolicy.pendingQuestion(in: [learner, assistant])?.options.count, 4)
        XCTAssertNil(CourseChatQuestionPolicy.pendingQuestion(in: [assistant, learner]))

        let stripped = CourseChatQuestionPolicy.strippingQuestions(from: [learner, assistant])
        XCTAssertEqual(stripped.map(\.id), ["u1", "a1"])
        guard case .assistant(let data) = stripped[1].content else {
            return XCTFail("expected an assistant item")
        }
        XCTAssertEqual(data.text, "Lead-in.\n\nWhat experience do you already have with cryptography?")
        XCTAssertEqual(stripped[0], learner)
    }
}
