import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct MoveColumnToWorkspaceTests {
    @Test func adjustActiveColumnIndexShiftsWhenRemovedBeforeActive() {
        var state = ViewportState()
        state.activeColumnIndex = 2
        NiriLayoutEngine.adjustActiveColumnIndex(&state, afterRemovalAt: 1, newColumnCount: 3)
        #expect(state.activeColumnIndex == 1, "Should shift left when column removed before active")
    }

    @Test func adjustActiveColumnIndexUnchangedWhenRemovedAfterActive() {
        var state = ViewportState()
        state.activeColumnIndex = 0
        NiriLayoutEngine.adjustActiveColumnIndex(&state, afterRemovalAt: 2, newColumnCount: 3)
        #expect(state.activeColumnIndex == 0, "Should stay when column removed after active")
    }

    @Test func adjustActiveColumnIndexClampsWhenActiveExceedsCount() {
        var state = ViewportState()
        state.activeColumnIndex = 3
        NiriLayoutEngine.adjustActiveColumnIndex(&state, afterRemovalAt: 3, newColumnCount: 3)
        #expect(state.activeColumnIndex == 2, "Should clamp to newCount - 1")
    }

    @Test func adjustActiveColumnIndexZeroWhenAllColumnsRemoved() {
        var state = ViewportState()
        state.activeColumnIndex = 2
        NiriLayoutEngine.adjustActiveColumnIndex(&state, afterRemovalAt: 0, newColumnCount: 0)
        #expect(state.activeColumnIndex == 0, "Should be 0 when no columns remain")
    }

    // MARK: - moveColumnToWorkspace engine tests

    @Test func moveColumnToWorkspaceAdjustsSourceActiveColumnIndex() async {
        let (controller, _, _, ws1, ws2) = makeTwoMonitorLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("No Niri engine")
            return
        }

        let t1 = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 7001)
        let t2 = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 7002)
        let t3 = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 7003)
        engine.syncWindows([t1, t2, t3], in: ws1, selectedNodeId: nil)
        _ = controller.workspaceManager.setManagedFocus(
            t1, in: ws1,
            onMonitor: controller.workspaceManager.monitors.first!.id
        )

        var sourceState = controller.workspaceManager.niriViewportState(for: ws1)
        var targetState = controller.workspaceManager.niriViewportState(for: ws2)
        sourceState.activeColumnIndex = 2

        guard let node2 = engine.findNode(for: t2),
              let column2 = engine.findColumn(containing: node2, in: ws1)
        else {
            Issue.record("Column not found")
            return
        }

        _ = engine.moveColumnToWorkspace(
            column2, from: ws1, to: ws2,
            sourceState: &sourceState, targetState: &targetState,
            resetColumnWidth: false
        )

        #expect(sourceState.activeColumnIndex == 1, "activeColumnIndex should shift after removal before active")
    }

    @Test func moveColumnToWorkspaceResetsWidthWhenRequested() async {
        let (controller, _, _, ws1, ws2) = makeTwoMonitorLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("No Niri engine")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 7010)
        engine.syncWindows([token], in: ws1, selectedNodeId: nil)

        guard let node = engine.findNode(for: token),
              let column = engine.findColumn(containing: node, in: ws1)
        else {
            Issue.record("Column not found")
            return
        }

        column.cachedWidth = 500
        let widthBefore = column.cachedWidth

        var sourceState = controller.workspaceManager.niriViewportState(for: ws1)
        var targetState = controller.workspaceManager.niriViewportState(for: ws2)

        _ = engine.moveColumnToWorkspace(
            column, from: ws1, to: ws2,
            sourceState: &sourceState, targetState: &targetState,
            resetColumnWidth: true
        )

        #expect(column.cachedWidth == 0, "cachedWidth should be reset to 0 when resetColumnWidth=true")
        #expect(column.isFullWidth == false, "isFullWidth should be reset")
        #expect(widthBefore != 0, "Width before should have been non-zero")
    }

    @Test func moveColumnToWorkspacePreservesWidthWhenNotRequested() async {
        let (controller, _, _, ws1, ws2) = makeTwoMonitorLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("No Niri engine")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 7020)
        engine.syncWindows([token], in: ws1, selectedNodeId: nil)

        guard let node = engine.findNode(for: token),
              let column = engine.findColumn(containing: node, in: ws1)
        else {
            Issue.record("Column not found")
            return
        }

        column.cachedWidth = 500
        column.isFullWidth = true

        var sourceState = controller.workspaceManager.niriViewportState(for: ws1)
        var targetState = controller.workspaceManager.niriViewportState(for: ws2)

        _ = engine.moveColumnToWorkspace(
            column, from: ws1, to: ws2,
            sourceState: &sourceState, targetState: &targetState,
            resetColumnWidth: false
        )

        #expect(column.cachedWidth == 500, "cachedWidth should be preserved when resetColumnWidth=false")
        #expect(column.isFullWidth == true, "isFullWidth should be preserved")
    }
}
