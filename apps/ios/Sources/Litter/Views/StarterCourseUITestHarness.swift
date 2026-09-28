#if DEBUG
import SwiftUI

/// Runs the production library and starter-course installer with isolated storage.
/// No generated course or AI response is supplied by this harness.
struct StarterCourseUITestHarness: View {
    static let argument = "--ui-test-starter-course"
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LEARNFOLD_UI_TESTING"] == "1"
            && ProcessInfo.processInfo.arguments.contains(argument)
    }

    @State private var store: CourseExperienceStore?
    @State private var error: String?

    var body: some View {
        Group {
            if let store {
                CourseExperienceRootView(store: store, onConnectRemoteAgent: {})
            } else if let error {
                Text(error).accessibilityIdentifier("starter-course-test-error")
            } else {
                ProgressView("Opening practice library")
            }
        }
        .task {
            guard store == nil else { return }
            let rawToken = ProcessInfo.processInfo.environment["LEARNFOLD_STARTER_TEST_TOKEN"] ?? ""
            guard let token = UUID(uuidString: rawToken)?.uuidString,
                  let defaults = UserDefaults(suiteName: "StarterCourseUITest.\(token)") else {
                error = "A valid isolated test token is required."
                return
            }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("StarterCourseUITest-\(token)", isDirectory: true)
            if ProcessInfo.processInfo.environment["LEARNFOLD_STARTER_TEST_SELECTION"] == "1" {
                let fixtureStore = CourseExperienceStore(
                    defaults: defaults, hostedRuntime: ReadingFixtureRuntime(), coursesRootURL: root
                )
                fixtureStore.selectedAgentID = CourseAgentProvider.hosted
                store = fixtureStore
            } else {
                store = CourseExperienceStore(defaults: defaults, coursesRootURL: root)
            }
        }
    }
}
#endif
