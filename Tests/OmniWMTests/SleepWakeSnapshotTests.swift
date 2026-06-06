import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct SleepWakeSnapshotTests {

    @Test func captureSnapshotStoresMonitorIdsAndPlacements() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing context")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 9801)
        engine.syncWindows([token], in: ws1, selectedNodeId: nil)
        _ = controller.workspaceManager.setManagedFocus(token, in: ws1, onMonitor: monitor.id)

        let plans = try? await controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [ws1])
        if let plans { controller.layoutRefreshController.executeLayoutPlans(plans) }
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let snapshot = controller.serviceLifecycleManager.captureStateSnapshot()
        #expect(snapshot != nil)
        #expect(snapshot!.monitorIds.contains(monitor.id))
        #expect(snapshot!.focusedToken == token)
        #expect(!snapshot!.niriPlacements.isEmpty)
    }

    @Test func pendingWakeReconciliationDefaultsFalse() {
        let controller = makeLayoutPlanTestController()
        #expect(!controller.serviceLifecycleManager.pendingWakeReconciliation)
    }

    @Test func snapshotCapturesViewportStates() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing context")
            return
        }

        let snapshot = controller.serviceLifecycleManager.captureStateSnapshot()
        #expect(snapshot != nil)
        #expect(snapshot!.viewportStates[ws1] != nil)
    }
}
