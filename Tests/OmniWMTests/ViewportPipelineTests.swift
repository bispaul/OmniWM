import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct ViewportPipelineTests {
    @Test func viewportPipelineRunsDuringLayoutCommandWithStructuralChange() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context for viewport pipeline test")
            return
        }

        let token1 = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 8001)
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 8002)
        _ = controller.workspaceManager.setManagedFocus(token1, in: workspaceId, onMonitor: monitor.id)

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let stateAfterLayout = controller.workspaceManager.niriViewportState(for: workspaceId)
        let columns = engine.columns(in: workspaceId)
        #expect(columns.count >= 2, "Should have at least 2 columns")
        #expect(stateAfterLayout.activeColumnIndex >= 0)
    }

    @Test func noOverspreadWhenColumnsExceedViewport() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context for no-overspread test")
            return
        }

        for i in 0 ..< 5 {
            _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 8010 + i)
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let columns = engine.columns(in: workspaceId)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gap = CGFloat(controller.workspaceManager.gaps)
        let totalWidth = columns.enumerated().reduce(CGFloat(0)) { sum, pair in
            sum + pair.element.cachedWidth + (pair.offset < columns.count - 1 ? gap : 0)
        }

        if totalWidth > workingFrame.width {
            let centerOffset = -(workingFrame.width - totalWidth) / 2
            let actualTarget = state.viewOffsetPixels.target()
            #expect(
                abs(actualTarget - Double(centerOffset)) > 1.0,
                "Should NOT center when columns overflow viewport"
            )
        }
    }

    @Test func pipelineSkippedWhenViewportRecalcNotNeeded() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let workspaceId = controller.workspaceManager.monitors.first
            .flatMap({ controller.workspaceManager.activeWorkspaceOrFirst(on: $0.id)?.id })
        else {
            Issue.record("Missing workspace for pipeline skip test")
            return
        }

        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 8020)

        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let stateBefore = controller.workspaceManager.niriViewportState(for: workspaceId)

        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged,
            affectedWorkspaceIds: [workspaceId]
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let stateAfter = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(
            abs(stateAfter.viewOffsetPixels.target() - stateBefore.viewOffsetPixels.target()) < 1.0,
            "Viewport should not change on axWindowChanged reflow without structural change"
        )
    }

    @Test func viewportClampPreventsGapAfterColumnRemoval() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context")
            return
        }

        let token1 = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9001)
        let token2 = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9002)
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9003)
        _ = controller.workspaceManager.setManagedFocus(token1, in: workspaceId, onMonitor: monitor.id)

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        // Remove middle window — simulates transfer
        engine.removeWindow(token: token2)
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.requiresViewportRecalc = true
        controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let postState = controller.workspaceManager.niriViewportState(for: workspaceId)
        let columns = engine.columns(in: workspaceId)
        let totalW = postState.totalSpan(containers: columns, gap: 2, sizeKeyPath: \.cachedWidth)
        let viewportSpan = monitor.frame.width

        if totalW > viewportSpan {
            let viewStart = postState.viewPosPixels(columns: columns, gap: 2)
            let viewEnd = viewStart + viewportSpan
            let contentEnd = totalW
            #expect(
                viewEnd <= contentEnd + 2,
                "Viewport should not extend past content bounds (gap=\(viewEnd - contentEnd)px)"
            )
        }
    }

    @Test func applyOverspreadIfNeededNoLongerExists() {
        let controller = makeLayoutPlanTestController()
        let mirror = Mirror(reflecting: controller.niriLayoutHandler as Any)
        let methodNames = mirror.children.compactMap { $0.label }
        #expect(!methodNames.contains("applyOverspreadIfNeeded"))
    }
}
