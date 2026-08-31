import XCTest
@testable import Litter

#if DEBUG
final class ProviderSettingsSourceCheckpointParserTests: XCTestCase {
    private let base = ProviderSettingsSourceCheckpointScenario.launchArgument

    func testScenarioSetMatchesFrozenTwentySevenStateArguments() {
        let expected: Set<String> = [
            "--ui-test-lf03-picker-available",
            "--ui-test-lf03-picker-unavailable",
            "--ui-test-lf05-saving",
            "--ui-test-lf05-success-return",
            "--ui-test-lf05-error",
            "--ui-test-lf06-connecting",
            "--ui-test-lf06-connected-target",
            "--ui-test-lf06-failed",
            "--ui-test-lf27-model-loading",
            "--ui-test-lf27-model-empty",
            "--ui-test-lf27-model-default",
            "--ui-test-lf27-model-populated",
            "--ui-test-lf27-checking",
            "--ui-test-lf27-cancel",
            "--ui-test-lf27-failure-rollback",
            "--ui-test-lf27-agent-error",
            "--ui-test-lf28-synced",
            "--ui-test-lf28-on-this-device",
            "--ui-test-lf28-sign-in-required",
            "--ui-test-lf28-needs-attention",
            "--ui-test-lf28-retry",
            "--ui-test-lf30-source-menu",
            "--ui-test-lf30-preparing",
            "--ui-test-lf30-passage-context",
            "--ui-test-lf30-permission-error",
            "--ui-test-lf30-parse-error",
            "--ui-test-lf30-preparation-error",
        ]

        let actual = ProviderSettingsSourceCheckpointScenario.allCases
            .map(\.rawValue)
        XCTAssertEqual(actual.count, 27)
        XCTAssertEqual(Set(actual), expected)
    }

    func testEveryScenarioRequiresTheDedicatedBaseAndParsesExactly() {
        for scenario in ProviderSettingsSourceCheckpointScenario.allCases {
            XCTAssertEqual(
                ProviderSettingsSourceCheckpointScenario.current(
                    arguments: [base, scenario.rawValue]
                ),
                scenario
            )
            XCTAssertNil(
                ProviderSettingsSourceCheckpointScenario.current(
                    arguments: [scenario.rawValue]
                )
            )
        }
    }

    @MainActor
    func testTypedHarnessRootStoresTheInjectedScenarioWithoutASecondParse() {
        for scenario in ProviderSettingsSourceCheckpointScenario.allCases {
            let root = ProviderSettingsSourceCheckpointUITestHarnessView(
                scenario: scenario
            )
            XCTAssertEqual(root.scenario, scenario)
        }
    }

    func testCheckpointAndSubstateMappingsMatchContract() {
        let expected: [
            ProviderSettingsSourceCheckpointScenario: (String, String)
        ] = [
            .lf03PickerAvailable: ("LF-03", "picker-available"),
            .lf03PickerUnavailable: ("LF-03", "picker-unavailable"),
            .lf05Saving: ("LF-05", "saving"),
            .lf05SuccessReturn: ("LF-05", "success-return"),
            .lf05Error: ("LF-05", "error"),
            .lf06Connecting: ("LF-06", "connecting"),
            .lf06ConnectedTarget: ("LF-06", "connected-target"),
            .lf06Failed: ("LF-06", "failed"),
            .lf27ModelLoading: ("LF-27", "model-loading"),
            .lf27ModelEmpty: ("LF-27", "model-empty"),
            .lf27ModelDefault: ("LF-27", "model-default"),
            .lf27ModelPopulated: ("LF-27", "model-populated"),
            .lf27Checking: ("LF-27", "checking"),
            .lf27Cancel: ("LF-27", "cancel"),
            .lf27FailureRollback: ("LF-27", "failure-rollback"),
            .lf27AgentError: ("LF-27", "agent-error"),
            .lf28Synced: ("LF-28", "synced"),
            .lf28OnThisDevice: ("LF-28", "on-this-device"),
            .lf28SignInRequired: ("LF-28", "sign-in-required"),
            .lf28NeedsAttention: ("LF-28", "needs-attention"),
            .lf28Retry: ("LF-28", "retry"),
            .lf30SourceMenu: ("LF-30", "source-menu"),
            .lf30Preparing: ("LF-30", "preparing"),
            .lf30PassageContext: ("LF-30", "passage-context"),
            .lf30PermissionError: ("LF-30", "permission-error"),
            .lf30ParseError: ("LF-30", "parse-error"),
            .lf30PreparationError: ("LF-30", "preparation-error"),
        ]

        for (scenario, mapping) in expected {
            XCTAssertEqual(scenario.checkpointID, mapping.0)
            XCTAssertEqual(scenario.substate, mapping.1)
        }
    }

