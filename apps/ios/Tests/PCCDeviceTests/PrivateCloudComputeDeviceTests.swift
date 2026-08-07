import XCTest
import UIKit
@testable import Litter

#if LEARNFOLD_PRIVATE_CLOUD_COMPUTE_SDK && canImport(FoundationModels)
import FoundationModels

/// Opt-in integration tests for Apple's live Private Cloud Compute service.
///
/// These tests intentionally live in a separate target so normal unit and simulator
/// suites do not consume a learner's PCC quota. Run them with
/// `apps/ios/scripts/test-pcc-on-device.sh`.
@available(iOS 27.0, *)
@MainActor
final class PrivateCloudComputeDeviceTests: XCTestCase {
    private let responseTimeout: TimeInterval = 120

    func testPreflightReportsAvailabilityAndQuota() throws {
        try requirePhysicalDevice()

        let model = PrivateCloudComputeLanguageModel()
        let report = PCCPreflightReport(model: model)
        addJSONAttachment(report, name: "pcc-preflight")

        guard case .available = model.availability else {
            XCTFail("PCC is unavailable: \(report.availability)")
            return
        }
        XCTAssertFalse(
            model.quotaUsage.isLimitReached,
            "PCC quota is exhausted. See the pcc-preflight attachment for reset details."
        )
    }

    func testMinimalStreamingResponse() async throws {
        let model = try availableModel()
        let session = LanguageModelSession(
            model: model,
            instructions: "Be concise. This is a synthetic connectivity test."
        )

        let report = await runProbe(
            name: "minimal-stream",
            session: session,
            prompt: "Reply with the exact token PCC_OK and nothing else.",
            options: GenerationOptions(
                samplingMode: .greedy,
                temperature: 0,
                maximumResponseTokens: 16
            )
        )

        XCTAssertFalse(report.timedOut, "PCC returned no completion within \(responseTimeout)s.")
        XCTAssertNil(report.errorType, report.errorDescription ?? "PCC generation failed.")
        XCTAssertNotNil(report.firstOutputSeconds, "PCC completed without yielding any output.")
        XCTAssertFalse(report.responsePreview.isEmpty, "PCC returned an empty response.")
    }

    func testRequiredToolCallCompletes() async throws {
        let model = try availableModel()
        let recorder = PCCProbeToolRecorder()
        let tool = try PCCProbeTool(recorder: recorder)
        let session = LanguageModelSession(
            model: model,
            tools: [tool],
            instructions: """
            Always call pcc_record_probe exactly once with the marker supplied by the learner. \
            After the tool returns, briefly confirm completion.
            """
        )

        let marker = "AEON_PCC_TOOL_OK"
        let report = await runProbe(
            name: "required-tool-call",
            session: session,
            prompt: "Record marker \(marker).",
            options: GenerationOptions(
                samplingMode: .greedy,
                temperature: 0,
                maximumResponseTokens: 48,
                // `.required` also requires another tool call after the first tool
                // result, which can loop until PCC reports maxTurnsLimitReached.
                // `.allowed` matches Learnfold's real course-agent configuration.
                toolCallingMode: .allowed
            )
        )
        let calls = await recorder.calls
        addJSONAttachment(calls, name: "pcc-tool-calls")

        XCTAssertFalse(report.timedOut, "PCC tool generation timed out.")
        XCTAssertNil(report.errorType, report.errorDescription ?? "PCC tool generation failed.")
        XCTAssertEqual(calls.count, 1, "Expected exactly one PCC tool invocation.")
        XCTAssertTrue(
            calls.first?.contains(marker) == true,
            "The PCC tool did not receive the requested marker."
        )
    }

