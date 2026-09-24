import XCTest
@testable import Litter

@MainActor
final class StoredLocalAuthPreferenceTests: XCTestCase {
    func testConfiguredCustomProviderTakesPrecedenceOverStoredChatGPTTokens() {
        XCTAssertEqual(
            AppModel.storedLocalAuthPreference(
                baseURL: "https://provider.example/v1",
                apiKey: "provider-key",
                hasChatGPTTokens: true
            ),
            .customProvider
        )
    }

    func testStoredKeyUsesDefaultEndpointAheadOfOldChatGPTTokens() {
        XCTAssertEqual(
            AppModel.storedLocalAuthPreference(
                baseURL: nil,
                apiKey: "stored-api-key",
                hasChatGPTTokens: true
            ),
            .apiKey
        )
    }

    func testExplicitChatGPTChoiceOverridesStoredAPIKey() {
        XCTAssertEqual(
            AppModel.storedLocalAuthPreference(
                baseURL: "https://provider.example/v1",
                apiKey: "stored-api-key",
                hasChatGPTTokens: true,
                explicitPreference: .chatGPT
            ),
            .chatGPT
        )
    }

    func testExplicitAPIKeySaveSwitchesBackFromChatGPT() {
        XCTAssertEqual(
            AppModel.storedLocalAuthPreference(
                baseURL: nil,
                apiKey: "stored-api-key",
                hasChatGPTTokens: true,
                explicitPreference: .apiKey
            ),
            .apiKey
        )
    }

    func testChatGPTRestoresWithoutStoredAPIKey() {
        XCTAssertEqual(
            AppModel.storedLocalAuthPreference(
                baseURL: nil,
                apiKey: nil,
                hasChatGPTTokens: true
            ),
            .chatGPT
        )
    }

    func testExplicitAPIKeyChoiceDoesNotFallBackToChatGPTIfKeyWasRemoved() {
        XCTAssertEqual(
            AppModel.storedLocalAuthPreference(
                baseURL: nil,
                apiKey: nil,
                hasChatGPTTokens: true,
                explicitPreference: .apiKey
            ),
            .none
        )
    }
}
