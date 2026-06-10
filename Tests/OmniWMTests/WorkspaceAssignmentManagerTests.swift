import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import Testing

private func makeTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.assignment.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeTestMonitor(
    displayId: CGDirectDisplayID = 1,
    name: String = "Test",
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    let frame = CGRect(x: 0, y: 0, width: width, height: height)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

private func makeTestWindow(windowId: Int) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

@Suite(.serialized) struct WorkspaceAssignmentManagerTests {
    @Test @MainActor func assignWindowPreservesWorkspaceFromCacheForRecentlyRemoved() async {
        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]
        let controller = WMController(settings: settings)
        let monitor = makeTestMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])

        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        let testPid: pid_t = 99999
        let testBundleId = "com.test.app"
        let ax = makeTestWindow(windowId: 101)

        // Step 1: Add window to WS1
        let token = controller.workspaceManager.addWindow(
            ax, pid: testPid, windowId: 101, to: ws1
        )

        // Step 2: Record removal (simulating what removeWindow does)
        controller.workspaceManager.assignmentManager.recordRemoval(
            token: token, workspaceId: ws1, bundleId: testBundleId
        )

        // Step 3: Remove the window from tracking
        controller.workspaceManager.removeWindow(pid: testPid, windowId: 101)

        // Step 4: Re-assign with .admission reason targeting WS2
        let ax2 = makeTestWindow(windowId: 102)
        let newToken = controller.workspaceManager.assignmentManager.assignWindowToWorkspace(
            ax2,
            pid: testPid,
            windowId: 102,
            to: ws2,
            reason: .admission,
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: testBundleId,
                workspaceId: ws2,
                mode: .tiling
            )
        )

        // Assert: window lands on WS1 (cached), not WS2 (target)
        let entry = controller.workspaceManager.entry(for: newToken)
        #expect(entry != nil)
        #expect(entry?.workspaceId == ws1)
    }

    @Test @MainActor func assignWindowUsesTargetWorkspaceWhenNoCacheHit() async {
        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]
        let controller = WMController(settings: settings)
        let monitor = makeTestMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])

        guard let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspace")
            return
        }

        let testPid: pid_t = 99998
        let ax = makeTestWindow(windowId: 201)

        // Assign with .admission reason and no prior removal
        let token = controller.workspaceManager.assignmentManager.assignWindowToWorkspace(
            ax,
            pid: testPid,
            windowId: 201,
            to: ws2,
            reason: .admission
        )

        // Assert: window lands on WS2 (no cache hit)
        let entry = controller.workspaceManager.entry(for: token)
        #expect(entry != nil)
        #expect(entry?.workspaceId == ws2)
    }

    @Test @MainActor func cacheExpiresAfterTTL() async throws {
        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]
        let controller = WMController(settings: settings)
        let monitor = makeTestMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])

        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        let testPid: pid_t = 99997
        let testBundleId = "com.test.expiry"
        let ax = makeTestWindow(windowId: 301)

        var fakeClock = Date()
        controller.workspaceManager.assignmentManager.clockForTests = { fakeClock }

        let token = controller.workspaceManager.addWindow(
            ax, pid: testPid, windowId: 301, to: ws1
        )
        controller.workspaceManager.assignmentManager.recordRemoval(
            token: token, workspaceId: ws1, bundleId: testBundleId
        )
        controller.workspaceManager.removeWindow(pid: testPid, windowId: 301)

        fakeClock = fakeClock.addingTimeInterval(2.1)

        let ax2 = makeTestWindow(windowId: 302)
        let newToken = controller.workspaceManager.assignmentManager.assignWindowToWorkspace(
            ax2,
            pid: testPid,
            windowId: 302,
            to: ws2,
            reason: .admission,
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: testBundleId,
                workspaceId: ws2,
                mode: .tiling
            )
        )

        let entry = controller.workspaceManager.entry(for: newToken)
        #expect(entry != nil)
        #expect(entry?.workspaceId == ws2)
    }

    @Test @MainActor func dedupSkipsAlreadyTrackedWindow() async {
        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]
        let controller = WMController(settings: settings)
        let monitor = makeTestMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])

        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        let testPid: pid_t = 99996
        let ax = makeTestWindow(windowId: 401)

        // First add via addWindow
        let originalToken = controller.workspaceManager.addWindow(
            ax, pid: testPid, windowId: 401, to: ws1
        )

        // Try to assign again via the gate to WS2
        let returnedToken = controller.workspaceManager.assignmentManager.assignWindowToWorkspace(
            ax,
            pid: testPid,
            windowId: 401,
            to: ws2,
            reason: .admission
        )

        // Assert: returned token is the same, and window stays on WS1
        #expect(returnedToken == originalToken)
        let entry = controller.workspaceManager.entry(for: returnedToken)
        #expect(entry?.workspaceId == ws1)
    }

    @Test @MainActor func transferReasonBypassesCache() async {
        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]
        let controller = WMController(settings: settings)
        let monitor = makeTestMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])

        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        let testPid: pid_t = 99995
        let testBundleId = "com.test.transfer"
        let ax = makeTestWindow(windowId: 501)

        // Add and remove
        let token = controller.workspaceManager.addWindow(
            ax, pid: testPid, windowId: 501, to: ws1
        )
        controller.workspaceManager.assignmentManager.recordRemoval(
            token: token, workspaceId: ws1, bundleId: testBundleId
        )
        controller.workspaceManager.removeWindow(pid: testPid, windowId: 501)

        // Re-assign with .transfer reason (should NOT use cache)
        let ax2 = makeTestWindow(windowId: 502)
        let newToken = controller.workspaceManager.assignmentManager.assignWindowToWorkspace(
            ax2,
            pid: testPid,
            windowId: 502,
            to: ws2,
            reason: .transfer,
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: testBundleId,
                workspaceId: ws2,
                mode: .tiling
            )
        )

        // Assert: window lands on WS2 (cache bypassed for transfer)
        let entry = controller.workspaceManager.entry(for: newToken)
        #expect(entry != nil)
        #expect(entry?.workspaceId == ws2)
    }

    @Test @MainActor func cacheSweepsExpiredEntriesWhenOverSizeCap() async {
        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]
        let controller = WMController(settings: settings)
        let monitor = makeTestMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])

        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        else {
            Issue.record("Failed to create workspace")
            return
        }

        var fakeClock = Date()
        let wam = controller.workspaceManager.assignmentManager
        wam.clockForTests = { fakeClock }

        for i in 0 ..< 70 {
            let token = WindowToken(pid: pid_t(60_000 + i), windowId: 6000 + i)
            wam.recordRemoval(token: token, workspaceId: ws1, bundleId: "com.test.sweep.\(i)")
        }

        fakeClock = fakeClock.addingTimeInterval(2.1)

        let freshToken = WindowToken(pid: 70_000, windowId: 7000)
        wam.recordRemoval(token: freshToken, workspaceId: ws1, bundleId: "com.test.fresh")

        let cached = wam.cachedWorkspaceForTests(pid: 70_000, bundleId: "com.test.fresh")
        #expect(cached == ws1, "Fresh entry should survive sweep")

        let expired = wam.cachedWorkspaceForTests(pid: 60_000, bundleId: "com.test.sweep.0")
        #expect(expired == nil, "Expired entry should be swept")
    }
}