    func testLearnfoldCoursePlanToolBoundary() async throws {
        _ = try availableModel()

        let workspaceID = "pcc-device-plan-\(UUID().uuidString.lowercased())"
        let sessionID = UUID()
        let workspaceURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Apps/Courses", isDirectory: true)
            .appendingPathComponent(workspaceID, isDirectory: true)
        let runtime = SystemAppleCourseAgentRuntime()
        var plan: CourseBrief?
        var latestResponse = ""
        defer {
            runtime.remove(sessionID: sessionID, workspaceID: workspaceID)
            try? FileManager.default.removeItem(at: workspaceURL)
        }

        do {
            try await runtime.send(
                sessionID: sessionID,
                providerID: CourseAgentProvider.applePrivateCloud,
                workspaceID: workspaceID,
                prompt: """
                Make exactly two beginner chapters about Swift actors. Present the course plan now. \
                Do not write or edit course pages.
                """,
                onAccepted: {},
                onPartialResponse: { latestResponse = $0 },
                onCoursePlan: { plan = $0 }
            )
        } catch {
            let persistedMessages = await runtime.restoredMessages(
                sessionID: sessionID,
                workspaceID: workspaceID
            )
            addJSONAttachment(
                PCCCoursePlanFailureReport(
                    errorType: String(reflecting: type(of: error)),
                    errorDescription: String(describing: error),
                    responseCharacters: latestResponse.count,
                    didPresentPlan: plan != nil,
                    persistedMessageCount: persistedMessages.count
                ),
                name: "learnfold-pcc-course-plan-failure"
            )
            addJSONAttachment(
                persistedMessages,
                name: "learnfold-pcc-failure-transcript-projection"
            )
            throw error
        }

        if let plan {
            addJSONAttachment(plan, name: "learnfold-pcc-course-plan")
        }
        let persistedMessages = await runtime.restoredMessages(
            sessionID: sessionID,
            workspaceID: workspaceID
        )
        addJSONAttachment(persistedMessages, name: "learnfold-pcc-transcript-projection")

        let resolvedPlan = try XCTUnwrap(
            plan,
            "PCC completed without invoking Learnfold's course-plan tool."
        )
        XCTAssertEqual(resolvedPlan.chapters.count, 2)
        XCTAssertFalse(resolvedPlan.planID.isEmpty)
        XCTAssertFalse(resolvedPlan.title.isEmpty)
        XCTAssertFalse(
            latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && persistedMessages.count < 2,
            "PCC produced neither a visible response nor a persisted completed turn."
        )
    }

    private func availableModel() throws -> PrivateCloudComputeLanguageModel {
        try requirePhysicalDevice()
        let model = PrivateCloudComputeLanguageModel()
        guard case .available = model.availability else {
            throw XCTSkip("PCC is unavailable: \(PCCPreflightReport(model: model).availability)")
        }
        guard !model.quotaUsage.isLimitReached else {
            throw XCTSkip("PCC daily quota is exhausted.")
        }
        return model
    }

