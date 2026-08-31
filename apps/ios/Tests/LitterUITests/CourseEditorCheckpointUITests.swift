import CoreGraphics
import XCTest

final class CourseEditorCheckpointUITests: XCTestCase {
    private enum Scenario: String {
        case lf45Loading = "--checkpoint-lf45-loading"
        case lf45Loaded = "--checkpoint-lf45-loaded"
        case lf45Error = "--checkpoint-lf45-error"
        case lf47FileLoaded = "--checkpoint-lf47-file-loaded"
        case lf47FileFallback = "--checkpoint-lf47-file-fallback"
        case lf48Opening = "--checkpoint-lf48-opening"
        case lf48Editable = "--checkpoint-lf48-editable"
        case lf48LoadError = "--checkpoint-lf48-load-error"
        case lf49Formatting = "--checkpoint-lf49-formatting"
        case lf49DocumentToolbar = "--checkpoint-lf49-document-toolbar"
        case lf49Reordered = "--checkpoint-lf49-reordered"
        case lf49LinkedPage = "--checkpoint-lf49-linked-page"
        case lf50Modified = "--checkpoint-lf50-modified"
        case lf50ReopenedPersisted = "--checkpoint-lf50-reopened-persisted"
        case lf50ErrorOverlay = "--checkpoint-lf50-error-overlay"
        case lf51Selection = "--checkpoint-lf51-selection"
        case lf51Annotation = "--checkpoint-lf51-annotation"
        case lf51ReopenedAnnotation = "--checkpoint-lf51-reopened-annotation"
    }

    private let baseOrder = [
        "Selection anchor survives reopen.",
        "First persisted block",
        "Linked destination",
        "Second persisted block",
    ].joined(separator: " | ")

    private let reorderedOrder = [
        "Selection anchor survives reopen.",
        "First persisted block",
        "Second persisted block",
        "Linked destination",
    ].joined(separator: " | ")

    private let modifiedOrder = [
        "Selection anchor survives reopen.",
        "First persisted block",
        "Second persisted block",
        "Linked destination",
        "Modified before leaving.",
    ].joined(separator: " | ")

    private let saveRecoveryOrder = [
        "paragraph",
        "First pending recovery edit",
        "Second pending recovery edit",
    ].joined(separator: " | ")

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCheckpointConfigurationFailuresAreVisible() {
        let token = UUID().uuidString.lowercased()

        var app = launch(arguments: [
            "--ui-test-course-editor-checkpoints",
            "--checkpoint-run-token",
            token,
        ])
        assertMarker(
            "course-checkpoint-configuration-error",
            value: "missing-scenario",
            in: app,
            requiresHittable: false
        )
        capture("Checkpoint configuration missing scenario", app: app)
        assertStrictIsolation(in: app, context: "missing-scenario before termination")
        app.terminate()

        app = launch(arguments: [
            Scenario.lf45Loaded.rawValue,
            "--checkpoint-run-token",
            UUID().uuidString.lowercased(),
        ])
        assertMarker(
            "course-checkpoint-configuration-error",
            value: "missing-base-flag",
            in: app,
            requiresHittable: false
        )
        capture("Checkpoint scenario without base flag", app: app)
        assertStrictIsolation(in: app, context: "missing-base-flag before termination")
        app.terminate()

        app = launch(arguments: [
            "--ui-test-course-editor-checkpoints",
            Scenario.lf45Loaded.rawValue,
            Scenario.lf48Editable.rawValue,
            "--checkpoint-run-token",
            UUID().uuidString.lowercased(),
        ])
        assertMarker(
            "course-checkpoint-configuration-error",
            value: "multiple-scenarios",
            in: app,
            requiresHittable: false
        )
        capture("Checkpoint configuration multiple scenarios", app: app)
        assertStrictIsolation(in: app, context: "multiple-scenarios before termination")
        app.terminate()

        app = launch(arguments: [
            "--ui-test-course-editor-checkpoints",
            Scenario.lf45Loaded.rawValue,
            "--checkpoint-run-token",
            "not-a-uuid",
        ])
        assertMarker(
            "course-checkpoint-configuration-error",
            value: "invalid-run-token",
            in: app,
            requiresHittable: false
        )
        capture("Checkpoint configuration invalid run token", app: app)
    }

