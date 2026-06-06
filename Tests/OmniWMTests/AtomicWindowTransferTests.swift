import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct AtomicWindowTransferTests {

    // MARK: - Task 1: Engine column index insertion

    @Test func moveColumnToWorkspaceAtIndex() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context")
            return
        }

        let ws2Id = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)!

        // Add 3 windows to ws2 (creates 3 columns: A, B, C)
        let tokenA = addLayoutPlanTestWindow(on: controller, workspaceId: ws2Id, windowId: 2001)
        let tokenB = addLayoutPlanTestWindow(on: controller, workspaceId: ws2Id, windowId: 2002)
        let tokenC = addLayoutPlanTestWindow(on: controller, workspaceId: ws2Id, windowId: 2003)

        // Sync ws2 windows into niri engine
        engine.syncWindows(
            [tokenA, tokenB, tokenC],
            in: ws2Id,
            selectedNodeId: nil
        )

        // Add 1 window to ws1
        let tokenToMove = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 1001)

        // Sync ws1 windows into niri engine
        engine.syncWindows(
            [tokenToMove],
            in: ws1,
            selectedNodeId: nil
        )

        guard let windowNode = engine.findNode(for: tokenToMove),
              let column = engine.findColumn(containing: windowNode, in: ws1)
        else {
            Issue.record("Window not in engine")
            return
        }

        var sourceState = controller.workspaceManager.niriViewportState(for: ws1)
        var targetState = controller.workspaceManager.niriViewportState(for: ws2Id)

        // Move column to ws2 at index 1 (between A and B)
        let result = engine.moveColumnToWorkspace(
            column,
            from: ws1,
            to: ws2Id,
            sourceState: &sourceState,
            targetState: &targetState,
            atColumnIndex: 1
        )

        #expect(result != nil)

        // Verify column order in ws2: A, moved, B, C
        let columns = engine.columns(in: ws2Id)
        #expect(columns.count == 4)
        #expect(columns[1].windowNodes.first?.token == tokenToMove)
    }

    @Test func moveColumnToWorkspaceAtIndexNilAppendsToEnd() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context")
            return
        }

        let ws2Id = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)!

        let tokenExisting = addLayoutPlanTestWindow(on: controller, workspaceId: ws2Id, windowId: 2001)

        // Sync ws2 windows into niri engine
        engine.syncWindows(
            [tokenExisting],
            in: ws2Id,
            selectedNodeId: nil
        )

        let tokenToMove = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 1001)

        // Sync ws1 windows into niri engine
        engine.syncWindows(
            [tokenToMove],
            in: ws1,
            selectedNodeId: nil
        )

        guard let windowNode = engine.findNode(for: tokenToMove),
              let column = engine.findColumn(containing: windowNode, in: ws1)
        else {
            Issue.record("Window not in engine")
            return
        }

        var sourceState = controller.workspaceManager.niriViewportState(for: ws1)
        var targetState = controller.workspaceManager.niriViewportState(for: ws2Id)

        // Move with nil index — should append
        let result = engine.moveColumnToWorkspace(
            column,
            from: ws1,
            to: ws2Id,
            sourceState: &sourceState,
            targetState: &targetState,
            atColumnIndex: nil
        )

        #expect(result != nil)
        let columns = engine.columns(in: ws2Id)
        #expect(columns.last?.windowNodes.first?.token == tokenToMove)
    }
}
