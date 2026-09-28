# Learnfold product analytics

PostHog project 601129 uses the US ingestion host. Its public project token is configured in `LearnfoldAnalytics.swift` and the website's `wrangler.toml`. This token permits event ingestion, not reading private analytics or waitlist data.

Dashboard: https://us.posthog.com/project/601129/dashboard/2079342

- Landing comparison: https://us.posthog.com/project/601129/insights/o6BGvZrf
- App usage: https://us.posthog.com/project/601129/insights/YiwqQZW3

## iOS events

| Event | Trigger | Meaning |
|---|---|---|
| app_opened | Scene becomes active | An app visit, including foreground returns |
| course_started | A fresh course workspace is started | The learner entered the course creation flow |
| question_submitted | A learner submission passes local guards | Submission intent, not provider acceptance or an answer |
| course_plan_approved | The approved plan is saved | The learner approved a course plan |
| course_ready | The current workspace first finishes generation | A course became available to learn |
| course_page_opened | A course page navigation is requested | Opening/continuing a page, not finishing reading |

The `question_context` property is `selection` or `course`. `navigation` is `continue` or `open`. These are structural labels only. The event filter drops all fields except these labels, app version/build, fixed source/environment, and explicit privacy controls. SDK-added device details, URLs, user profiles and arbitrary content are removed before queueing. Random install IDs remain necessary for active-install counts.

PostHog iOS 3.72.0 is pinned through `project.yml`; regenerate Xcode with `make xcgen`. The SDK handles queueing/retry. Automatic lifecycle/screen/element capture, push subscriptions, session replay, surveys, error capture and feature flag preloading are disabled. The SDK still retrieves its public project configuration. No Apple advertising identifier, email, course ID/title/content, source document, question text or selected passage is sent.

Analytics is enabled in Release builds and can be disabled in Settings using Share anonymous usage analytics. Debug builds and XCTest launches never configure production capture. Website and app identities are deliberately separate. This does not establish website-to-install or signup-to-retention attribution.

## Release and verification

The code and privacy manifest are updated. This work does not upload a TestFlight build or change the currently distributed app. Before publishing a build with analytics, reconcile the App Store Connect privacy questionnaire with the new anonymous installation identifiers and product interaction analytics. The website privacy policy describes the new app behavior.

Focused tests: `LitterTests/LearnfoldAnalyticsTests`. They validate the event/property allowlist and the SDK's privacy configuration without sending production events. Simulator compilation and unit tests do not prove receipt from a distributed Release app. Check real app events after the next authorized release; do not manufacture production usage events to populate the dashboard.

## Website

The waitlist is stored in Cloudflare D1. Completed, newly saved signups are attributed atomically to the assigned copy. The website's `EXPERIMENT.md` describes previews, cookie lifetime, abuse controls, privacy opt-outs, results reporting and private CSV export. The dashboard queries actual events only. Empty results mean no measured events in the selected period, not a winning variant.

### September 9 verification

The iOS simulator application build succeeded with the SDK, event hooks and Settings control. A host Swift executable using the actual policy source passed checks for unknown event rejection, sensitive property removal and anonymous/geolocation flags. Full XCTest execution was attempted on the iOS 27 and iOS 26.5 iPhone 17 Pro simulators; both stalled in runner startup and were stopped. The XCTest configuration assertions compiled, but are not reported as executed passes. The new Settings control has not received runtime visual verification. No TestFlight upload or distributed-app analytics receipt was performed.