    @MainActor
    func testLF45StructureLoadingLoadedAndRetryRecovery() {
        var app = launch(.lf45Loading)
        assertMarker(
            "course-checkpoint-lf45-loading",
            value: "Reading source files and course pages",
            in: app
        )
        XCTAssertTrue(element("course-structure-loading", in: app).exists)
        capture("LF-45 structure loading", app: app)
        assertStrictIsolation(in: app, context: "LF-45 loading before termination")
        app.terminate()

        app = launch(.lf45Loaded)
        assertMarker("course-checkpoint-lf45-loaded", value: "2 files, 3 folders", in: app)
        let browser = element("course-structure-browser", in: app)
        XCTAssertTrue(browser.waitForExistence(timeout: 10))
        XCTAssertEqual(browser.value as? String, "2 files, 3 folders")
        let representativeFile = element("course-file-sources/field-guide.md", in: app)
        XCTAssertTrue(representativeFile.exists)
        XCTAssertTrue(element("course-file-chapters/chapter-1/lesson.md", in: app).exists)
        capture("LF-45 structure loaded", app: app)
        assertStrictIsolation(in: app, context: "LF-45 loaded before termination")
        app.terminate()

        app = launch(.lf45Error)
        assertMarker(
            "course-checkpoint-lf45-error",
            value: "Deterministic source-file and course-page load failure",
            in: app
        )
        XCTAssertTrue(app.staticTexts["Course structure unavailable"].exists)
        let retry = element("course-structure-retry", in: app)
        XCTAssertTrue(waitUntilHittable(retry, timeout: 10))
        capture("LF-45 structure error", app: app)
        retry.tap()
        assertMarker("course-checkpoint-lf45-loaded", value: "2 files, 3 folders", in: app)
        capture("LF-45 structure retry recovered", app: app)
        assertStrictIsolation(in: app, context: "LF-45 after retry recovery")
    }

    @MainActor
    func testLF47LoadedFileBackToStructureAndUnavailableFallback() {
        var app = launch(.lf47FileLoaded)
        assertMarker(
            "course-checkpoint-lf47-file-loaded",
            value: "sources/field-guide.md",
            in: app
        )
        let viewer = element("course-file-viewer", in: app)
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        XCTAssertEqual(viewer.value as? String, "File loaded as text")
        let text = element("course-file-viewer-text", in: app)
        XCTAssertTrue(text.exists)
        XCTAssertTrue(text.label.contains("Deterministic source content for LF-47."))
        capture("LF-47 loaded file", app: app)

        let back = element("course-checkpoint-lf47-back", in: app)
        XCTAssertTrue(waitUntilHittable(back, timeout: 10))
        back.tap()
        assertMarker(
            "course-checkpoint-lf47-back-to-structure",
            value: "2 files, 3 folders",
            in: app
        )
        XCTAssertTrue(element("course-structure-browser", in: app).exists)
        capture("LF-47 back to structure", app: app)
        assertStrictIsolation(in: app, context: "LF-47 after back navigation")
        app.terminate()

        app = launch(.lf47FileFallback)
        assertMarker(
            "course-checkpoint-lf47-file-fallback",
            value: "sources/removed-field-guide.md",
            in: app
        )
        let unavailableViewer = element("course-file-viewer", in: app)
        XCTAssertTrue(unavailableViewer.waitForExistence(timeout: 10))
        XCTAssertEqual(unavailableViewer.value as? String, "File unavailable")
        XCTAssertTrue(element("course-route-unavailable-file", in: app).exists)
        capture("LF-47 unavailable file fallback", app: app)

        let openStructure = app.buttons["Open Course Structure"].firstMatch
        XCTAssertTrue(waitUntilHittable(openStructure, timeout: 10))
        openStructure.tap()
        assertMarker(
            "course-checkpoint-lf47-back-to-structure",
            value: "2 files, 3 folders",
            in: app
        )
        capture("LF-47 fallback recovered to structure", app: app)
        assertStrictIsolation(in: app, context: "LF-47 after fallback recovery")
    }

