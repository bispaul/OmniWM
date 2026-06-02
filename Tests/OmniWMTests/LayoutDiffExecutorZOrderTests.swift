import Testing
import Foundation
@testable import OmniWM

@Suite @MainActor struct LayoutDiffExecutorZOrderTests {
    @Test func focusedWindowIsOrderedLastWithTwoTiledWindows() {
        var orderedWindowIds: [UInt32] = []
        let controller = makeLayoutPlanTestController(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in },
                orderWindow: { windowId in
                    orderedWindowIds.append(windowId)
                }
            )
        )

        let wsId = controller.workspaceManager.visibleWorkspaceIds().first!
        let monitor = controller.workspaceManager.monitors.first!

        let w1 = makeLayoutPlanTestWindow(windowId: 100)
        let w2 = makeLayoutPlanTestWindow(windowId: 200)
        let token1 = controller.workspaceManager.addWindow(w1, pid: getpid(), windowId: 100, to: wsId, mode: .tiling)
        let token2 = controller.workspaceManager.addWindow(w2, pid: getpid(), windowId: 200, to: wsId, mode: .tiling)

        let diff = WorkspaceLayoutDiff(
            frameChanges: [
                LayoutFrameChange(token: token1, frame: CGRect(x: 0, y: 0, width: 960, height: 1080), forceApply: false),
                LayoutFrameChange(token: token2, frame: CGRect(x: 960, y: 0, width: 960, height: 1080), forceApply: false),
            ],
            focusedFrame: LayoutFocusedFrame(token: token2, frame: CGRect(x: 960, y: 0, width: 960, height: 1080))
        )

        let plan = WorkspaceLayoutPlan(
            workspaceId: wsId,
            monitor: LayoutMonitorSnapshot(
                monitorId: monitor.id,
                displayId: monitor.displayId,
                frame: monitor.frame,
                visibleFrame: monitor.visibleFrame,
                workingFrame: monitor.visibleFrame,
                scale: 1.0,
                orientation: .horizontal
            ),
            sessionPatch: .init(workspaceId: wsId, viewportState: controller.workspaceManager.niriViewportState(for: wsId), rememberedFocusToken: nil),
            diff: diff
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(orderedWindowIds.last == 200)
        #expect(orderedWindowIds.first == 100)
        #expect(orderedWindowIds.count == 2)
    }

    @Test func threeWindowsOrderedByXWithFocusedLast() {
        var orderedWindowIds: [UInt32] = []
        let controller = makeLayoutPlanTestController(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in },
                orderWindow: { windowId in
                    orderedWindowIds.append(windowId)
                }
            )
        )

        let wsId = controller.workspaceManager.visibleWorkspaceIds().first!
        let monitor = controller.workspaceManager.monitors.first!

        let w1 = makeLayoutPlanTestWindow(windowId: 100)
        let w2 = makeLayoutPlanTestWindow(windowId: 200)
        let w3 = makeLayoutPlanTestWindow(windowId: 300)
        let token1 = controller.workspaceManager.addWindow(w1, pid: getpid(), windowId: 100, to: wsId, mode: .tiling)
        let token2 = controller.workspaceManager.addWindow(w2, pid: getpid(), windowId: 200, to: wsId, mode: .tiling)
        let token3 = controller.workspaceManager.addWindow(w3, pid: getpid(), windowId: 300, to: wsId, mode: .tiling)

        let diff = WorkspaceLayoutDiff(
            frameChanges: [
                LayoutFrameChange(token: token1, frame: CGRect(x: 0, y: 0, width: 640, height: 1080), forceApply: false),
                LayoutFrameChange(token: token2, frame: CGRect(x: 640, y: 0, width: 640, height: 1080), forceApply: false),
                LayoutFrameChange(token: token3, frame: CGRect(x: 1280, y: 0, width: 640, height: 1080), forceApply: false),
            ],
            focusedFrame: LayoutFocusedFrame(token: token2, frame: CGRect(x: 640, y: 0, width: 640, height: 1080))
        )

        let plan = WorkspaceLayoutPlan(
            workspaceId: wsId,
            monitor: LayoutMonitorSnapshot(
                monitorId: monitor.id,
                displayId: monitor.displayId,
                frame: monitor.frame,
                visibleFrame: monitor.visibleFrame,
                workingFrame: monitor.visibleFrame,
                scale: 1.0,
                orientation: .horizontal
            ),
            sessionPatch: .init(workspaceId: wsId, viewportState: controller.workspaceManager.niriViewportState(for: wsId), rememberedFocusToken: nil),
            diff: diff
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(orderedWindowIds == [100, 300, 200])
    }

    @Test func singleTiledWindowSkipsZOrdering() {
        var orderedWindowIds: [UInt32] = []
        let controller = makeLayoutPlanTestController(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in },
                orderWindow: { windowId in
                    orderedWindowIds.append(windowId)
                }
            )
        )

        let wsId = controller.workspaceManager.visibleWorkspaceIds().first!
        let monitor = controller.workspaceManager.monitors.first!

        let w1 = makeLayoutPlanTestWindow(windowId: 100)
        let token1 = controller.workspaceManager.addWindow(w1, pid: getpid(), windowId: 100, to: wsId, mode: .tiling)

        let diff = WorkspaceLayoutDiff(
            frameChanges: [
                LayoutFrameChange(token: token1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), forceApply: false),
            ],
            focusedFrame: LayoutFocusedFrame(token: token1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        )

        let plan = WorkspaceLayoutPlan(
            workspaceId: wsId,
            monitor: LayoutMonitorSnapshot(
                monitorId: monitor.id,
                displayId: monitor.displayId,
                frame: monitor.frame,
                visibleFrame: monitor.visibleFrame,
                workingFrame: monitor.visibleFrame,
                scale: 1.0,
                orientation: .horizontal
            ),
            sessionPatch: .init(workspaceId: wsId, viewportState: controller.workspaceManager.niriViewportState(for: wsId), rememberedFocusToken: nil),
            diff: diff
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(orderedWindowIds.isEmpty)
    }
}
