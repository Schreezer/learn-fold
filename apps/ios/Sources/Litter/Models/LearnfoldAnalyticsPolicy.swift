import Foundation

/// Only event names and structural properties belong in analytics. No learner content or IDs.
enum LearnfoldAnalyticsEvent: String, CaseIterable, Sendable {
    case appOpened = "app_opened"
    case courseStarted = "course_started"
    case questionSubmitted = "question_submitted"
    case planApproved = "course_plan_approved"
    case courseReady = "course_ready"
    case pageOpened = "course_page_opened"
}

enum LearnfoldAnalyticsPolicy {
    static let preferenceKey = "learnfold.analytics.enabled"

    static func sanitized(event: String, properties: [String: Any]) -> [String: Any]? {
        guard LearnfoldAnalyticsEvent(rawValue: event) != nil else { return nil }
        // Drop every SDK-added property unless explicitly needed for aggregate product analysis.
        let allowed = Set(["app_version", "app_build", "question_context", "navigation", "source", "environment"])
        var result = properties.filter { allowed.contains($0.key) }
        result["source"] = "learnfold_ios"
        result["environment"] = "production"
        result["$process_person_profile"] = false
        result["$geoip_disable"] = true
        result["$ip"] = NSNull()
        return result
    }
}
