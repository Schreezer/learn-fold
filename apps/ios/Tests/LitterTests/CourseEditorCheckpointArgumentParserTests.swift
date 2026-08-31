import NativeBlockEditorCore
import NativeBlockEditorUI
import XCTest
@testable import Litter

#if DEBUG
final class CourseEditorCheckpointArgumentParserTests: XCTestCase {
    private let token = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

    func testEveryRecognizedScenarioParsesWithExactlyOneBaseFlagAndToken() {
        for scenario in CourseEditorCheckpointUITestScenario.allCases {
            XCTAssertEqual(
                CourseEditorCheckpointUITestConfigurationParser.parse(arguments: [
                    "Litter",
                    CourseEditorCheckpointUITestConfigurationParser.baseFlag,
                    scenario.rawValue,
                    CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                    token,
                ]),
                .valid(CourseEditorCheckpointUITestConfiguration(
                    scenario: scenario,
                    runToken: token
                )),
                "Failed to parse \(scenario.rawValue)"
            )
        }
    }

    func testCanonicalizesUppercaseUUIDWithoutChangingRunIdentity() {
        let uppercaseToken = token.uppercased()
        XCTAssertEqual(
            parse(.lf50Modified, tokenArguments: [
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                uppercaseToken,
            ]),
            .valid(CourseEditorCheckpointUITestConfiguration(
                scenario: .lf50Modified,
                runToken: token
            ))
        )
    }

    func testLF50ErrorOverlayUsesTypedStrictEvidenceAndCanonicalRoute() {
        let scenario = CourseEditorCheckpointUITestScenario.lf50ErrorOverlay
        XCTAssertEqual(scenario.rawValue, "--checkpoint-lf50-error-overlay")
        XCTAssertTrue(scenario.requiresFixture)
        XCTAssertEqual(
            scenario.strictEvidence,
            CourseEditorCheckpointStrictEvidence(
                checkpointID: "LF-50",
                substate: "error-overlay",
                hookIdentifier: "lf-50-fault-hook",
                runtimeProbeIdentifier: "lf-50-runtime-probe"
            )
        )
        XCTAssertEqual(
            parse(scenario, tokenArguments: [
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                token,
            ]),
            .valid(CourseEditorCheckpointUITestConfiguration(
                scenario: scenario,
                runToken: token
            ))
        )
    }

    func testScenarioInventoryIsFrozen() {
        XCTAssertEqual(
            CourseEditorCheckpointUITestScenario.allCases,
            [
                .lf45Loading,
                .lf45Loaded,
                .lf45Error,
                .lf47FileLoaded,
                .lf47FileFallback,
                .lf48Opening,
                .lf48Editable,
                .lf48LoadError,
                .lf49Formatting,
                .lf49DocumentToolbar,
                .lf49Reordered,
                .lf49LinkedPage,
                .lf50Modified,
                .lf50ReopenedPersisted,
                .lf50ErrorOverlay,
                .lf51Selection,
                .lf51Annotation,
                .lf51ReopenedAnnotation,
            ],
            "Adding or removing a strict editor state requires an explicit fixture-isolation review."
        )
    }

    func testEveryScenarioHasAnExactFixtureDependencyAndAvoidsCourseExperienceStore() {
        let expectedDependencies: [
            CourseEditorCheckpointUITestScenario: CourseEditorCheckpointFixtureDependency
        ] = [
            .lf45Loading: .none,
            .lf45Loaded: .workspaceFiles,
            .lf45Error: .workspaceFiles,
            .lf47FileLoaded: .workspaceFiles,
            .lf47FileFallback: .workspaceFiles,
            .lf48Opening: .none,
            .lf48Editable: .documentRepository,
            .lf48LoadError: .documentRepository,
            .lf49Formatting: .documentRepository,
            .lf49DocumentToolbar: .documentRepository,
            .lf49Reordered: .documentRepository,
            .lf49LinkedPage: .documentRepository,
            .lf50Modified: .documentRepository,
            .lf50ReopenedPersisted: .persistedDocumentRepository,
            .lf50ErrorOverlay: .documentRepository,
            .lf51Selection: .documentRepository,
            .lf51Annotation: .documentRepository,
            .lf51ReopenedAnnotation: .documentRepository,
        ]
        XCTAssertEqual(
            expectedDependencies.count,
            CourseEditorCheckpointUITestScenario.allCases.count
        )

        for scenario in CourseEditorCheckpointUITestScenario.allCases {
            guard let expectedDependency = expectedDependencies[scenario] else {
                XCTFail("Missing fixture dependency for \(scenario.rawValue)")
                continue
            }
            XCTAssertEqual(
                scenario.fixtureDependency,
                expectedDependency,
                "Unexpected fixture dependency for \(scenario.rawValue)"
            )
            XCTAssertEqual(
                scenario.requiresFixture,
                expectedDependency != .none,
                "Fixture-presence projection drifted for \(scenario.rawValue)"
            )
            XCTAssertFalse(
                scenario.requiresCourseExperienceStore,
                "Strict editor state \(scenario.rawValue) must not construct CourseExperienceStore."
            )
        }
    }

