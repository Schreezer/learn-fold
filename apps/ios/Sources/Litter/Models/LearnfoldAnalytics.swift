import Foundation
#if os(iOS)
import PostHog
#endif

@MainActor
final class LearnfoldAnalytics {
    static let shared = LearnfoldAnalytics()
    private var configured = false

    private init() {}

    func configure() {
        #if os(iOS)
        // Local development and all UI/unit fixtures must never enter production analytics.
        guard Self.productionCaptureAllowed, isEnabled, !configured,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let config = Self.configuration(enabled: isEnabled)
        PostHogSDK.shared.setup(config)
        configured = true
        setEnabled(isEnabled)
        #endif
    }

    static var productionCaptureAllowed: Bool {
        #if DEBUG || !os(iOS)
        false
        #else
        true
        #endif
    }

    #if os(iOS)
    static func configuration(enabled: Bool) -> PostHogConfig {
        let config = PostHogConfig(
            projectToken: "phc_qHU3sUFAnfFnJEJDmC4t3Kwyzh6uKgxXPPTN7eH2J4eF",
            host: "https://us.i.posthog.com"
        )
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.captureElementInteractions = false
        config.capturePushNotificationSubscriptions = false
        config.capturePushNotificationOpened = false
        config.enableSwizzling = false
        config.sessionReplay = false
        config.surveys = false
        config.preloadFeatureFlags = false
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        config.errorTrackingConfig.autoCapture = false
        config.optOut = !enabled
        config.maxQueueSize = 500
        config.setBeforeSend { event in
            guard let properties = LearnfoldAnalyticsPolicy.sanitized(event: event.event, properties: event.properties) else { return nil }
            event.properties = properties
            return event
        }
        return config
    }
    #endif

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: LearnfoldAnalyticsPolicy.preferenceKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: LearnfoldAnalyticsPolicy.preferenceKey)
        #if os(iOS)
        if enabled {
            if !configured { configure() }
            else { PostHogSDK.shared.optIn() }
        } else if configured {
            PostHogSDK.shared.optOut()
            PostHogSDK.shared.close()
            configured = false
        }
        #endif
    }

    func capture(_ event: LearnfoldAnalyticsEvent, questionContext: Bool? = nil, replacingPage: Bool? = nil) {
        #if os(iOS)
        guard configured, isEnabled else { return }
        var properties: [String: Any] = [
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        ]
        if let questionContext { properties["question_context"] = questionContext ? "selection" : "course" }
        if let replacingPage { properties["navigation"] = replacingPage ? "continue" : "open" }
        PostHogSDK.shared.capture(event.rawValue, properties: properties)
        #endif
    }

    func flush() {
        #if os(iOS)
        guard configured, isEnabled else { return }
        PostHogSDK.shared.flush()
        #endif
    }
}
