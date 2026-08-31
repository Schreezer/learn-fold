import Foundation
import XCTest
@testable import Litter

final class CourseHermesRecoveryPresentationTests: XCTestCase {
    private struct JournalFixture {
        let directory: URL
        let toolURL: URL
        let submissionURL: URL
        let toolJournal: RemoteHermesToolJournal
        let submissionJournal: RemoteHermesSubmissionJournal
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    func testMapsEveryPendingToolJournalPhase() throws {
        let cases: [(
            phase: RemoteHermesToolJournalEntry.Phase,
            state: CourseHermesRecoveryProvenance.JournalState
        )] = [
            (.executing, .toolExecuting),
            (.executed, .toolExecuted),
            (.resultSubmitting, .resultSubmitting),
            (.resultSubmitted, .resultSubmitted),
        ]

        for (index, testCase) in cases.enumerated() {
            let fixture = try makeFixture()
            let workspaceID = "workspace-phase-\(index)"
            let threadID = "thread-phase-\(index)"
            try fixture.toolJournal.save(
                makeToolEntry(
                    workspaceID: workspaceID,
                    threadID: threadID,
                    phase: testCase.phase
                )
            )

            let presentation = try XCTUnwrap(
                load(
                    fixture,
                    workspaceID: workspaceID,
                    threadID: threadID
                )
            )
            XCTAssertEqual(presentation.provenance.journalState, testCase.state)
            XCTAssertEqual(presentation.provenance.workspaceID, workspaceID)
            XCTAssertEqual(presentation.provenance.threadID, threadID)
            XCTAssertEqual(presentation.provenance.toolName, "private-native-tool")
        }
    }

    func testMapsEveryPendingSubmissionJournalState() throws {
        let cases: [(
            record: PendingHermesAcceptedTurn,
            state: CourseHermesRecoveryProvenance.JournalState
        )] = [
            (
                makeAcceptedTurn(
                    workspaceID: "workspace-intent",
                    threadID: "thread-intent",
                    submissionIntentID: "intent-1"
                ),
                .submissionIntent
            ),
            (
                makeAcceptedTurn(
                    workspaceID: "workspace-accepted",
                    threadID: "thread-accepted",
                    expectedTurnID: "turn-accepted"
                ),
                .acceptedTurn
            ),
            (
                makeAcceptedTurn(
                    workspaceID: "workspace-tool-owned",
                    threadID: "thread-tool-owned",
                    toolLifecycleOwned: true
                ),
                .toolLifecyclePending
            ),
            (
                makeAcceptedTurn(
                    workspaceID: "workspace-terminal",
                    threadID: "thread-terminal",
                    terminalError: "terminal recovery failure"
                ),
                .terminalFailure
            ),
        ]

        for testCase in cases {
            let fixture = try makeFixture()
            try fixture.submissionJournal.save(testCase.record)

            let presentation = try XCTUnwrap(
                load(
                    fixture,
                    workspaceID: testCase.record.workspaceID,
                    threadID: testCase.record.threadID
                )
            )
            XCTAssertEqual(presentation.provenance.journalState, testCase.state)
        }
    }

    func testCorrelatesCourseAndSelectionDiscussionsIndependently() throws {
        let fixture = try makeFixture()
        let workspaceID = "workspace-correlated"
        let selectionID = UUID()
        try fixture.toolJournal.save(
            makeToolEntry(
                workspaceID: workspaceID,
                threadID: "thread-course",
                phase: .executed
            )
        )
        try fixture.toolJournal.save(
            makeToolEntry(
                workspaceID: workspaceID,
                threadID: "thread-selection",
                selectionDiscussionID: selectionID,
                phase: .resultSubmitted
            )
        )

        let course = try XCTUnwrap(
            load(
                fixture,
                workspaceID: workspaceID,
                threadID: "thread-course"
            )
        )
        XCTAssertEqual(course.provenance.discussionKind, .course)
        XCTAssertEqual(course.provenance.threadID, "thread-course")

        let selection = try XCTUnwrap(
            load(
                fixture,
                workspaceID: workspaceID,
                threadID: "thread-selection",
                selectionDiscussionID: selectionID
            )
        )
        XCTAssertEqual(selection.provenance.discussionKind, .selection)
        XCTAssertEqual(selection.provenance.threadID, "thread-selection")
    }

