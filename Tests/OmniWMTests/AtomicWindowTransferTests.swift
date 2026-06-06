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

    // MARK: - Task 2: atomicTransferWindow

    @Test func atomicTransferPreservesColumnWidth() async {
        let (controller, primaryMonitor, secondaryMonitor, ws1, ws2) =
            makeTwoMonitorLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("No Niri engine")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 3001)
        _ = controller.workspaceManager.setManagedFocus(token, in: ws1, onMonitor: primaryMonitor.id)

        // Sync window into engine
        engine.syncWindows([token], in: ws1, selectedNodeId: nil)

        // Run layout so column gets a computed width
        let plans = try? await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [ws1]
        )
        if let plans { controller.layoutRefreshController.executeLayoutPlans(plans) }
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        // Capture column width before transfer
        guard let windowNode = engine.findNode(for: token),
              let column = engine.findColumn(containing: windowNode, in: ws1)
        else {
            Issue.record("Window not in engine before transfer")
            return
        }
        let widthBefore = column.cachedWidth

        // Perform atomic transfer
        let result = controller.workspaceNavigationHandler.atomicTransferWindow(
            token,
            from: ws1,
            to: ws2
        )

        #expect(result)

        // Verify registry updated
        #expect(controller.workspaceManager.workspace(for: token) == ws2)

        // Verify column width preserved (moveColumnToWorkspace, not moveWindowToWorkspace)
        guard let movedNode = engine.findNode(for: token),
              let movedColumn = engine.findColumn(containing: movedNode, in: ws2)
        else {
            Issue.record("Window not in engine after transfer")
            return
        }
        #expect(movedColumn.cachedWidth == widthBefore)
    }

    @Test func atomicTransferFailsForFloatingWindow() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace")
            return
        }

        let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)!
        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 4001)

        // Set window to floating mode
        controller.workspaceManager.setWindowMode(.floating, for: token)

        let result = controller.workspaceNavigationHandler.atomicTransferWindow(
            token,
            from: ws1,
            to: ws2
        )

        #expect(!result)
        // Window should still be in ws1 (no registry change on failure)
        #expect(controller.workspaceManager.workspace(for: token) == ws1)
    }

    @Test func atomicTransferFailsForTabbedColumnWithMultipleWindows() async {
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

        let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)!

        // Add two windows
        let token1 = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 5001)
        let token2 = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 5002)

        // Sync into engine (creates 2 columns)
        engine.syncWindows([token1, token2], in: ws1, selectedNodeId: nil)

        // Consume token2 into token1's column to create a multi-window column
        if let node1 = engine.findNode(for: token1),
           let col1 = engine.findColumn(containing: node1, in: ws1),
           let node2 = engine.findNode(for: token2)
        {
            node2.detach()
            col1.appendChild(node2)
        }

        let result = controller.workspaceNavigationHandler.atomicTransferWindow(
            token1,
            from: ws1,
            to: ws2
        )

        // Should fail — column has multiple windows
        #expect(!result)
    }

    @Test func atomicTransferFailsForSameWorkspace() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 6001)

        let result = controller.workspaceNavigationHandler.atomicTransferWindow(
            token,
            from: ws1,
            to: ws1
        )

        #expect(!result)
    }
}
