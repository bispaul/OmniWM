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

    @Test func nonPolicyPassCentersColumnsWhenTheyFit() async {
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

        // Add 1 window (should fit in viewport — applyOverspread should center)
        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 6001)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)

        // Run initial layout with policies
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        // Manually set viewport offset to a bad position (simulating stale state)
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.viewOffsetPixels = .static(500)
        controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)

        // Run a NON-policy layout pass (no recalc flag — applyPolicies=false)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        // Check: viewport should be corrected by applyOverspread (centers the single column)
        let postState = controller.workspaceManager.niriViewportState(for: workspaceId)
        let columns = engine.columns(in: workspaceId)
        if columns.count == 1 {
            let offset = postState.stationary()
            let columnWidth = columns[0].cachedWidth
            let viewportWidth = monitor.frame.width
            let expectedCenterOffset = -((viewportWidth - columnWidth) / 2)
            #expect(
                abs(offset - expectedCenterOffset) < 2,
                "Non-policy pass should center column via applyOverspread (offset=\(offset) expected=\(expectedCenterOffset))"
            )
            #expect(offset != 500, "Stale offset 500 should have been corrected")
        }
    }

    @Test func clampViewportOffsetDoesNotOverrideNavigationWithinGapTolerance() async {
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

        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9501)
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9502)
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9503)

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let columns = engine.columns(in: workspaceId)
        #expect(columns.count == 3, "Need 3 columns to overflow viewport")

        let gap = CGFloat(controller.workspaceManager.gaps)
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let totalW = state.totalSpan(containers: columns, gap: gap, sizeKeyPath: \.cachedWidth)
        let minOffsetStrict = monitor.frame.width - totalW

        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(minOffsetStrict - 6)

        let clamped = state.clampViewportOffset(
            containers: columns,
            gap: gap,
            viewportSpan: monitor.frame.width,
            sizeKeyPath: \.cachedWidth
        )
        #expect(
            !clamped,
            "Offset 6px past strict min should NOT be clamped (within gap tolerance of \(Int(gap))px)"
        )
    }

    @Test func focusNeighborWritesSpringBeforeRelayout() async {
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

        let token1 = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 7001)
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 7002)
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 7003)
        _ = controller.workspaceManager.setManagedFocus(token1, in: workspaceId, onMonitor: monitor.id)

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let columns = engine.columns(in: workspaceId)
        #expect(columns.count == 3, "Need 3 columns to overflow viewport")

        let stateBefore = controller.workspaceManager.niriViewportState(for: workspaceId)

        controller.niriLayoutHandler.focusNeighbor(direction: .right)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let stateAfter = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(
            stateAfter.activeColumnIndex != stateBefore.activeColumnIndex,
            "focusNeighbor should change active column"
        )
        #expect(
            abs(stateAfter.viewOffsetPixels.target() - stateBefore.viewOffsetPixels.target()) > 1,
            "Viewport should shift to show the newly focused column"
        )
    }

    @Test func focusNeighborLeavesViewportAnimatingToPreventESVOverwrite() async {
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

        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9701)
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9702)
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9703)

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(engine.columns(in: workspaceId).count == 3)

        controller.niriLayoutHandler.focusNeighbor(direction: .right)

        let stateImmediately = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(
            stateImmediately.viewOffsetPixels.isAnimating,
            "Viewport must be animating after focusNeighbor to prevent resolveSelection ESV from recomputing offset"
        )
    }

    @Test func viewportOffsetStableAfterWorkspaceSwitchRelayout() async {
        let controller = makeLayoutPlanTestController(
            monitors: [makeLayoutPlanTestMonitor(width: 2560, height: 1440)],
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main)
            ]
        )
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1Id = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context")
            return
        }

        _ = addLayoutPlanTestWindow(on: controller, workspaceId: ws1Id, windowId: 9901)
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: ws1Id, windowId: 9902)
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: ws1Id, windowId: 9903)

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        #expect(engine.columns(in: ws1Id).count == 3)

        controller.niriLayoutHandler.focusNeighbor(direction: .right)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let navState = controller.workspaceManager.niriViewportState(for: ws1Id)
        let navOffset = navState.viewOffsetPixels.target()
        let navActiveCol = navState.activeColumnIndex
        #expect(navActiveCol > 0, "Navigation should advance activeColumnIndex")

        // Simulate settled spring → static (what happens after DisplayLink ticks)
        var settledState = controller.workspaceManager.niriViewportState(for: ws1Id)
        settledState.viewOffsetPixels = .static(navOffset)
        controller.workspaceManager.updateNiriViewportState(settledState, for: ws1Id)

        // Workspace switch round-trip
        controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.workspaceNavigationHandler.switchWorkspace(index: 0)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        // Extra relayout to trigger resolveSelection ESV
        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let postState = controller.workspaceManager.niriViewportState(for: ws1Id)
        let postOffset = postState.viewOffsetPixels.target()

        #expect(
            postState.activeColumnIndex == navActiveCol,
            "activeColumnIndex must survive workspace switch (nav=\(navActiveCol) post=\(postState.activeColumnIndex))"
        )
        #expect(
            abs(postOffset - navOffset) < 2,
            "Viewport offset must not drift after workspace switch (nav=\(navOffset) post=\(postOffset) diff=\(abs(postOffset - navOffset)))"
        )
    }

    @Test func activeColumnVisibleAfterLeftColumnRemoval() async {
        let controller = makeLayoutPlanTestController(
            monitors: [makeLayoutPlanTestMonitor(width: 2560, height: 1440)]
        )
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

        let token1 = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9801)
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9802)
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9803)

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        controller.niriLayoutHandler.focusNeighbor(direction: .right)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let preRemoval = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(preRemoval.activeColumnIndex == 1, "Should be on column 1 before removal")

        engine.removeWindow(token: token1)
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.requiresViewportRecalc = true
        controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let postRemoval = controller.workspaceManager.niriViewportState(for: workspaceId)
        let columns = engine.columns(in: workspaceId)
        let gap = CGFloat(controller.workspaceManager.gaps)
        let activeCol = postRemoval.activeColumnIndex
        #expect(activeCol < columns.count, "activeColumnIndex must be valid")

        let viewStart = postRemoval.containerPosition(
            at: activeCol, containers: columns, gap: gap, sizeKeyPath: \.cachedWidth
        ) + postRemoval.stationary()
        let viewEnd = viewStart + monitor.frame.width
        let colStart = postRemoval.containerPosition(
            at: activeCol, containers: columns, gap: gap, sizeKeyPath: \.cachedWidth
        )
        let colEnd = colStart + columns[activeCol].cachedWidth

        #expect(
            colStart >= viewStart - gap && colEnd <= viewEnd + gap,
            "Active column must be visible after left-column removal (colStart=\(colStart) colEnd=\(colEnd) viewStart=\(viewStart) viewEnd=\(viewEnd))"
        )
    }
}
