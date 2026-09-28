import XCTest
@testable import Litter

final class LearnfoldAnalyticsTests: XCTestCase {
    func testUnknownEventsAndSensitivePropertiesAreDropped() throws {
        XCTAssertNil(LearnfoldAnalyticsPolicy.sanitized(event: "$identify", properties: ["email": "private@example.com"]))
        let properties = try XCTUnwrap(LearnfoldAnalyticsPolicy.sanitized(event: "question_submitted", properties: [
            "question": "Private learner question", "email": "private@example.com", "course_id": "private-course",
            "$current_url": "https://private.example", "$set": ["name": "Private"], "$device_id": "device",
            "app_version": "1.0", "question_context": "selection"
        ]))
        XCTAssertEqual(Set(properties.keys), Set(["app_version", "question_context", "source", "environment", "$process_person_profile", "$geoip_disable", "$ip"]))
        XCTAssertEqual(properties["source"] as? String, "learnfold_ios")
        XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
        XCTAssertTrue(properties["$ip"] is NSNull)
    }

    @MainActor
    func testConfigurationDisablesAutomaticCollectionAndHonorsOptOut() {
        XCTAssertFalse(LearnfoldAnalytics.productionCaptureAllowed)
        let config = LearnfoldAnalytics.configuration(enabled: false)
        XCTAssertTrue(config.optOut)
        XCTAssertFalse(config.captureApplicationLifecycleEvents)
        XCTAssertFalse(config.captureScreenViews)
        XCTAssertFalse(config.captureElementInteractions)
        XCTAssertFalse(config.capturePushNotificationSubscriptions)
        XCTAssertFalse(config.capturePushNotificationOpened)
        XCTAssertFalse(config.enableSwizzling)
        XCTAssertFalse(config.sessionReplay)
        XCTAssertFalse(config.surveys)
        XCTAssertFalse(config.preloadFeatureFlags)
        XCTAssertFalse(config.errorTrackingConfig.autoCapture)
        XCTAssertEqual(config.personProfiles.rawValue, 0)
    }
}
