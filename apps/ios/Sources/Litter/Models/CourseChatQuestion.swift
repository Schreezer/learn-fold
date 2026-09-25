import Foundation

/// A multiple-choice question a course agent asks in chat.
///
/// Agents write the question as a `learnfold-question` fenced block inside an
/// ordinary reply, so it travels with the message text through every
/// provider's transcript, persistence, and restore path without a new wire
/// type. The chat hides the fence, keeps the question sentence in the message,
/// and renders the options as tappable replies under the newest agent message.
///
/// Canonical form:
///
/// ```learnfold-question
/// What experience do you already have with cryptography?
/// - New to cryptography and blockchain
/// - I understand basic cryptography
/// ```
///
/// A JSON object with `question` and `options` keys is accepted inside the
/// fence as well, because some models prefer it.
struct CourseChatQuestion: Equatable, Sendable {
    static let fenceLanguage = "learnfold-question"
    static let minimumOptionCount = 2
    static let maximumOptionCount = 5
    static let freeTextPrompt = "Or type your own response here…"

    /// The question sentence. Empty when the lead-in prose carries it.
    let prompt: String
    /// Two to five short, distinct answers in the order the agent wrote them.
    let options: [String]

    /// The result of removing question fences from a message.
    struct Extraction: Equatable, Sendable {
        /// The message with every fence removed and the question sentence kept
        /// as a trailing paragraph.
        let text: String
        /// The last complete, valid question in the message.
        let question: CourseChatQuestion?
        /// True while a fence has been opened but not closed, which happens
        /// mid-stream. The partial block is hidden from `text`.
        let isIncomplete: Bool
    }

    /// The canonical block an agent writes. Used by prompts and tests.
    static func markdownBlock(prompt: String, options: [String]) -> String {
        var lines = ["```\(fenceLanguage)"]
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            lines.append(trimmedPrompt)
        }
        lines.append(contentsOf: options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "- \($0)" })
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    /// Removes every `learnfold-question` fence from `markdown` and returns
    /// the last complete valid question. Malformed fences are unwrapped into
    /// plain text so nothing the agent wrote is lost.
    static func extract(from markdown: String) -> Extraction {
        guard markdown.range(of: fenceLanguage, options: .caseInsensitive) != nil else {
            return Extraction(text: markdown, question: nil, isIncomplete: false)
        }

        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var output: [String] = []
        var question: CourseChatQuestion?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard isOpeningFence(line) else {
                output.append(line)
                index += 1
                continue
            }

            guard let closingIndex = lines[(index + 1)...].firstIndex(where: isClosingFence) else {
                // Streaming: the block is still being written. Hide it until
                // it closes rather than flashing raw fence text.
                return Extraction(
                    text: cleaned(output, appending: question?.prompt),
                    question: nil,
                    isIncomplete: true
                )
            }

            let body = Array(lines[(index + 1)..<closingIndex])
            if let parsed = parse(body) {
                question = parsed
            } else {
                // Keep malformed content readable as ordinary Markdown.
                output.append(contentsOf: body)
            }
            index = closingIndex + 1
        }

        return Extraction(
            text: cleaned(output, appending: question?.prompt),
            question: question,
            isIncomplete: false
        )
    }

    // MARK: - Parsing

    private static func isOpeningFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let language = fenceLanguage(in: trimmed) else { return false }
        return language.caseInsensitiveCompare(fenceLanguage) == .orderedSame
    }

    private static func isClosingFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "```" || trimmed == "~~~"
    }

    private static func fenceLanguage(in trimmedLine: String) -> String? {
        for marker in ["```", "~~~"] where trimmedLine.hasPrefix(marker) {
            return trimmedLine
                .dropFirst(marker.count)
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func parse(_ body: [String]) -> CourseChatQuestion? {
        let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        if joined.hasPrefix("{") {
            return parseJSON(joined)
        }
        return parseList(body)
    }

    private static func parseJSON(_ text: String) -> CourseChatQuestion? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return nil
        }
        let prompt = (object["question"] ?? object["prompt"]) as? String ?? ""
        let rawOptions: [String]
        if let strings = object["options"] as? [String] {
            rawOptions = strings
        } else if let objects = object["options"] as? [[String: Any]] {
            rawOptions = objects.compactMap { ($0["label"] ?? $0["text"] ?? $0["title"]) as? String }
        } else {
            return nil
        }
        return make(prompt: prompt, options: rawOptions)
    }

    private static func parseList(_ body: [String]) -> CourseChatQuestion? {
        var promptLines: [String] = []
        var options: [String] = []
        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let item = listItem(trimmed) {
                options.append(item)
            } else if options.isEmpty {
                promptLines.append(trimmed)
            }
            // Prose after the options is dropped: the agent was told to put
            // nothing there, and rendering it would sit awkwardly under pills.
        }
        return make(prompt: promptLines.joined(separator: " "), options: options)
    }

    private static func listItem(_ trimmedLine: String) -> String? {
        for marker in ["- ", "* ", "• ", "+ "] where trimmedLine.hasPrefix(marker) {
            return trimmedLine.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        }
        // Ordered list: "1. " or "1) ".
        var digits = Substring(trimmedLine)
        var count = 0
        while let first = digits.first, first.isNumber, count < 3 {
            digits = digits.dropFirst()
            count += 1
        }
        guard count > 0, let separator = digits.first, separator == "." || separator == ")" else {
            return nil
        }
        let rest = digits.dropFirst()
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func make(prompt: String, options rawOptions: [String]) -> CourseChatQuestion? {
        var seen = Set<String>()
        var options: [String] = []
        for option in rawOptions {
            let trimmed = option
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            options.append(trimmed)
            if options.count == maximumOptionCount { break }
        }
        guard options.count >= minimumOptionCount else { return nil }
        return CourseChatQuestion(
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            options: options
        )
    }

    private static func cleaned(_ lines: [String], appending prompt: String?) -> String {
        var text = lines.joined(separator: "\n")
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prompt, !prompt.isEmpty {
            text = text.isEmpty ? prompt : "\(text)\n\n\(prompt)"
        }
        return text
    }
}

