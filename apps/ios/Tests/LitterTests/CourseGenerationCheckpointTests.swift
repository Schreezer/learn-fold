import XCTest
@testable import Litter

final class CourseGenerationCheckpointTests: XCTestCase {
    func testBuildingMilestonesProjectStepsZeroThroughFourExactly() {
        for step in 0..<CourseBuildingPresentationSnapshot.milestoneCount {
            let snapshot = makeSnapshot(step: step)
            XCTAssertEqual(snapshot.stateIdentifier, "milestone-\(step + 1)")
            XCTAssertFalse(snapshot.isComplete)

            for index in 0..<CourseBuildingPresentationSnapshot.milestoneCount {
                let expected: CourseBuildingMilestoneState
                if index < step {
                    expected = .complete
                } else if index == step {
                    expected = .active
                } else {
                    expected = .upcoming
                }
                XCTAssertEqual(snapshot.milestoneState(at: index), expected)
            }
        }
    }

    func testBuildingCompletionRequiresStepFiveAndNoError() {
        let completion = makeSnapshot(step: 5)
        XCTAssertTrue(completion.isComplete)
        XCTAssertEqual(completion.stateIdentifier, "completion")
        for index in 0..<CourseBuildingPresentationSnapshot.milestoneCount {
            XCTAssertEqual(completion.milestoneState(at: index), .complete)
        }

        let failed = makeSnapshot(step: 5, error: "generation failed")
        XCTAssertFalse(failed.isComplete)
        XCTAssertEqual(failed.stateIdentifier, "generation-error")
        XCTAssertEqual(failed.milestoneState(at: 4), .failed)
    }

    func testGenerationErrorOverridesTransientMilestoneState() {
        let snapshot = makeSnapshot(step: 3, error: "page generation failed")
        XCTAssertEqual(snapshot.stateIdentifier, "generation-error")
        XCTAssertFalse(snapshot.isComplete)
        XCTAssertEqual(snapshot.milestoneState(at: 2), .complete)
        XCTAssertEqual(snapshot.milestoneState(at: 3), .failed)
        XCTAssertEqual(snapshot.milestoneState(at: 4), .upcoming)
    }

    @MainActor
    func testNonApplePendingFolderRemainsTheDirectGenerationTarget() throws {
        let folder = makePendingFolder()
        for runtimeID in [CourseAgentProvider.codex, "hermes"] {
            let request = try XCTUnwrap(
                CourseExperienceStore.directGenerationRequest(
                    for: folder,
                    runtimeID: runtimeID
                )
            )
            XCTAssertEqual(request.target, folder)
            XCTAssertEqual(request.controlTitle, "Generate")
        }
    }

    @MainActor
    func testApplePendingFolderTargetsFirstValidLeafAndNeverBulkGenerates() throws {
        let folder = makePendingFolder()
        let request = try XCTUnwrap(
            CourseExperienceStore.directGenerationRequest(
                for: folder,
                runtimeID: CourseAgentProvider.appleOnDevice
            )
        )
        XCTAssertEqual(request.target, folder.children[0])
        XCTAssertEqual(request.controlTitle, "Generate next")

        var emptyFolder = folder
        emptyFolder.children = []
        XCTAssertNil(
            CourseExperienceStore.directGenerationRequest(
                for: emptyFolder,
                runtimeID: CourseAgentProvider.applePrivateCloud
            )
        )
    }

    #if DEBUG
    func testScenarioSetAndRouteOwnershipMatchCheckpointContract() {
        let expected: Set<String> = [
            "--ui-test-lf39-milestone-1",
            "--ui-test-lf39-milestone-2",
            "--ui-test-lf39-milestone-3",
            "--ui-test-lf39-milestone-4",
            "--ui-test-lf39-milestone-5",
            "--ui-test-lf40-generation-error",
            "--ui-test-lf40-returned-agent",
            "--ui-test-lf44-pending",
            "--ui-test-lf44-generating",
            "--ui-test-lf44-partial-generated",
            "--ui-test-lf44-error",
        ]
        XCTAssertEqual(
            Set(CourseGenerationCheckpointScenario.allCases.map(\.rawValue)),
            expected
        )

        for scenario in CourseGenerationCheckpointScenario.allCases {
            switch scenario.checkpointID {
            case "LF-39":
                XCTAssertEqual(scenario.route, CourseGenerationCheckpointScenario.lf39Route)
                XCTAssertEqual(scenario.hookIdentifier, "lf-39-fixture-hook")
            case "LF-40":
                XCTAssertEqual(scenario.route, CourseGenerationCheckpointScenario.lf40Route)
                XCTAssertEqual(scenario.hookIdentifier, "lf-40-fault-hook")
            case "LF-44":
                XCTAssertEqual(scenario.route, CourseGenerationCheckpointScenario.lf44Route)
                XCTAssertEqual(scenario.hookIdentifier, "lf-44-fault-hook")
            default:
                XCTFail("Unexpected checkpoint \(scenario.checkpointID)")
            }
        }
    }

    @MainActor
    func testTypedHarnessStoresInjectedScenarioWithoutArgumentReparsing() {
        for scenario in CourseGenerationCheckpointScenario.allCases {
            let root = CourseGenerationCheckpointUITestHarnessView(
                scenario: scenario
            )
            XCTAssertEqual(root.scenario, scenario)
        }
    }
    #endif

    private func makeSnapshot(
        step: Int,
        error: String? = nil
    ) -> CourseBuildingPresentationSnapshot {
        var brief = CourseBrief()
        brief.title = "Checkpoint course"
        brief.chapters = [
            CourseChapter(
                id: "chapter",
                title: "Chapter",
                objective: "Learn",
                deliverables: ["Lesson"]
            ),
        ]
        return CourseBuildingPresentationSnapshot(
            brief: brief,
            agentName: "Course Agent",
            generationStep: step,
            generationError: error
        )
    }

    private func makePendingFolder() -> CourseLearningNode {
        CourseLearningNode(
            id: "checkpoint-folder",
            title: "Feedback Loops",
            kind: .folder,
            status: .pendingGeneration,
            role: .chapter,
            children: [
                CourseLearningNode(
                    id: "checkpoint-leaf",
                    title: "Loop behavior",
                    kind: .markdown,
                    status: .pendingGeneration,
                    role: .lesson,
                    pageID: "checkpoint-page"
                ),
            ]
        )
    }
}