    @MainActor
    func testLF48OpeningEditableLoadErrorAndRetry() {
        var app = launch(.lf48Opening)
        assertMarker(
            "course-checkpoint-lf48-opening",
            value: "Opening checkpoint-editor-page",
            in: app
        )
        XCTAssertTrue(element("course-page-opening-checkpoint-editor-page", in: app).exists)
        capture("LF-48 page opening", app: app)
        assertStrictIsolation(in: app, context: "LF-48 opening before termination")
        app.terminate()

        app = launch(.lf48Editable)
        assertMarker(
            "course-checkpoint-lf48-editable",
            value: "checkpoint-editor-page",
            in: app
        )
        let editor = element("course-page-editor-checkpoint-editor-page", in: app)
        let firstBlock = element("native-editor-block-0", in: app)
        XCTAssertTrue(
            editor.exists && firstBlock.exists,
            "The editor parent and representative native block must coexist in accessibility."
        )
        capture("LF-48 editable page", app: app)
        assertStrictIsolation(in: app, context: "LF-48 editable before termination")
        app.terminate()

        app = launch(.lf48LoadError)
        assertMarker(
            "course-checkpoint-lf48-load-error",
            value: "Deterministic page load failure",
            in: app
        )
        XCTAssertTrue(element("course-page-load-error-checkpoint-editor-page", in: app).exists)
        let retry = element("course-page-retry-checkpoint-editor-page", in: app)
        XCTAssertTrue(waitUntilHittable(retry, timeout: 10))
        capture("LF-48 page load error", app: app)
        retry.tap()
        assertMarker(
            "course-checkpoint-lf48-editable",
            value: "checkpoint-editor-page",
            in: app
        )
        XCTAssertTrue(element("course-page-editor-checkpoint-editor-page", in: app).exists)
        capture("LF-48 page retry recovered", app: app)
        assertStrictIsolation(in: app, context: "LF-48 after retry recovery")
    }

