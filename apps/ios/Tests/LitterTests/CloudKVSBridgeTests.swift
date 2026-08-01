import XCTest
@testable import Litter

@MainActor
final class CloudKVSBridgeTests: XCTestCase {
    func testCloudSyncDefaultsToDisabledWhenInfoKeyIsMissing() {
        XCTAssertFalse(CloudKVSBridge.isCloudSyncEnabled(infoDictionary: [:]))
    }

    func testCloudSyncRespectsExplicitInfoFlag() {
        XCTAssertFalse(
            CloudKVSBridge.isCloudSyncEnabled(
                infoDictionary: ["LearnfoldCourseCloudSyncEnabled": false]
            )
        )
        XCTAssertTrue(
            CloudKVSBridge.isCloudSyncEnabled(
                infoDictionary: ["LearnfoldCourseCloudSyncEnabled": true]
            )
        )
    }

    func testSimulatorDoesNotInitializeUbiquitousKVS() {
#if targetEnvironment(simulator)
        XCTAssertFalse(CloudKVSBridge.runtimeSupportsKVS)
#else
        XCTAssertTrue(CloudKVSBridge.runtimeSupportsKVS)
#endif
    }
}