    func testExcludesPendingEvidenceForWrongThread() throws {
        let fixture = try makeFixture()
        try fixture.toolJournal.save(
            makeToolEntry(
                workspaceID: "workspace-wrong-thread",
                threadID: "thread-other",
                phase: .executed
            )
        )

        XCTAssertNil(
            load(
                fixture,
                workspaceID: "workspace-wrong-thread",
                threadID: "thread-requested"
            )
        )
    }

    func testMissingSelectionThreadNeverInheritsUnrelatedMainRecovery() throws {
        let fixture = try makeFixture()
        let workspaceID = "workspace-missing-selection-thread"
        let selectionID = UUID()
        try fixture.toolJournal.save(
            makeToolEntry(
                workspaceID: workspaceID,
                threadID: "main-thread",
                phase: .executing
            )
        )

        XCTAssertNotNil(load(
            fixture,
            workspaceID: workspaceID,
            threadID: "main-thread"
        ))
        XCTAssertNil(load(
            fixture,
            workspaceID: workspaceID,
            threadID: nil,
            selectionDiscussionID: selectionID
        ))
    }

    func testMainRecoveryCanStillLoadWhileThreadIdentityIsTemporarilyUnavailable() throws {
        let fixture = try makeFixture()
        let workspaceID = "workspace-main-thread-cold"
        try fixture.toolJournal.save(
            makeToolEntry(
                workspaceID: workspaceID,
                threadID: "main-thread-cold",
                phase: .executed
            )
        )

        let presentation = try XCTUnwrap(load(
            fixture,
            workspaceID: workspaceID,
            threadID: nil
        ))
        XCTAssertEqual(presentation.provenance.discussionKind, .course)
        XCTAssertEqual(presentation.provenance.threadID, "main-thread-cold")
    }

    func testCorruptToolJournalFallsBackToValidSubmissionJournal() throws {
        let fixture = try makeFixture()
        let workspaceID = "workspace-fallback"
        let threadID = "thread-fallback"
        try Data("not-json".utf8).write(to: fixture.toolURL)
        try fixture.submissionJournal.save(
            makeAcceptedTurn(
                workspaceID: workspaceID,
                threadID: threadID,
                expectedTurnID: "turn-accepted"
            )
        )

        let presentation = try XCTUnwrap(
            load(
                fixture,
                workspaceID: workspaceID,
                threadID: threadID
            )
        )
        XCTAssertEqual(presentation.provenance.journalState, .acceptedTurn)
        XCTAssertEqual(presentation.provenance.workspaceID, workspaceID)
        XCTAssertEqual(presentation.provenance.threadID, threadID)
    }

    func testCorruptSubmissionJournalFallsBackToValidToolJournal() throws {
        let fixture = try makeFixture()
        let workspaceID = "workspace-tool-fallback"
        let threadID = "thread-tool-fallback"
        try fixture.toolJournal.save(
            makeToolEntry(
                workspaceID: workspaceID,
                threadID: threadID,
                phase: .resultSubmitting
            )
        )
        try Data("not-json".utf8).write(to: fixture.submissionURL)

        let presentation = try XCTUnwrap(
            load(
                fixture,
                workspaceID: workspaceID,
                threadID: threadID
            )
        )
        XCTAssertEqual(presentation.provenance.journalState, .resultSubmitting)
        XCTAssertEqual(presentation.provenance.workspaceID, workspaceID)
        XCTAssertEqual(presentation.provenance.threadID, threadID)
        XCTAssertEqual(presentation.provenance.toolName, "private-native-tool")
    }

    func testEitherUnreadableJournalWithoutValidEvidenceReturnsExplicitState() throws {
        for corruptsToolJournal in [true, false] {
            let fixture = try makeFixture()
            let suffix = corruptsToolJournal ? "tool" : "submission"
            let workspaceID = "workspace-corrupt-\(suffix)"
            let threadID = "thread-corrupt-\(suffix)"
            let corruptURL = corruptsToolJournal
                ? fixture.toolURL
                : fixture.submissionURL
            try Data("not-json".utf8).write(to: corruptURL)

            let presentation = try XCTUnwrap(
                load(
                    fixture,
                    workspaceID: workspaceID,
                    threadID: threadID
                )
            )
            XCTAssertEqual(
                presentation.provenance.journalState,
                .unreadableEvidence
            )
            XCTAssertEqual(presentation.provenance.workspaceID, workspaceID)
            XCTAssertEqual(presentation.provenance.threadID, threadID)
        }
    }

