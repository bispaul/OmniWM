import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct WindowClassifierTests {
    @Test func chromeInternalWindowRejected() {
        let info = WindowServerInfo(id: 99999, pid: 100, level: 0, frame: .zero)
        let result = WindowClassifier.preFilter(
            windowId: 99999,
            pid: 100,
            windowInfo: info,
            bundleId: "com.google.Chrome"
        )
        if case let .reject(reason) = result {
            #expect(reason == "chromium-internal-no-title")
        } else {
            Issue.record("Expected Chrome internal window to be rejected")
        }
    }

    @Test func chromeInternalWindowWithEmptyTitleRejected() {
        var info = WindowServerInfo(id: 99998, pid: 100, level: 0, frame: .zero)
        info.title = ""
        let result = WindowClassifier.preFilter(
            windowId: 99998,
            pid: 100,
            windowInfo: info,
            bundleId: "com.google.Chrome"
        )
        if case .reject = result {
            // expected
        } else {
            Issue.record("Expected Chrome window with empty title to be rejected")
        }
    }

    @Test func chromeRegularWindowAdmitted() {
        var info = WindowServerInfo(id: 500, pid: 100, level: 0, frame: .zero)
        info.title = "Google - Chrome"
        let result = WindowClassifier.preFilter(
            windowId: 500,
            pid: 100,
            windowInfo: info,
            bundleId: "com.google.Chrome"
        )
        if case .admit = result {
            // expected
        } else {
            Issue.record("Expected Chrome window with title to be admitted")
        }
    }

    @Test func nonChromeWindowWithNoTitleAdmitted() {
        let info = WindowServerInfo(id: 300, pid: 200, level: 0, frame: .zero)
        let result = WindowClassifier.preFilter(
            windowId: 300,
            pid: 200,
            windowInfo: info,
            bundleId: "com.apple.Safari"
        )
        if case .admit = result {
            // expected
        } else {
            Issue.record("Expected non-Chrome window to be admitted even without title")
        }
    }

    @Test func unknownBundleIdAdmitted() {
        let info = WindowServerInfo(id: 400, pid: 300, level: 0, frame: .zero)
        let result = WindowClassifier.preFilter(
            windowId: 400,
            pid: 300,
            windowInfo: info,
            bundleId: nil
        )
        if case .admit = result {
            // expected
        } else {
            Issue.record("Expected nil bundleId to be admitted")
        }
    }

    @Test func noWindowInfoAdmitsChrome() {
        let result = WindowClassifier.preFilter(
            windowId: 600,
            pid: 100,
            windowInfo: nil,
            bundleId: "com.google.Chrome"
        )
        if case .admit = result {
            // expected
        } else {
            Issue.record("Expected Chrome without windowInfo to be admitted (safe default)")
        }
    }

    @Test func edgeBrowserInternalRejected() {
        let info = WindowServerInfo(id: 88888, pid: 400, level: 0, frame: .zero)
        let result = WindowClassifier.preFilter(
            windowId: 88888,
            pid: 400,
            windowInfo: info,
            bundleId: "com.microsoft.edgemac"
        )
        if case .reject = result {
            // expected
        } else {
            Issue.record("Expected Edge internal window to be rejected")
        }
    }
}