    @MainActor
    func testLF49FormattingDocumentToolbarReorderAndLinkedPageNavigation() {
        var app = launch(.lf49Formatting)
        assertMarker(
            "course-checkpoint-lf49-formatting",
            value: "checkpoint-editor-page",
            in: app
        )
        let firstBlock = element("native-editor-block-0", in: app)
        XCTAssertTrue(waitUntilHittable(firstBlock, timeout: 10))
        firstBlock.tap()
        XCTAssertTrue(
            element("native-editor-format-bold", in: app).waitForExistence(timeout: 5),
            "Focusing editable text did not expose the production formatting toolbar"
        )
        XCTAssertTrue(element("native-editor-format-italic", in: app).exists)
        capture("LF-49 formatting toolbar", app: app)
        assertStrictIsolation(in: app, context: "LF-49 after formatting action")
        app.terminate()

        app = launch(.lf49DocumentToolbar)
        assertMarker(
            "course-checkpoint-lf49-document-toolbar",
            value: "checkpoint-editor-page",
            in: app
        )
        assertDocumentOrder(baseOrder, in: app)
        let documentActions = element("native-editor-document-actions", in: app)
        XCTAssertTrue(waitUntilHittable(documentActions, timeout: 10))
        XCTAssertTrue(documentActions.exists)
        XCTAssertTrue(documentActions.isEnabled)
        XCTAssertFalse(documentActions.frame.isEmpty)
        XCTAssertTrue(documentActions.isHittable)
        XCTAssertEqual(documentActions.label, "Document actions")
        let hitTargetMeasurementEpsilon = 0.000001
        XCTAssertGreaterThanOrEqual(
            documentActions.frame.width + hitTargetMeasurementEpsilon,
            28,
            "Document actions must retain the iOS system-toolbar minimum width of 28 points."
        )
        XCTAssertGreaterThanOrEqual(
            documentActions.frame.height + hitTargetMeasurementEpsilon,
            28,
            "Document actions must retain the iOS system-toolbar minimum height of 28 points."
        )
        let strictRoot = element("courseEditorCheckpoint.strictRoot", in: app)
        let strictCounter = element("courseEditorCheckpoint.forbiddenSideEffects", in: app)
        XCTAssertTrue(strictRoot.waitForExistence(timeout: 5))
        XCTAssertTrue(strictCounter.waitForExistence(timeout: 5))
        XCTAssertFalse(
            strictRoot.frame.intersects(documentActions.frame),
            "Strict root \(strictRoot.frame) must not cover Document actions \(documentActions.frame)."
        )
        XCTAssertFalse(
            strictCounter.frame.intersects(documentActions.frame),
            "Strict counter \(strictCounter.frame) must not cover Document actions \(documentActions.frame)."
        )
        documentActions.tap()
        XCTAssertTrue(app.buttons["Copy document"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Paste rich content"].exists)
        capture("LF-49 document toolbar", app: app)
        assertStrictIsolation(in: app, context: "LF-49 after document actions menu")
        app.buttons["Copy document"].tap()
        assertStrictIsolation(in: app, context: "LF-49 after copy document action")

        let referenceActions = element("native-editor-block-actions-2", in: app)
        XCTAssertTrue(waitUntilHittable(referenceActions, timeout: 10))
        referenceActions.tap()
        let moveDown = app.buttons["Move down"].firstMatch
        XCTAssertTrue(moveDown.waitForExistence(timeout: 5))
        XCTAssertTrue(moveDown.isEnabled)
        assertStrictIsolation(in: app, context: "LF-49 after block actions menu")
        moveDown.tap()
        assertDocumentOrder(reorderedOrder, in: app)
        let secondBlock = element("native-editor-block-2", in: app)
        let movedReference = element("native-editor-block-actions-3", in: app)
        XCTAssertTrue(secondBlock.exists)
        XCTAssertTrue(movedReference.exists)
        XCTAssertLessThan(secondBlock.frame.minY, movedReference.frame.minY)
        capture("LF-49 reordered through production block menu", app: app)
        assertStrictIsolation(in: app, context: "LF-49 after reorder action")

        let linkedPage = app.buttons["Linked destination"].firstMatch
        XCTAssertTrue(waitUntilHittable(linkedPage, timeout: 10))
        linkedPage.tap()
        assertMarker(
            "course-checkpoint-lf49-linked-page",
            value: "checkpoint-linked-page",
            in: app
        )
        XCTAssertTrue(element("course-page-editor-checkpoint-linked-page", in: app).exists)
        XCTAssertTrue(element("native-editor-block-1", in: app).exists)
        capture("LF-49 linked page navigation", app: app)
        assertStrictIsolation(in: app, context: "LF-49 after linked-page navigation")
        app.terminate()

        app = launch(.lf49Reordered)
        assertMarker(
            "course-checkpoint-lf49-reordered",
            value: "checkpoint-editor-page",
            in: app
        )
        assertDocumentOrder(reorderedOrder, in: app)
        capture("LF-49 deterministic reordered checkpoint", app: app)
        assertStrictIsolation(in: app, context: "LF-49 reordered before termination")
        app.terminate()

        app = launch(.lf49LinkedPage)
        assertMarker(
            "course-checkpoint-lf49-linked-page",
            value: "checkpoint-linked-page",
            in: app
        )
        XCTAssertTrue(element("course-page-editor-checkpoint-linked-page", in: app).exists)
        capture("LF-49 deterministic linked-page checkpoint", app: app)
    }

    @MainActor
    func testLF50ModifiedLeaveFlushAndReopenPersistsExactDocument() {
        let runToken = UUID().uuidString.lowercased()
        var app = launch(.lf50Modified, runToken: runToken)
        assertMarker(
            "course-checkpoint-lf50-modified",
            value: "checkpoint-editor-page",
            in: app
        )
        assertDocumentOrder(modifiedOrder, in: app)
        let preLeaveSaveStatus = element("course-page-save-status", in: app)
        XCTAssertTrue(
            waitUntil(timeout: 5, pollInterval: 0.02) {
                preLeaveSaveStatus.value as? String == "Saving changes"
            },
            "The modified document did not expose its pending Saving changes state."
        )
        XCTAssertEqual(preLeaveSaveStatus.value as? String, "Saving changes")
        XCTAssertTrue(element("native-editor-block-4", in: app).exists)
        capture("LF-50 modified before leave", app: app)

        let leave = element("course-checkpoint-lf50-leave", in: app)
        XCTAssertTrue(waitUntilHittable(leave, timeout: 10))
        leave.tap()
        let phaseOneMarker = element("course-checkpoint-lf50-phase1-persisted", in: app)
        XCTAssertTrue(
            phaseOneMarker.waitForExistence(timeout: 10),
            "The first process did not checkpoint its SQLite database and receipt"
        )
        XCTAssertTrue(waitUntilHittable(phaseOneMarker, timeout: 5))
        guard let phaseOneReceipt = phaseOneMarker.value as? String else {
            XCTFail("The first process did not expose its persistence receipt")
            return
        }
        XCTAssertTrue(phaseOneReceipt.contains("token=\(runToken)"))
        XCTAssertTrue(phaseOneReceipt.contains("database="))
        XCTAssertTrue(phaseOneReceipt.contains("document="))
        capture("LF-50 first process persisted exact database", app: app)

        assertStrictIsolation(in: app, context: "LF-50 after leave and persistence before termination")
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)

        app = launch(.lf50ReopenedPersisted, runToken: runToken)
        let reopenedMarker = element("course-checkpoint-lf50-reopened-persisted", in: app)
        XCTAssertTrue(
            reopenedMarker.waitForExistence(timeout: 10),
            "The fresh process did not reopen the persisted database"
        )
        XCTAssertEqual(reopenedMarker.value as? String, phaseOneReceipt)
        XCTAssertTrue(waitUntilHittable(reopenedMarker, timeout: 5))
        assertDocumentOrder(modifiedOrder, in: app)
        XCTAssertTrue(element("native-editor-block-4", in: app).exists)
        capture("LF-50 fresh process reopened exact persisted document", app: app)
        assertStrictIsolation(in: app, context: "LF-50 after fresh-process reopen")
    }

    @MainActor
    func testLF50StrictErrorOverlayRetryRetainsDraftAndProbesPersistenceTruth() {
        let runToken = UUID().uuidString.lowercased()
        let app = launch(.lf50ErrorOverlay, runToken: runToken)

        assertMarker(
            "course-checkpoint-lf50-error-overlay",
            value: "error-overlay",
            in: app
        )
        assertMarker(
            "courseEditorCheckpoint.route",
            value: "--ui-test-course-editor-checkpoints",
            in: app,
            requiresHittable: false
        )
        assertMarker(
            "courseEditorCheckpoint.state",
            value: "error-overlay",
            in: app,
            requiresHittable: false
        )
        assertMarker(
            "courseEditorCheckpoint.hook",
            value: "lf-50-fault-hook",
            in: app,
            requiresHittable: false
        )
        assertMarker(
            "courseEditorCheckpoint.runtimeProbeID",
            value: "lf-50-runtime-probe",
            in: app,
            requiresHittable: false
        )
        assertDocumentOrder(saveRecoveryOrder, in: app)

        let failedStatus = element("course-page-save-status", in: app)
        XCTAssertTrue(failedStatus.waitForExistence(timeout: 10))
        XCTAssertEqual(failedStatus.label, "Changes not saved")

        let pageTitle = app.staticTexts["Save recovery evidence"]
        XCTAssertTrue(pageTitle.exists)
        XCTAssertTrue(app.staticTexts["Editable course page"].exists)
        assertBlockValue(
            "native-editor-block-1",
            contains: "First pending recovery edit",
            in: app
        )
        assertBlockValue(
            "native-editor-block-2",
            contains: "Second pending recovery edit",
            in: app
        )

        let failureMessage = element("course-page-save-error", in: app)
        XCTAssertTrue(failureMessage.exists)
        XCTAssertEqual(
            failureMessage.label,
            "Simulated course-page save failure. Your changes are still pending."
        )
        let retry = element("course-page-save-retry", in: app)
        XCTAssertTrue(waitUntilHittable(retry, timeout: 5))
        XCTAssertEqual(retry.label, "Retry save")
        XCTAssertLessThanOrEqual(
            retry.frame.maxY,
            pageTitle.frame.minY,
            "The failed-save recovery card must participate in layout above the editor title."
        )

        let runtimeProbe = element("courseEditorCheckpoint.runtimeProbe", in: app)
        XCTAssertTrue(runtimeProbe.waitForExistence(timeout: 10))
        let failedReceipt = requireReceiptValue(runtimeProbe, phase: "error-overlay")
        let failedFields = receiptFields(failedReceipt)
        XCTAssertEqual(failedFields["probe"], "lf-50-runtime-probe")
        XCTAssertEqual(failedFields["hook"], "lf-50-fault-hook")
        XCTAssertEqual(failedFields["token"], runToken)
        XCTAssertEqual(failedFields["transition"], "saving>failed")
        XCTAssertEqual(failedFields["draft-retained"], "true")
        XCTAssertEqual(failedFields["pending-journal"], "true")
        XCTAssertEqual(failedFields["persisted-matches-draft"], "false")
        XCTAssertNotEqual(failedFields["draft"], failedFields["persisted"])
        XCTAssertFalse(failedFields["database", default: ""].isEmpty)
        capture("LF-50 strict error overlay retains pending draft", app: app)
        assertStrictIsolation(in: app, context: "LF-50 strict error overlay")

        retry.tap()
        XCTAssertTrue(
            waitUntil(timeout: 1.5, pollInterval: 0.02) {
                let status = self.element("course-page-save-status", in: app)
                return status.label == "Saving changes…"
                    || status.value as? String == "Saving changes"
            },
            "Retry did not expose the real saving presentation."
        )
        capture("LF-50 strict retry saving", app: app)
        assertStrictIsolation(in: app, context: "LF-50 strict retry saving")

        XCTAssertTrue(
            waitUntil(timeout: 8, pollInterval: 0.05) {
                let status = self.element("course-page-save-status", in: app)
                return status.value as? String == "Changes saved"
            },
            "Retry did not reach the visible saved state."
        )
        XCTAssertFalse(element("course-page-save-retry", in: app).exists)
        let savedStatus = element("course-page-save-status", in: app)
        XCTAssertEqual(savedStatus.label, "Changes saved")
        XCTAssertLessThanOrEqual(
            savedStatus.frame.maxY,
            pageTitle.frame.minY,
            "The saved-status row must participate in layout above the editor title."
        )
        assertBlockValue(
            "native-editor-block-1",
            contains: "First pending recovery edit",
            in: app
        )
        assertBlockValue(
            "native-editor-block-2",
            contains: "Second pending recovery edit",
            in: app
        )
        assertDocumentOrder(saveRecoveryOrder, in: app)

        let savedReceipt = requireReceiptValue(runtimeProbe, phase: "saved-after-retry")
        let savedFields = receiptFields(savedReceipt)
        XCTAssertEqual(savedFields["probe"], "lf-50-runtime-probe")
        XCTAssertEqual(savedFields["hook"], "lf-50-fault-hook")
        XCTAssertEqual(savedFields["token"], runToken)
        XCTAssertEqual(savedFields["transition"], "failed>saving>saved")
        XCTAssertEqual(savedFields["draft-retained"], "true")
        XCTAssertEqual(savedFields["pending-journal"], "false")
        XCTAssertEqual(savedFields["persisted-matches-draft"], "true")
        XCTAssertEqual(savedFields["draft"], savedFields["persisted"])
        XCTAssertFalse(savedFields["database", default: ""].isEmpty)
        capture("LF-50 strict retry saved exact pending draft", app: app)
        assertStrictIsolation(in: app, context: "LF-50 strict saved persistence truth")
    }

    @MainActor
    func testLF51SelectionAnnotationAndReopenedAnnotation() {
        var app = launch(.lf51Selection)
        assertMarker(
            "course-checkpoint-lf51-selection-ready",
            value: "checkpoint-editor-page",
            in: app
        )
        let resolve = element("course-checkpoint-lf51-resolve-selection", in: app)
        XCTAssertTrue(waitUntilHittable(resolve, timeout: 10))
        resolve.tap()
        assertMarker(
            "course-checkpoint-lf51-selection",
            value: "course=checkpoint-course;page=checkpoint-editor-page;block=checkpoint-selection-block;path=0;range=0:16;text=Selection anchor",
            in: app,
            requiresHittable: false
        )
        let selectionLimitation = XCTAttachment(
            string: "Known evidence boundary: this checkpoint validates the production anchor resolver with deterministic block/path/range input. XCTest does not yet prove UIKit native drag-selection geometry; the proposed additive NativeBlockEditor selection-request hook would make that geometry deterministic."
        )
        selectionLimitation.name = "LF-51 native selection geometry limitation"
        selectionLimitation.lifetime = .keepAlways
        add(selectionLimitation)
        capture("LF-51 deterministic selection action", app: app)
        assertStrictIsolation(in: app, context: "LF-51 after selection action")
        app.terminate()

        app = launch(.lf51Annotation)
        assertMarker(
            "course-checkpoint-lf51-annotation",
            value: "checkpoint-editor-page",
            in: app
        )
        assertMarker(
            "course-checkpoint-lf51-annotation-projection",
            value: "id=checkpoint-annotation;page=checkpoint-editor-page;block=checkpoint-selection-block;path=0;range=0:16",
            in: app,
            requiresHittable: false
        )
        XCTAssertTrue(element("course-page-editor-checkpoint-editor-page", in: app).exists)
        tapRenderedAnnotation(in: app)
        capture("LF-51 rendered annotation opened", app: app)
        assertStrictIsolation(in: app, context: "LF-51 after annotation action")

        let leave = element("course-checkpoint-lf51-leave-annotation", in: app)
        XCTAssertTrue(waitUntilHittable(leave, timeout: 10))
        leave.tap()
        assertMarker(
            "course-checkpoint-lf51-left-annotation",
            value: "Editor model released",
            in: app
        )
        assertStrictIsolation(in: app, context: "LF-51 after leaving annotation editor")
        let reopen = element("course-checkpoint-lf51-reopen-annotation", in: app)
        XCTAssertTrue(waitUntilHittable(reopen, timeout: 10))
        reopen.tap()
        assertMarker(
            "course-checkpoint-lf51-reopened-annotation",
            value: "checkpoint-editor-page",
            in: app
        )
        assertMarker(
            "course-checkpoint-lf51-annotation-projection",
            value: "id=checkpoint-annotation;page=checkpoint-editor-page;block=checkpoint-selection-block;path=0;range=0:16",
            in: app,
            requiresHittable: false
        )
        assertStrictIsolation(in: app, context: "LF-51 after reopening annotation editor")
        tapRenderedAnnotation(in: app)
        capture("LF-51 reopened rendered annotation opened", app: app)
        assertStrictIsolation(in: app, context: "LF-51 after reopened annotation action")
        app.terminate()

        app = launch(.lf51ReopenedAnnotation)
        assertMarker(
            "course-checkpoint-lf51-reopened-annotation",
            value: "checkpoint-editor-page",
            in: app
        )
        assertMarker(
            "course-checkpoint-lf51-annotation-projection",
            value: "id=checkpoint-annotation;page=checkpoint-editor-page;block=checkpoint-selection-block;path=0;range=0:16",
            in: app,
            requiresHittable: false
        )
        tapRenderedAnnotation(in: app)
        capture("LF-51 fresh fixture rendered annotation opened", app: app)
        assertStrictIsolation(in: app, context: "LF-51 after fresh-fixture annotation action")
    }

    @MainActor
    private func launch(
        _ scenario: Scenario,
        runToken: String = UUID().uuidString.lowercased()
    ) -> XCUIApplication {
        launch(arguments: [
            "--ui-test-course-editor-checkpoints",
            scenario.rawValue,
            "--checkpoint-run-token",
            runToken,
        ])
    }

    @MainActor
    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchArguments += arguments
        app.launch()
        assertStrictIsolation(in: app, context: "launch")
        return app
    }