    func testLF45SelectedFileAndLF47ViewerStatesUseWorkspaceFilesOnly() {
        for scenario in [
            CourseEditorCheckpointUITestScenario.lf45Loaded,
            .lf45Error,
            .lf47FileLoaded,
            .lf47FileFallback,
        ] {
            XCTAssertEqual(scenario.fixtureDependency, .workspaceFiles)
            XCTAssertFalse(scenario.requiresCourseExperienceStore)
        }
    }

    func testRejectsRecognizedScenarioWithoutBaseFlag() {
        XCTAssertEqual(
            CourseEditorCheckpointUITestConfigurationParser.parse(arguments: [
                CourseEditorCheckpointUITestScenario.lf45Loaded.rawValue,
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                token,
            ]),
            .invalid(.missingBaseFlag)
        )
    }

    func testRejectsZeroRecognizedScenarios() {
        XCTAssertEqual(
            CourseEditorCheckpointUITestConfigurationParser.parse(arguments: [
                CourseEditorCheckpointUITestConfigurationParser.baseFlag,
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                token,
            ]),
            .invalid(.missingScenario)
        )
    }

    func testRejectsMultipleDistinctRecognizedScenarios() {
        XCTAssertEqual(
            CourseEditorCheckpointUITestConfigurationParser.parse(arguments: [
                CourseEditorCheckpointUITestConfigurationParser.baseFlag,
                CourseEditorCheckpointUITestScenario.lf45Loaded.rawValue,
                CourseEditorCheckpointUITestScenario.lf48Editable.rawValue,
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                token,
            ]),
            .invalid(.multipleScenarios([.lf45Loaded, .lf48Editable]))
        )
    }

    func testRejectsDuplicateRecognizedScenario() {
        XCTAssertEqual(
            CourseEditorCheckpointUITestConfigurationParser.parse(arguments: [
                CourseEditorCheckpointUITestConfigurationParser.baseFlag,
                CourseEditorCheckpointUITestScenario.lf45Loaded.rawValue,
                CourseEditorCheckpointUITestScenario.lf45Loaded.rawValue,
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                token,
            ]),
            .invalid(.multipleScenarios([.lf45Loaded, .lf45Loaded]))
        )
    }

    func testRejectsDuplicateBaseFlag() {
        XCTAssertEqual(
            CourseEditorCheckpointUITestConfigurationParser.parse(arguments: [
                CourseEditorCheckpointUITestConfigurationParser.baseFlag,
                CourseEditorCheckpointUITestConfigurationParser.baseFlag,
                CourseEditorCheckpointUITestScenario.lf45Loaded.rawValue,
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                token,
            ]),
            .invalid(.duplicateBaseFlag)
        )
    }

    func testRejectsMissingRunTokenFlag() {
        XCTAssertEqual(
            parse(.lf45Loaded, tokenArguments: []),
            .invalid(.missingRunToken)
        )
    }

    func testRejectsRunTokenFlagWithoutValue() {
        XCTAssertEqual(
            parse(.lf45Loaded, tokenArguments: [
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
            ]),
            .invalid(.missingRunToken)
        )
    }

    func testRejectsDuplicateRunTokenFlag() {
        XCTAssertEqual(
            parse(.lf45Loaded, tokenArguments: [
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                token,
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
            ]),
            .invalid(.duplicateRunToken)
        )
    }

    func testRejectsInvalidAndNoncanonicalRunTokens() {
        XCTAssertEqual(
            parse(.lf45Loaded, tokenArguments: [
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                "not-a-uuid",
            ]),
            .invalid(.invalidRunToken("not-a-uuid"))
        )
        XCTAssertEqual(
            parse(.lf45Loaded, tokenArguments: [
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                "f47ac10b58cc4372a5670e02b2c3d479",
            ]),
            .invalid(.invalidRunToken("f47ac10b58cc4372a5670e02b2c3d479"))
        )
    }

