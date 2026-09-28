import SwiftUI
import WebKit
import XCTest
@testable import NativeBlockEditorUI

@MainActor
final class BrowserHTMLRecoveryTests: XCTestCase {
    private final class RecordingWebView: WKWebView {
        var documents: [String] = []

        override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
            documents.append(string)
            return nil
        }
    }

    func testProcessTerminationReloadsSandboxedContentOnceThenShowsRetry() {
        var failed = false
        let view = BrowserHTMLBlockView(
            html: "<p>Lesson content</p><iframe src='https://example.com'></iframe>",
            allowNetwork: false,
            allowJavaScript: true,
            identifier: "recovery",
            height: .constant(220),
            loadFailed: Binding(get: { failed }, set: { failed = $0 })
        )
        let coordinator = view.makeCoordinator()
        let webView = RecordingWebView()
        coordinator.loadContent(in: webView)
        XCTAssertEqual(webView.documents.count, 1)
        XCTAssertTrue(webView.documents[0].contains("Lesson content"))
        XCTAssertFalse(webView.documents[0].contains("<iframe"))

        coordinator.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(webView.documents.count, 2)
        XCTAssertEqual(webView.documents[0], webView.documents[1])
        XCTAssertFalse(failed)

        coordinator.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(webView.documents.count, 2, "Repeated crashes must not create a reload loop")
        XCTAssertTrue(failed, "Offer a visible retry instead of an empty block")
    }

    func testCancelledNavigationDoesNotShowFailureButLoadErrorDoes() {
        var failed = false
        let view = BrowserHTMLBlockView(
            html: "<p>Lesson</p>", allowNetwork: false, allowJavaScript: false,
            identifier: "failure", height: .constant(220),
            loadFailed: Binding(get: { failed }, set: { failed = $0 })
        )
        let coordinator = view.makeCoordinator()
        let webView = RecordingWebView()
        coordinator.webView(webView, didFailProvisionalNavigation: nil,
                            withError: URLError(.cancelled))
        XCTAssertFalse(failed)
        coordinator.webView(webView, didFailProvisionalNavigation: nil,
                            withError: URLError(.cannotLoadFromNetwork))
        XCTAssertTrue(failed)
    }
}