    func testParserRejectsMissingOrDuplicatedBase() {
        XCTAssertNil(
            ProviderSettingsSourceCheckpointScenario.current(arguments: [base])
        )
        XCTAssertNil(
            ProviderSettingsSourceCheckpointScenario.current(
                arguments: [base, base, "--ui-test-lf05-saving"]
            )
        )
    }

    func testParserRejectsDuplicateAndMultipleStates() {
        XCTAssertNil(
            ProviderSettingsSourceCheckpointScenario.current(
                arguments: [
                    base,
                    "--ui-test-lf27-checking",
                    "--ui-test-lf27-checking",
                ]
            )
        )
        XCTAssertNil(
            ProviderSettingsSourceCheckpointScenario.current(
                arguments: [
                    base,
                    "--ui-test-lf05-saving",
                    "--ui-test-lf30-preparing",
                ]
            )
        )
    }

    func testParserRejectsMalformedShapedStateArguments() {
        let malformed = [
            "--ui-test-lf03-picker",
            "--ui-test-lf05-unknown",
            "--ui-test-lf06-",
            "--ui-test-lf27-model",
            "--ui-test-lf28-needs_attention",
            "--ui-test-lf30-permission",
        ]

        for argument in malformed {
            XCTAssertNil(
                ProviderSettingsSourceCheckpointScenario.current(
                    arguments: [base, argument]
                ),
                argument
            )
        }
    }

    func testParserRejectsValidStatePlusMalformedShapedState() {
        XCTAssertNil(
            ProviderSettingsSourceCheckpointScenario.current(
                arguments: [
                    base,
                    "--ui-test-lf28-synced",
                    "--ui-test-lf28-not-a-state",
                ]
            )
        )
        XCTAssertNil(
            ProviderSettingsSourceCheckpointScenario.current(
                arguments: [
                    base,
                    "--ui-test-lf28-synced",
                    "--ui-test-lf34-preparing",
                ]
            )
        )
    }

    func testBoundaryCopyNeverPromotesFixtureToLiveEvidence() {
        for scenario in ProviderSettingsSourceCheckpointScenario.allCases {
            XCTAssertTrue(scenario.nonLiveBoundary.contains("NON-LIVE"))
        }
        XCTAssertTrue(
            ProviderSettingsSourceCheckpointScenario.lf03PickerUnavailable
                .nonLiveBoundary
                .contains("LIVE-FROZEN PRODUCT COMPANION STILL REQUIRED")
        )
        XCTAssertTrue(
            ProviderSettingsSourceCheckpointScenario.lf05Saving
                .nonLiveBoundary
                .contains("LIVE-CONTROLLED EVIDENCE STILL REQUIRED")
        )
        XCTAssertTrue(
            ProviderSettingsSourceCheckpointScenario.lf27AgentError
                .nonLiveBoundary
                .contains("LIVE-PRODUCT COMPANION STILL REQUIRED")
        )
    }

    func testLF03StatesOwnTheContractFixtureHook() {
        for scenario in [
            ProviderSettingsSourceCheckpointScenario.lf03PickerAvailable,
            .lf03PickerUnavailable,
        ] {
            XCTAssertEqual(
                scenario.deterministicHookIdentifier,
                ProviderSettingsSourceCheckpointScenario.lf03HookIdentifier
            )
        }
        XCTAssertNil(
            ProviderSettingsSourceCheckpointScenario.lf05Saving
                .deterministicHookIdentifier
        )
    }
}
#endif
