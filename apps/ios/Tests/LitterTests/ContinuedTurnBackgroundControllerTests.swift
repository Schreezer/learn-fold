import BackgroundTasks
import XCTest
@testable import Litter

@MainActor
final class ContinuedTurnBackgroundControllerTests: XCTestCase {
    @available(iOS 26.0, *)
    private final class SchedulerSpy: ContinuedProcessingTaskScheduling {
        var registeredIdentifiers: [String] = []
        var submittedRequests: [BGTaskRequest] = []
        var cancelledIdentifiers: [String] = []

        func register(identifier: String, handler: @escaping (BGTask) -> Void) -> Bool {
            registeredIdentifiers.append(identifier)
            return true
        }

        func submit(_ request: BGTaskRequest) throws {
            submittedRequests.append(request)
        }

        func cancel(identifier: String) {
            cancelledIdentifiers.append(identifier)
        }
    }

    func testSubmitsAndCancelsAUserInitiatedContinuedProcessingTask() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { nil },
            onExpiration: { _ in XCTFail("The freshly submitted test task should not expire") }
        )
        let key = ThreadKey(serverId: "background-test", threadId: UUID().uuidString)

        let token = controller.beginUserInitiatedTurn(key: key, title: "Background test")

        XCTAssertNotNil(token)
        XCTAssertTrue(controller.hasScheduledOrRunningTasks)
        XCTAssertEqual(scheduler.registeredIdentifiers.count, 1)
        XCTAssertEqual(scheduler.submittedRequests.count, 1)
        XCTAssertTrue(scheduler.registeredIdentifiers[0].hasPrefix("com.example.course.codex-turn."))

        if let token {
            controller.markTurnStartFailed(token)
        }
        XCTAssertFalse(controller.hasScheduledOrRunningTasks)
        XCTAssertEqual(scheduler.cancelledIdentifiers, scheduler.registeredIdentifiers)
    }
}