/// The instructions every course agent receives for asking multiple-choice
/// questions. Kept in one place so Codex, Hermes, and the Apple models agree
/// on the exact block format the chat parses.
enum CourseChatQuestionPromptPolicy {
    static let exampleBlock = CourseChatQuestion.markdownBlock(
        prompt: "What experience do you already have with cryptography or blockchains?",
        options: [
            "No cryptography or blockchain background",
            "Understand the basics but haven't built with them",
            "Built applications but haven't studied advanced cryptography",
            "Studied advanced cryptography, including zero-knowledge proofs",
        ]
    )

    /// Full guidance for large-context providers.
    static let instructions = """
    Assess the learner one question at a time. Ask only one assessment question in each reply, wait for the learner's answer before asking another, and use what they already told you instead of repeating questions. Never bundle questions in a numbered list or add another question in the lead-in or prose around a question fence.

    For a bounded-answer question about prior experience, goal, depth, pace, or a similar preference, use a native multiple-choice prompt. Ask at least one such fenced question during assessment unless the learner has already supplied every relevant bounded preference. Write a brief declarative lead-in, then end the reply with a fenced block tagged `\(CourseChatQuestion.fenceLanguage)`: the sole question on its first line, then \(CourseChatQuestion.minimumOptionCount) to \(CourseChatQuestion.maximumOptionCount) short, genuinely distinct, non-overlapping answers as a bulleted list, ordered from least to most experience where that applies. Do not present bounded choices as plain-text numbered questions or options. Put nothing after the closing fence. Learnfold renders the options as tappable replies and always lets the learner type a different answer; the reply arrives as their next message.

    This block is literal text in your assistant reply, not a tool call or the Codex `request_user_input` tool. It works in New Course and course-building chat. Do not claim the choice interface is unavailable in course-building mode. If you previously asked several questions as prose, re-ask only the most useful unanswered bounded question using this block, then wait for the answer.

    Keep at least one diagnostic question open-ended so the learner can demonstrate understanding in their own words. Ask that question in its own reply, without a fence or other assessment questions. Example of a bounded question:

    \(exampleBlock)
    """

    /// A shorter form for the Apple models, whose context is small.
    static let compactInstructions = """
    Assess one question per reply; wait for the learner's answer before the next. Do not bundle \
    numbered questions or add another question around a fence. For bounded answers such as \
    experience, goal, depth, or pace, use a \(CourseChatQuestion.fenceLanguage) fence: the sole \
    question on its first line, then \(CourseChatQuestion.minimumOptionCount) to \
    \(CourseChatQuestion.maximumOptionCount) genuinely distinct, non-overlapping bulleted \
    options. Put nothing after the fence. This is text in your reply, not a tool; it works in \
    New Course and course-building chat. Do not claim it is unavailable there. Ask at least one \
    fenced question unless the learner \
    already gave every bounded preference. Learnfold shows options as tappable replies; the \
    learner may type instead. Ask one open-ended diagnostic question in a separate reply, \
    without a fence.
    """
}

/// Decides which question, if any, is awaiting the learner's reply.
enum CourseChatQuestionPolicy {
    /// The question in the newest message when that message is an agent reply.
    /// A learner message after it means it was answered.
    static func pendingQuestion(in messages: [CourseChatMessage]) -> CourseChatQuestion? {
        guard let last = messages.last, last.role == .agent else { return nil }
        return CourseChatQuestion.extract(from: last.text).question
    }

    /// The remote-timeline equivalent of `pendingQuestion(in:)`.
    static func pendingQuestion(in items: [ConversationItem]) -> CourseChatQuestion? {
        guard let last = items.last(where: isLearnerOrAgentMessage),
              case .assistant(let data) = last.content else { return nil }
        return CourseChatQuestion.extract(from: data.text).question
    }

    /// Hides question fences from assistant items before the generic timeline
    /// renders them as code blocks.
    static func strippingQuestions(from items: [ConversationItem]) -> [ConversationItem] {
        items.map { item in
            guard case .assistant(var data) = item.content,
                  data.text.range(of: CourseChatQuestion.fenceLanguage, options: .caseInsensitive) != nil
            else { return item }
            data.text = CourseChatQuestion.extract(from: data.text).text
            return ConversationItem(
                id: item.id,
                content: .assistant(data),
                sourceTurnId: item.sourceTurnId,
                sourceTurnIndex: item.sourceTurnIndex,
                timestamp: item.timestamp,
                isFromUserTurnBoundary: item.isFromUserTurnBoundary
            )
        }
    }

    private static func isLearnerOrAgentMessage(_ item: ConversationItem) -> Bool {
        switch item.content {
        case .user, .assistant: true
        default: false
        }
    }
}