    @MainActor
    private func assertStrictIsolation(in app: XCUIApplication, context: String) {
        let root = element("courseEditorCheckpoint.strictRoot", in: app)
        XCTAssertTrue(
            root.waitForExistence(timeout: 10),
            "\(context): strict editor root did not render"
        )
        XCTAssertEqual(
            root.label,
            "STRICT EDITOR NON-LIVE FIXTURE ROOT · LIVE LIFECYCLE SUPPRESSED",
            "\(context): strict editor root did not attest that live lifecycle was suppressed"
        )
        let initialCounter = element(
            "courseEditorCheckpoint.forbiddenSideEffects",
            in: app
        )
        XCTAssertTrue(
            initialCounter.waitForExistence(timeout: 10),
            "\(context): strict editor sentinel did not render"
        )

        // Cross a TimelineView refresh tick, then reacquire the element so this
        // assertion samples the live post-action sentinel rather than launch state.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let liveCounter = element(
            "courseEditorCheckpoint.forbiddenSideEffects",
            in: app
        )
        let zero = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@ AND value == %@",
                "Forbidden production entry events · 0",
                "0"
            ),
            object: liveCounter
        )
        let details = element(
            "courseEditorCheckpoint.forbiddenSideEffectDetails",
            in: app
        )
        let failure = "\(context): strict editor root reached forbidden production entries: \(details.exists ? details.label : "none")"
        XCTAssertEqual(
            XCTWaiter.wait(for: [zero], timeout: 5),
            .completed,
            failure
        )
        XCTAssertEqual(
            liveCounter.label,
            "Forbidden production entry events · 0",
            failure
        )
        XCTAssertEqual(
            liveCounter.value as? String,
            "0",
            failure
        )
        XCTAssertFalse(
            details.exists,
            "\(context): lifecycle/forbidden event details should be absent at zero"
        )
    }

    @MainActor
    private func tapRenderedAnnotation(in app: XCUIApplication) {
        let expectedValue = "id=checkpoint-annotation;page=checkpoint-editor-page;block=checkpoint-selection-block;path=0;range=0:16"
        let block = element("native-editor-block-0", in: app)
        XCTAssertTrue(
            waitUntilHittable(block, timeout: 10),
            "The rendered annotated block was not hittable"
        )

        let opened = element("course-checkpoint-lf51-annotation-opened", in: app)
        for horizontalOffset in [0.04, 0.10, 0.18, 0.26, 0.34] {
            block.coordinate(
                withNormalizedOffset: CGVector(dx: horizontalOffset, dy: 0.5)
            ).tap()
            assertStrictIsolation(
                in: app,
                context: "LF-51 after annotation tap at horizontal offset \(horizontalOffset)"
            )
            if opened.waitForExistence(timeout: 1) {
                XCTAssertEqual(opened.value as? String, expectedValue)
                return
            }
        }
        XCTFail("Tapping the actual rendered annotation did not invoke onOpenTextAnnotation")
    }

    @MainActor
    private func assertMarker(
        _ identifier: String,
        value: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        requiresHittable: Bool = true
    ) {
        let marker = element(identifier, in: app)
        let appeared = marker.waitForExistence(timeout: timeout)
        let setupError = element("course-checkpoint-setup-error", in: app)
        let setupErrorDiagnostic = setupError.exists
            ? "; setup error label=\(setupError.label), value=\(String(describing: setupError.value))"
            : ""
        XCTAssertTrue(appeared, "Checkpoint marker \(identifier) did not appear\(setupErrorDiagnostic)")
        XCTAssertEqual(marker.value as? String, value)
        if requiresHittable {
            XCTAssertTrue(
                waitUntilHittable(marker, timeout: 5),
                "Checkpoint marker \(identifier) was not hittable"
            )
        }
    }

    @MainActor
    private func assertDocumentOrder(_ order: String, in app: XCUIApplication) {
        let marker = element("course-checkpoint-document-order", in: app)
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", order),
            object: marker
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "Document order did not become \(order); actual value: \(String(describing: marker.value))"
        )
    }

    @MainActor
    private func assertBlockValue(
        _ identifier: String,
        contains expectedText: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) {
        let block = element(identifier, in: app)
        XCTAssertTrue(
            block.waitForExistence(timeout: timeout),
            "Native editor block \(identifier) did not appear."
        )
        XCTAssertTrue(
            waitUntil(timeout: timeout, pollInterval: 0.02) {
                (block.value as? String)?.contains(expectedText) == true
            },
            "Native editor block \(identifier) value did not contain \(expectedText); actual value: \(String(describing: block.value))."
        )
    }

    @MainActor
    private func requireReceiptValue(
        _ element: XCUIElement,
        phase: String
    ) -> String {
        XCTAssertTrue(
            waitUntil(timeout: 8, pollInterval: 0.05) {
                (element.value as? String)?.contains("phase=\(phase)") == true
            },
            "Runtime probe did not reach phase \(phase)."
        )
        guard let value = element.value as? String else {
            XCTFail("Runtime probe did not expose a receipt value.")
            return ""
        }
        return value
    }

    private func receiptFields(_ receipt: String) -> [String: String] {
        receipt.split(separator: ";").reduce(into: [:]) { fields, component in
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return }
            fields[String(parts[0])] = String(parts[1])
        }
    }

    @MainActor
    private func elementContainingText(
        _ text: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name) screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