    func testWasRequestedOnlyForBaseFlagOrRecognizedScenario() {
        XCTAssertFalse(
            CourseEditorCheckpointUITestConfigurationParser.wasRequested(arguments: [
                "Litter",
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                token,
            ])
        )
        XCTAssertTrue(
            CourseEditorCheckpointUITestConfigurationParser.wasRequested(arguments: [
                CourseEditorCheckpointUITestConfigurationParser.baseFlag,
            ])
        )
        for scenario in CourseEditorCheckpointUITestScenario.allCases {
            XCTAssertTrue(
                CourseEditorCheckpointUITestConfigurationParser.wasRequested(arguments: [
                    scenario.rawValue,
                ]),
                "Did not route \(scenario.rawValue) to the visible configuration result"
            )
        }
    }

    func testLiveRuntimeProbeGateRequiresExactNonFixtureRouteAndEphemeralKey() {
        let key = Data(repeating: 0x4C, count: 32).base64EncodedString()
        let arguments = [
            "Litter",
            CourseEditorRuntimeProbeConfiguration.enableFlag,
            CourseEditorRuntimeProbeConfiguration.runTokenFlag,
            token,
        ]
        let environment = [
            CourseEditorRuntimeProbeConfiguration.keyEnvironmentVariable: key,
        ]
        XCTAssertNotNil(CourseEditorRuntimeProbeConfiguration.current(
            arguments: arguments,
            environment: environment
        ))
        XCTAssertNil(CourseEditorRuntimeProbeConfiguration.current(
            arguments: Array(arguments.dropLast(2)),
            environment: environment
        ))
        XCTAssertNil(CourseEditorRuntimeProbeConfiguration.current(
            arguments: arguments,
            environment: [:]
        ))
        XCTAssertNil(CourseEditorRuntimeProbeConfiguration.current(
            arguments: arguments + [CourseEditorCheckpointUITestConfigurationParser.baseFlag],
            environment: environment
        ))
        XCTAssertNil(CourseEditorRuntimeProbeConfiguration.current(
            arguments: arguments + [CourseEditorRuntimeProbeConfiguration.enableFlag],
            environment: environment
        ))
    }

