import SwiftUI

/// Tappable answers for the newest agent question in the course chat.
/// Tapping an option sends it as the learner's reply; the composer stays
/// available for a typed answer instead.
struct CourseChatQuestionOptionsView: View {
    let question: CourseChatQuestion
    let isEnabled: Bool
    let onSelect: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    onSelect(option)
                } label: {
                    Text(option)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(3)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .background(
                    colorScheme == .dark
                        ? Color(uiColor: .secondarySystemGroupedBackground)
                        : Color(uiColor: .systemBackground).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.16), lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.5)
                .disabled(!isEnabled)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Answer: \(option)")
                .accessibilityIdentifier("course-chat-question-option-\(index)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question.prompt.isEmpty ? "Choose an answer" : question.prompt)
        .accessibilityIdentifier("course-chat-question-options")
    }
}
