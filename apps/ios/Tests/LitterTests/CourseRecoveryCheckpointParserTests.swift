import XCTest
@testable import Litter

#if DEBUG
final class CourseRecoveryCheckpointParserTests: XCTestCase {
    private let base = CourseRecoveryCheckpointUITestScenario.launchArgument
    private let enabledEnvironment = ["LEARNFOLD_UI_TESTING": "1"]

    func testScenarioSetIncludesFrozenAndSupplementalUIArguments() {
        let expected: Set<String> = [
            "--ui-test-lf34-preparing",
            "--ui-test-lf34-known-not-accepted",
            "--ui-test-lf34-acceptance-unknown",
            "--ui-test-lf34-accepted-reply-incomplete",
            "--ui-test-lf34-destructive-confirmation",
            "--ui-test-lf35-missing-discussion",
            "--ui-test-lf35-recovering",
            "--ui-test-lf35-recovery-failure",
            "--ui-test-lf35-unreadable-evidence",
            "--ui-test-lf35-provenance",
            "--ui-test-lf35-confirmation",
            "--ui-test-lf35-finish-deletion",
            "--ui-test-lf36-authentication-recovery",
            "--ui-test-lf36-transport-recovery",
            "--ui-test-lf53-conflict-dialog",
            "--ui-test-lf53-continue-existing",
            "--ui-test-lf53-close-and-start-new",
            "--ui-test-lf53-cancel",
            "--ui-test-lf53-replacement-failure",
        ]
        let rawValues = CourseRecoveryCheckpointUITestScenario.allCases.map(\.rawValue)

        XCTAssertEqual(rawValues.count, 19)
        XCTAssertEqual(Set(rawValues), expected)
    }

    func testStrictHarnessPolicyUsesOnlyDedicatedBaseArgument() {
        XCTAssertTrue(
            LearnfoldStrictHarnessPolicy.isRecoveryCheckpointActive(
                arguments: [base],
                environment: enabledEnvironment
            )
        )
        XCTAssertFalse(
            LearnfoldStrictHarnessPolicy.isRecoveryCheckpointActive(
                arguments: ["--ui-test-course-draft-recovery"],
                environment: enabledEnvironment
            )
        )
        XCTAssertFalse(
            LearnfoldStrictHarnessPolicy.isRecoveryCheckpointActive(
                arguments: ["LEARNFOLD_UI_TESTING=1"],
                environment: enabledEnvironment
            )
        )
    }

    func testStrictHarnessSentinelRecordsInstrumentedEntryWithDedicatedBase() {
        let arguments = [
            base,
            CourseRecoveryCheckpointUITestScenario.lf34Preparing.rawValue,
        ]
        LearnfoldStrictHarnessSentinel.resetForTesting()

        LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
            "unit-test-forbidden-entry",
            arguments: arguments,
            environment: enabledEnvironment
        )

        XCTAssertEqual(
            LearnfoldStrictHarnessSentinel.forbiddenEvents(
                arguments: arguments,
                environment: enabledEnvironment
            ),
            ["unit-test-forbidden-entry"]
        )
        LearnfoldStrictHarnessSentinel.resetForTesting()
    }

    func testParserAcceptsExactlyOneScenarioWithBase() {
        XCTAssertEqual(
            CourseRecoveryCheckpointUITestScenario.current(
                arguments: [
                    base,
                    CourseRecoveryCheckpointUITestScenario
                        .lf34AcceptedReplyIncomplete
                        .rawValue,
                ],
                environment: enabledEnvironment
            ),
            .lf34AcceptedReplyIncomplete
        )
    }

    func testParserRejectsBaseWithoutScenario() {
        XCTAssertNil(
            CourseRecoveryCheckpointUITestScenario.current(
                arguments: [base],
                environment: enabledEnvironment
            )
        )
    }

    func testParserRejectsMultipleDistinctScenarioFlags() {
        XCTAssertNil(
            CourseRecoveryCheckpointUITestScenario.current(
                arguments: [
                    base,
                    CourseRecoveryCheckpointUITestScenario.lf34Preparing.rawValue,
                    CourseRecoveryCheckpointUITestScenario.lf35Recovering.rawValue,
                ],
                environment: enabledEnvironment
            )
        )
    }

    func testParserRejectsDuplicatedScenarioFlag() {
        let scenario = CourseRecoveryCheckpointUITestScenario.lf35Provenance
        XCTAssertNil(
            CourseRecoveryCheckpointUITestScenario.current(
                arguments: [base, scenario.rawValue, scenario.rawValue],
                environment: enabledEnvironment
            )
        )
    }

    func testParserRejectsScenarioWithoutBase() {
        XCTAssertNil(
            CourseRecoveryCheckpointUITestScenario.current(
                arguments: [
                    CourseRecoveryCheckpointUITestScenario
                        .lf36TransportRecovery
                        .rawValue,
                ],
                environment: enabledEnvironment
            )
        )
    }
}
#endif
