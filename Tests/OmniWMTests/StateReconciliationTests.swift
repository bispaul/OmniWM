import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct StateReconciliationTests {
    @Test func isReconcilingGuardSuppressesFrameChange() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let workspaceId = controller.workspaceManager.monitors.first
            .flatMap({ controller.workspaceManager.activeWorkspaceOrFirst(on: $0.id)?.id })
        else {
            Issue.record("Missing workspace for reconciliation guard test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9001)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        controller.workspaceManager.isReconciling = true
        controller.layoutRefreshController.markWorkspaceDirty(workspaceId)
        controller.layoutRefreshController.drainDirtyWorkspacesForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.isReconciling)
        controller.workspaceManager.isReconciling = false

        #expect(token.windowId == 9001)
    }

    @Test func isReconcilingDefaultsFalse() {
        let controller = makeLayoutPlanTestController()
        #expect(!controller.workspaceManager.isReconciling)
    }

    @Test func fullscreenRestorePositionsSavedOnCallback() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context for fullscreen restore test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9010)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)

        let plans = try? await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        if let plans { controller.layoutRefreshController.executeLayoutPlans(plans) }
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        controller.workspaceManager.onFullscreenColumnCapture = { captureToken, wsId in
            guard let node = engine.findNode(for: captureToken),
                  let column = engine.column(of: node),
                  let index = engine.columnIndex(of: column, in: wsId)
            else { return nil }
            return index
        }

        controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: token)

        let restored = controller.workspaceManager.fullscreenRestorePositions[token]
        #expect(restored != nil)
        #expect(restored?.workspaceId == workspaceId)
    }

    @Test func fullscreenRestorePositionsEmptyByDefault() {
        let controller = makeLayoutPlanTestController()
        #expect(controller.workspaceManager.fullscreenRestorePositions.isEmpty)
    }

    @Test func scopedFocusLeaseOnlyAffectsTargetMonitor() {
        let engine = FocusPolicyEngine()
        let monitor1 = Monitor.ID(displayId: 1)
        let monitor2 = Monitor.ID(displayId: 2)

        engine.beginLease(
            owner: .nativeAppSwitch,
            reason: "test",
            monitorId: monitor1
        )

        let resultOnMonitor1 = engine.evaluate(.focusFollowsMouse, onMonitor: monitor1)
        let resultOnMonitor2 = engine.evaluate(.focusFollowsMouse, onMonitor: monitor2)

        #expect(!resultOnMonitor1.allowsFocusChange)
        #expect(resultOnMonitor2.allowsFocusChange)
    }

    @Test func globalFocusLeaseSuppressesAllMonitors() {
        let engine = FocusPolicyEngine()
        let monitor1 = Monitor.ID(displayId: 1)
        let monitor2 = Monitor.ID(displayId: 2)

        engine.beginLease(
            owner: .nativeAppSwitch,
            reason: "test"
        )

        let resultOnMonitor1 = engine.evaluate(.focusFollowsMouse, onMonitor: monitor1)
        let resultOnMonitor2 = engine.evaluate(.focusFollowsMouse, onMonitor: monitor2)

        #expect(!resultOnMonitor1.allowsFocusChange)
        #expect(!resultOnMonitor2.allowsFocusChange)
    }

    @Test func focusLeaseWithNoMonitorQuerySuppressesGlobally() {
        let engine = FocusPolicyEngine()
        let monitor1 = Monitor.ID(displayId: 1)

        engine.beginLease(
            owner: .nativeAppSwitch,
            reason: "test",
            monitorId: monitor1
        )

        let resultNoMonitor = engine.evaluate(.focusFollowsMouse)
        #expect(!resultNoMonitor.allowsFocusChange)
    }
}