    func testLF51RuntimeProbeUsesCallbackAndPersistedDiscussionWithoutExposingText() throws {
        let configuration = CourseEditorRuntimeProbeConfiguration(
            runToken: token,
            keyData: Data(repeating: 0x51, count: 32)
        )
        let privateSelection = "  Private selected passage 🔒  "
        let selection = NativeBlockEditorSelection(
            blockID: "stable-block-id",
            path: BlockPath([2, 1]),
            range: NSRange(location: 7, length: 27),
            text: privateSelection
        )
        let discussionID = try XCTUnwrap(UUID(
            uuidString: "89a7c432-7736-49ab-aebc-c82874c7bb2a"
        ))
        let reference = try XCTUnwrap(CourseTextReference(
            id: discussionID,
            courseID: "private-course-id",
            pageID: "resolved-page-id",
            pageTitle: "Private page title",
            blockID: "resolved-block-id",
            pathIndices: [4, 3],
            rangeLocation: 9,
            rangeLength: 25,
            selectedText: privateSelection
        ))

        var state = CourseEditorLF51RuntimeProbeState()
        state.recordSelection(
            selection,
            resolvedReference: reference,
            callbackResult: "discussion-opened",
            configuration: configuration
        )
        let selectionValue = state.accessibilityValue(
            annotationProvenances: []
        )
        let selectionFields = runtimeProbeFields(selectionValue)
        XCTAssertEqual(
            Set(selectionFields.keys),
            [
                "selected-text-digest",
                "selected-text-utf16-length",
                "selection-block",
                "selection-path",
                "selection-range",
                "resolved-page-id",
            ]
        )
        let normalizedSelection = privateSelection.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        XCTAssertEqual(
            selectionFields["selected-text-digest"],
            configuration.digest(domain: "lf51-selected-text", value: normalizedSelection)
        )
        XCTAssertEqual(
            selectionFields["selected-text-utf16-length"],
            String(normalizedSelection.utf16.count)
        )
        XCTAssertEqual(selectionFields["selection-block"], "resolved-block-id")
        XCTAssertEqual(selectionFields["selection-path"], "4.3")
        XCTAssertEqual(selectionFields["selection-range"], "9:25")
        XCTAssertEqual(selectionFields["resolved-page-id"], reference.pageID)
        XCTAssertFalse(selectionValue.contains(normalizedSelection))
        XCTAssertFalse(selectionValue.contains(reference.pageTitle))
        XCTAssertFalse(selectionValue.contains(reference.courseID))
        XCTAssertEqual(
            state.hookAccessibilityValue,
            "callback-kind=selection;callback-count=1;callback-result=discussion-opened"
        )

        let discussion = CourseSelectionDiscussion(reference: reference)
        let annotation = NativeBlockEditorTextAnnotation(
            id: discussion.id.uuidString,
            blockID: "resolved-block-id",
            path: BlockPath([4, 3]),
            range: NSRange(location: 9, length: 25)
        )
        let provenance = try XCTUnwrap(CourseEditorLF51AnnotationStoreProvenance(
            discussion: discussion,
            annotation: annotation,
            configuration: configuration
        ))
        let projectedValue = state.accessibilityValue(
            annotationProvenances: [provenance]
        )
        let projectedFields = runtimeProbeFields(projectedValue)
        XCTAssertEqual(projectedFields["annotation-id"], annotation.id)
        XCTAssertEqual(projectedFields["annotation-projection"], "projected")
        XCTAssertEqual(projectedFields["annotation-block"], "resolved-block-id")
        XCTAssertEqual(projectedFields["annotation-path"], "4.3")
        XCTAssertEqual(projectedFields["annotation-range"], "9:25")
        XCTAssertEqual(projectedFields["annotation-page-id"], reference.pageID)
        XCTAssertEqual(projectedFields["reopen-persistence-receipt"]?.count, 64)

        state.recordOpenedAnnotation(
            annotation,
            wasOpened: true,
            callbackResult: "discussion-opened"
        )
        let openedFields = runtimeProbeFields(state.accessibilityValue(
            annotationProvenances: [provenance]
        ))
        XCTAssertEqual(openedFields["annotation-projection"], "opened")
        XCTAssertEqual(
            openedFields["reopen-persistence-receipt"],
            projectedFields["reopen-persistence-receipt"]
        )

        let reopenedFields = runtimeProbeFields(
            CourseEditorLF51RuntimeProbeState().accessibilityValue(
                annotationProvenances: [provenance]
            )
        )
        XCTAssertEqual(reopenedFields["annotation-projection"], "projected")
        XCTAssertEqual(
            reopenedFields["reopen-persistence-receipt"],
            projectedFields["reopen-persistence-receipt"]
        )
        XCTAssertFalse(openedFields.values.contains(where: { $0.contains(normalizedSelection) }))
        XCTAssertEqual(
            state.hookAccessibilityValue,
            "callback-kind=annotation;callback-count=2;callback-result=discussion-opened"
        )
        let alternateProvenance = try XCTUnwrap(CourseEditorLF51AnnotationStoreProvenance(
            discussion: discussion,
            annotation: annotation,
            configuration: CourseEditorRuntimeProbeConfiguration(
                runToken: token,
                keyData: Data(repeating: 0x52, count: 32)
            )
        ))
        XCTAssertNotEqual(alternateProvenance.storeReceipt, provenance.storeReceipt)
    }

