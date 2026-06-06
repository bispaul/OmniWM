@testable import OmniWM
import Testing

@Suite @MainActor struct DirtyWorkspaceReflowTests {
    @Test func markWorkspaceDirtyAddsToSet() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.workspaceManager.monitors.first
            .flatMap({ controller.workspaceManager.activeWorkspaceOrFirst(on: $0.id)?.id })
        else {
            Issue.record("Missing workspace for dirty marking test")
            return
        }

        #expect(controller.layoutRefreshController.layoutState.dirtyWorkspaceIds.isEmpty)
        controller.layoutRefreshController.markWorkspaceDirty(workspaceId)
        #expect(controller.layoutRefreshController.layoutState.dirtyWorkspaceIds.contains(workspaceId))
    }

    @Test func markWorkspaceDirtyIsIdempotent() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.workspaceManager.monitors.first
            .flatMap({ controller.workspaceManager.activeWorkspaceOrFirst(on: $0.id)?.id })
        else {
            Issue.record("Missing workspace for idempotent dirty test")
            return
        }

        controller.layoutRefreshController.markWorkspaceDirty(workspaceId)
        controller.layoutRefreshController.markWorkspaceDirty(workspaceId)
        #expect(controller.layoutRefreshController.layoutState.dirtyWorkspaceIds.count == 1)
    }

    @Test func multipleDirtyMarksCoalesce() {
        let controller = makeLayoutPlanTestController()
        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Need 2 workspaces for coalescing test")
            return
        }

        controller.layoutRefreshController.markWorkspaceDirty(ws1)
        controller.layoutRefreshController.markWorkspaceDirty(ws2)
        #expect(controller.layoutRefreshController.layoutState.dirtyWorkspaceIds.contains(ws1))
        #expect(controller.layoutRefreshController.layoutState.dirtyWorkspaceIds.contains(ws2))
        #expect(controller.layoutRefreshController.layoutState.dirtyWorkspaceIds.count == 2)
    }

    @Test func drainClearsSetAndEnqueuesReflow() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.workspaceManager.monitors.first
            .flatMap({ controller.workspaceManager.activeWorkspaceOrFirst(on: $0.id)?.id })
        else {
            Issue.record("Missing workspace for drain test")
            return
        }

        controller.layoutRefreshController.markWorkspaceDirty(workspaceId)
        #expect(!controller.layoutRefreshController.layoutState.dirtyWorkspaceIds.isEmpty)

        controller.layoutRefreshController.drainDirtyWorkspacesForTests()

        #expect(controller.layoutRefreshController.layoutState.dirtyWorkspaceIds.isEmpty)
        #expect(
            controller.layoutRefreshController.debugCounters.requestedByReason[.dirtyWorkspaceReflow] == 1
        )
        #expect(
            controller.layoutRefreshController.debugCounters.lastAffectedWorkspaceIdsByReason[.dirtyWorkspaceReflow]?
                .contains(workspaceId) == true
        )
    }

    @Test func drainCoalescesMultipleWorkspaces() {
        let controller = makeLayoutPlanTestController()
        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Need 2 workspaces for drain coalescing test")
            return
        }

        controller.layoutRefreshController.markWorkspaceDirty(ws1)
        controller.layoutRefreshController.markWorkspaceDirty(ws2)

        controller.layoutRefreshController.drainDirtyWorkspacesForTests()

        #expect(controller.layoutRefreshController.layoutState.dirtyWorkspaceIds.isEmpty)
        #expect(
            controller.layoutRefreshController.debugCounters.requestedByReason[.dirtyWorkspaceReflow] == 1
        )
        let affected = controller.layoutRefreshController.debugCounters
            .lastAffectedWorkspaceIdsByReason[.dirtyWorkspaceReflow]
        #expect(affected?.contains(ws1) == true)
        #expect(affected?.contains(ws2) == true)
    }

    @Test func drainNoOpWhenSetEmpty() {
        let controller = makeLayoutPlanTestController()

        controller.layoutRefreshController.drainDirtyWorkspacesForTests()

        #expect(controller.layoutRefreshController.debugCounters.requestedByReason[.dirtyWorkspaceReflow] == nil)
    }

    @Test func resetStateClearsDirtySet() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.workspaceManager.monitors.first
            .flatMap({ controller.workspaceManager.activeWorkspaceOrFirst(on: $0.id)?.id })
        else {
            Issue.record("Missing workspace for reset test")
            return
        }

        controller.layoutRefreshController.markWorkspaceDirty(workspaceId)
        #expect(!controller.layoutRefreshController.layoutState.dirtyWorkspaceIds.isEmpty)

        controller.layoutRefreshController.resetState()
        #expect(controller.layoutRefreshController.layoutState.dirtyWorkspaceIds.isEmpty)
    }
}