    func testNoPendingEvidenceReturnsNil() throws {
        let fixture = try makeFixture()
        let workspaceID = "workspace-terminal"
        let threadID = "thread-terminal"
        try fixture.toolJournal.save(
            makeToolEntry(
                workspaceID: workspaceID,
                threadID: threadID,
                phase: .completed
            )
        )
        try fixture.submissionJournal.save(
            makeAcceptedTurn(
                workspaceID: workspaceID,
                threadID: threadID
            )
        )

        XCTAssertNil(
            load(
                fixture,
                workspaceID: workspaceID,
                threadID: threadID
            )
        )
    }

    func testCorruptBothJournalsReturnsExplicitUnreadableEvidence() throws {
        let fixture = try makeFixture()
        try Data("bad-tool-journal".utf8).write(to: fixture.toolURL)
        try Data("bad-submission-journal".utf8).write(to: fixture.submissionURL)

        let presentation = try XCTUnwrap(
            load(
                fixture,
                workspaceID: "workspace-corrupt",
                threadID: "thread-corrupt"
            )
        )
        XCTAssertEqual(
            presentation.provenance.journalState,
            .unreadableEvidence
        )
        XCTAssertEqual(presentation.provenance.workspaceID, "workspace-corrupt")
        XCTAssertEqual(presentation.provenance.threadID, "thread-corrupt")
    }

    private func makeFixture() throws -> JournalFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CourseHermesRecoveryPresentationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        let toolURL = directory.appendingPathComponent("tool-journal.json")
        let submissionURL = directory.appendingPathComponent("submission-journal.json")
        return JournalFixture(
            directory: directory,
            toolURL: toolURL,
            submissionURL: submissionURL,
            toolJournal: RemoteHermesToolJournal(fileURL: toolURL),
            submissionJournal: RemoteHermesSubmissionJournal(fileURL: submissionURL)
        )
    }

    private func load(
        _ fixture: JournalFixture,
        workspaceID: String,
        threadID: String?,
        selectionDiscussionID: UUID? = nil
    ) -> CourseHermesRecoveryPresentation? {
        CourseHermesRecoveryPresentationLoader.load(
            workspaceID: workspaceID,
            requestedThreadID: threadID,
            selectionDiscussionID: selectionDiscussionID,
            toolJournal: fixture.toolJournal,
            submissionJournal: fixture.submissionJournal
        )
    }

    private func makeToolEntry(
        workspaceID: String,
        threadID: String,
        selectionDiscussionID: UUID? = nil,
        phase: RemoteHermesToolJournalEntry.Phase
    ) -> RemoteHermesToolJournalEntry {
        RemoteHermesToolJournalEntry(
            id: UUID().uuidString,
            workspaceID: workspaceID,
            threadID: threadID,
            sourceTurnID: "source-turn",
            toolName: "private-native-tool",
            argumentsJSON: #"{"workspace_id":"private"}"#,
            selectionDiscussionID: selectionDiscussionID,
            phase: phase,
            success: phase == .executed ? true : nil,
            output: phase == .executed ? #"{"ok":true}"# : nil,
            resultTurnID: phase == .resultSubmitted ? "result-turn" : nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeAcceptedTurn(
        workspaceID: String,
        threadID: String,
        expectedTurnID: String? = nil,
        terminalError: String? = nil,
        submissionIntentID: String? = nil,
        toolLifecycleOwned: Bool? = nil
    ) -> PendingHermesAcceptedTurn {
        PendingHermesAcceptedTurn(
            workspaceID: workspaceID,
            serverID: "server-private",
            threadID: threadID,
            expectedTurnID: expectedTurnID,
            selectionDiscussionID: nil,
            terminalError: terminalError,
            submissionIntentID: submissionIntentID,
            toolLifecycleOwned: toolLifecycleOwned
        )
    }
}