    func testLF51RuntimeProbeUsesOpenedAnnotationProvenanceAmongMultipleDiscussions() throws {
        let configuration = CourseEditorRuntimeProbeConfiguration(
            runToken: token,
            keyData: Data(repeating: 0x53, count: 32)
        )
        let firstReference = try XCTUnwrap(CourseTextReference(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            courseID: "course-id",
            pageID: "page-id",
            pageTitle: "Page",
            blockID: "first-block",
            pathIndices: [0],
            rangeLocation: 1,
            rangeLength: 5,
            selectedText: "First"
        ))
        let openedReference = try XCTUnwrap(CourseTextReference(
            id: UUID(uuidString: "ffffffff-ffff-4fff-bfff-ffffffffffff")!,
            courseID: "course-id",
            pageID: "page-id",
            pageTitle: "Page",
            blockID: "opened-block",
            pathIndices: [3, 2],
            rangeLocation: 7,
            rangeLength: 6,
            selectedText: "Opened"
        ))
        let firstDiscussion = CourseSelectionDiscussion(reference: firstReference)
        let openedDiscussion = CourseSelectionDiscussion(reference: openedReference)
        let firstAnnotation = NativeBlockEditorTextAnnotation(
            id: firstDiscussion.id.uuidString,
            blockID: firstReference.blockID,
            path: BlockPath(firstReference.pathIndices),
            range: NSRange(
                location: firstReference.rangeLocation,
                length: firstReference.rangeLength
            )
        )
        let openedAnnotation = NativeBlockEditorTextAnnotation(
            id: openedDiscussion.id.uuidString,
            blockID: openedReference.blockID,
            path: BlockPath(openedReference.pathIndices),
            range: NSRange(
                location: openedReference.rangeLocation,
                length: openedReference.rangeLength
            )
        )
        let firstProvenance = try XCTUnwrap(CourseEditorLF51AnnotationStoreProvenance(
            discussion: firstDiscussion,
            annotation: firstAnnotation,
            configuration: configuration
        ))
        let openedProvenance = try XCTUnwrap(CourseEditorLF51AnnotationStoreProvenance(
            discussion: openedDiscussion,
            annotation: openedAnnotation,
            configuration: configuration
        ))

        var state = CourseEditorLF51RuntimeProbeState()
        state.recordOpenedAnnotation(
            openedAnnotation,
            wasOpened: true,
            callbackResult: "discussion-opened"
        )
        let fields = runtimeProbeFields(state.accessibilityValue(
            annotationProvenances: [openedProvenance, firstProvenance]
        ))

        XCTAssertEqual(fields["annotation-id"], openedAnnotation.id)
        XCTAssertEqual(fields["annotation-projection"], "opened")
        XCTAssertEqual(fields["annotation-block"], "opened-block")
        XCTAssertEqual(fields["annotation-path"], "3.2")
        XCTAssertEqual(fields["annotation-range"], "7:6")
        XCTAssertEqual(
            fields["reopen-persistence-receipt"],
            openedProvenance.storeReceipt
        )
        XCTAssertNotEqual(
            fields["reopen-persistence-receipt"],
            firstProvenance.storeReceipt
        )
    }

    func testLF51RuntimeProbeDoesNotCallReprojectedGeometryOpened() throws {
        let configuration = CourseEditorRuntimeProbeConfiguration(
            runToken: token,
            keyData: Data(repeating: 0x54, count: 32)
        )
        let reference = try XCTUnwrap(CourseTextReference(
            id: UUID(uuidString: "89a7c432-7736-49ab-aebc-c82874c7bb2a")!,
            courseID: "course-id",
            pageID: "page-id",
            pageTitle: "Page",
            blockID: "original-block",
            pathIndices: [1],
            rangeLocation: 2,
            rangeLength: 8,
            selectedText: "Selected"
        ))
        let discussion = CourseSelectionDiscussion(reference: reference)
        let openedAnnotation = NativeBlockEditorTextAnnotation(
            id: discussion.id.uuidString,
            blockID: "original-block",
            path: BlockPath([1]),
            range: NSRange(location: 2, length: 8)
        )
        let reprojectedAnnotation = NativeBlockEditorTextAnnotation(
            id: discussion.id.uuidString,
            blockID: "moved-block",
            path: BlockPath([4, 0]),
            range: NSRange(location: 11, length: 8)
        )
        let reprojectedProvenance = try XCTUnwrap(
            CourseEditorLF51AnnotationStoreProvenance(
                discussion: discussion,
                annotation: reprojectedAnnotation,
                configuration: configuration
            )
        )

        var state = CourseEditorLF51RuntimeProbeState()
        state.recordOpenedAnnotation(
            openedAnnotation,
            wasOpened: true,
            callbackResult: "discussion-opened"
        )
        let fields = runtimeProbeFields(state.accessibilityValue(
            annotationProvenances: [reprojectedProvenance]
        ))

        XCTAssertEqual(fields["annotation-id"], openedAnnotation.id)
        XCTAssertEqual(fields["annotation-projection"], "projected")
        XCTAssertEqual(fields["annotation-block"], "moved-block")
        XCTAssertEqual(fields["annotation-path"], "4.0")
        XCTAssertEqual(fields["annotation-range"], "11:8")
        XCTAssertEqual(
            state.hookAccessibilityValue,
            "callback-kind=annotation;callback-count=1;callback-result=discussion-opened"
        )
    }

    private func runtimeProbeFields(_ value: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: value.split(separator: ";").compactMap { field in
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        })
    }

    private func parse(
        _ scenario: CourseEditorCheckpointUITestScenario,
        tokenArguments: [String]
    ) -> CourseEditorCheckpointUITestConfigurationParseResult {
        CourseEditorCheckpointUITestConfigurationParser.parse(arguments: [
            CourseEditorCheckpointUITestConfigurationParser.baseFlag,
            scenario.rawValue,
        ] + tokenArguments)
    }
}
#endif
