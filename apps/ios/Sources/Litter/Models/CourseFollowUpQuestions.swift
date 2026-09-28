import Foundation
import NativeBlockEditorCore

/// A legacy trailing "Keep asking" section: a heading followed by a short
/// list of follow-up questions.
///
/// Course agents used to append this to every page and the reader turned it
/// into tappable prompts. Generation and the prompts are both gone, but pages
/// written earlier still carry the Markdown, so the reader keeps recognizing
/// the section in order to hide it.
struct CourseFollowUpQuestions: Equatable, Sendable {
    static let headingTitle = "Keep asking"
    static let maximumCount = 3

    /// Heading texts the reader recognizes, compared case-insensitively.
    static let recognizedHeadings: Set<String> = [
        "keep asking",
        "questions to explore",
        "follow-up questions",
        "follow up questions",
        "ask next",
        "what to ask next",
    ]

    let questions: [String]
    /// The heading and list blocks that hold the questions in the document.
    let hiddenBlockIDs: Set<UUID>

    /// Finds a trailing questions section. Only the last matching heading
    /// counts, and only when nothing but its list (and page links) follows it.
    static func extract(from document: BlockDocument) -> CourseFollowUpQuestions? {
        let blocks = document.root.children
        guard let headingIndex = blocks.lastIndex(where: { block in
            block.type == "heading" && recognizedHeadings.contains(normalized(block.delta?.plainText))
        }) else { return nil }

        var questions: [String] = []
        var hidden: Set<UUID> = [blocks[headingIndex].id]
        for block in blocks[(headingIndex + 1)...] {
            switch block.type {
            case "bulleted_list", "numbered_list", "todo_list":
                let text = block.delta?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty, questions.count < maximumCount {
                    questions.append(text)
                }
                hidden.insert(block.id)
            case "paragraph":
                let text = block.delta?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard text.isEmpty else { return nil }
                hidden.insert(block.id)
            case "nbe/child_page", "nbe/page_reference":
                continue
            default:
                return nil
            }
        }
        guard !questions.isEmpty else { return nil }
        return CourseFollowUpQuestions(questions: questions, hiddenBlockIDs: hidden)
    }

    private static func normalized(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":?"))
            .lowercased() ?? ""
    }
}
