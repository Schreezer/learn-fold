import AppIntents

struct EndVoiceSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Voice Session"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        VoiceSessionControl.requestEnd()
        return .result()
    }
}