    private func requirePhysicalDevice() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("PCC device diagnostics must run on a signed physical iOS 27 device.")
#endif
    }

    private func runProbe(
        name: String,
        session: LanguageModelSession,
        prompt: String,
        options: GenerationOptions
    ) async -> PCCProbeReport {
        let state = PCCProbeState(name: name)
        let finished = expectation(description: "\(name) PCC request finished")
        let generationTask = Task {
            let startedAt = Date()
            do {
                for try await snapshot in session.streamResponse(to: prompt, options: options) {
                    await state.record(snapshot: snapshot.content, startedAt: startedAt)
                }
                await state.complete(startedAt: startedAt)
            } catch {
                await state.fail(error, startedAt: startedAt)
            }
            finished.fulfill()
        }

        let waiterResult = await XCTWaiter.fulfillment(
            of: [finished],
            timeout: responseTimeout
        )
        if waiterResult != .completed {
            await state.timeOut(after: responseTimeout)
            generationTask.cancel()
        }

        let report = await state.report
        addJSONAttachment(report, name: "pcc-\(name)-report")
        return report
    }

    private func addJSONAttachment<Value: Encodable>(_ value: Value, name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let text = (try? encoder.encode(value))
            .map { String(decoding: $0, as: UTF8.self) }
            ?? String(describing: value)
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@available(iOS 27.0, *)
private struct PCCPreflightReport: Codable {
    let deviceName: String
    let systemName: String
    let systemVersion: String
    let availability: String
    let quotaStatus: String
    let isApproachingLimit: Bool?
    let isLimitReached: Bool
    let resetDate: Date?

    init(model: PrivateCloudComputeLanguageModel) {
        deviceName = UIDevice.current.name
        systemName = UIDevice.current.systemName
        systemVersion = UIDevice.current.systemVersion
        switch model.availability {
        case .available:
            availability = "available"
        case .unavailable(.deviceNotEligible):
            availability = "unavailable.deviceNotEligible"
        case .unavailable(.systemNotReady):
            availability = "unavailable.systemNotReady"
        @unknown default:
            availability = "unavailable.unknown"
        }
        switch model.quotaUsage.status {
        case .belowLimit(let status):
            quotaStatus = "belowLimit"
            isApproachingLimit = status.isApproachingLimit
        case .limitReached:
            quotaStatus = "limitReached"
            isApproachingLimit = nil
        }
        isLimitReached = model.quotaUsage.isLimitReached
        resetDate = model.quotaUsage.resetDate
    }
}

private struct PCCProbeReport: Codable, Sendable {
    let name: String
    var snapshotCount = 0
    var responseCharacters = 0
    var responsePreview = ""
    var firstOutputSeconds: TimeInterval?
    var totalSeconds: TimeInterval?
    var timedOut = false
    var errorType: String?
    var errorDescription: String?
}

private struct PCCCoursePlanFailureReport: Codable {
    let errorType: String
    let errorDescription: String
    let responseCharacters: Int
    let didPresentPlan: Bool
    let persistedMessageCount: Int
}

private actor PCCProbeState {
    private(set) var report: PCCProbeReport

    init(name: String) {
        report = PCCProbeReport(name: name)
    }

    func record(snapshot: String, startedAt: Date) {
        report.snapshotCount += 1
        report.responseCharacters = snapshot.count
        report.responsePreview = String(snapshot.prefix(240))
        if report.firstOutputSeconds == nil, !snapshot.isEmpty {
            report.firstOutputSeconds = Date().timeIntervalSince(startedAt)
        }
    }

    func complete(startedAt: Date) {
        report.totalSeconds = Date().timeIntervalSince(startedAt)
    }

    func fail(_ error: Error, startedAt: Date) {
        report.totalSeconds = Date().timeIntervalSince(startedAt)
        report.errorType = String(reflecting: type(of: error))
        report.errorDescription = String(describing: error)
    }

    func timeOut(after timeout: TimeInterval) {
        report.timedOut = true
        report.totalSeconds = timeout
        report.errorType = "PCCProbeTimeout"
        report.errorDescription = "No completion or error arrived within \(Int(timeout)) seconds."
    }
}

private actor PCCProbeToolRecorder {
    private(set) var calls: [String] = []

    func record(_ argumentsJSON: String) {
        calls.append(argumentsJSON)
    }
}

@available(iOS 27.0, *)
private struct PCCProbeTool: Tool {
    let name = "pcc_record_probe"
    let description = "Records a synthetic marker for PCC transport testing. It has no side effects."
    let parameters: GenerationSchema
    private let recorder: PCCProbeToolRecorder

    init(recorder: PCCProbeToolRecorder) throws {
        self.recorder = recorder
        let root = DynamicGenerationSchema(
            name: "pcc_record_probe_arguments",
            properties: [
                .init(
                    name: "marker",
                    description: "The exact synthetic marker supplied by the learner.",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
            ]
        )
        parameters = try GenerationSchema(root: root, dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        await recorder.record(arguments.jsonString)
        return "Synthetic PCC marker recorded."
    }
}

#else

final class PrivateCloudComputeDeviceTests: XCTestCase {
    func testRequiresTheIOS27PrivateCloudComputeSDK() throws {
        throw XCTSkip("Build this target with the iOS 27 SDK to run PCC device diagnostics.")
    }
}

#endif
