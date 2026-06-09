import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct RefreshQueueManagerTests {
    private func makeRefresh(
        kind: LayoutRefreshController.ScheduledRefreshKind,
        reason: RefreshReason = .axWindowCreated,
        workspaceIds: Set<WorkspaceDescriptor.ID> = []
    ) -> LayoutRefreshController.ScheduledRefresh {
        LayoutRefreshController.ScheduledRefresh(
            kind: kind,
            reason: reason,
            affectedWorkspaceIds: workspaceIds
        )
    }

    private func makeWindowRemovalPayload(
        workspaceId: WorkspaceDescriptor.ID = UUID()
    ) -> LayoutRefreshController.WindowRemovalPayload {
        LayoutRefreshController.WindowRemovalPayload(
            workspaceId: workspaceId,
            layoutType: .niri,
            removedNodeId: nil,
            niriOldFrames: [:],
            shouldRecoverFocus: false
        )
    }

    private func makeRefreshWithRemoval(
        workspaceId: WorkspaceDescriptor.ID = UUID()
    ) -> LayoutRefreshController.ScheduledRefresh {
        LayoutRefreshController.ScheduledRefresh(
            kind: .windowRemoval,
            reason: .windowDestroyed,
            windowRemovalPayload: makeWindowRemovalPayload(workspaceId: workspaceId)
        )
    }

    // MARK: - Basic Queue Operations

    @Test func emptyQueueEnqueueBecomesPending() {
        var completed: [(LayoutRefreshController.ScheduledRefresh, Bool)] = []
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, didComplete in
                completed.append((refresh, didComplete))
            }
        )

        let refresh = makeRefresh(kind: .relayout)
        manager.enqueue(refresh)

        #expect(completed.isEmpty)
    }

    @Test func cancelActiveTaskClearsActiveState() async {
        var executionStarted = false
        let manager = RefreshQueueManager(
            executor: { _ in
                executionStarted = true
                try? await Task.sleep(for: .milliseconds(100))
                return true
            },
            onComplete: { _, _ in }
        )

        manager.enqueue(makeRefresh(kind: .relayout))

        await Task.yield()
        #expect(executionStarted)

        manager.cancelActiveTask()
    }

    @Test func resetClearsAllState() async {
        var executionCount = 0
        let manager = RefreshQueueManager(
            executor: { _ in
                executionCount += 1
                try? await Task.sleep(for: .milliseconds(100))
                return true
            },
            onComplete: { _, _ in }
        )

        manager.enqueue(makeRefresh(kind: .relayout))
        manager.enqueue(makeRefresh(kind: .immediateRelayout))

        await Task.yield()

        manager.reset()

        try? await Task.sleep(for: .milliseconds(150))

        #expect(executionCount <= 1)
    }

    // MARK: - Merge Matrix: fullRescan

    @Test func fullRescanAbsorbsFullRescan() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .fullRescan, reason: .startup))
        manager.enqueue(makeRefresh(kind: .fullRescan, reason: .activeSpaceChanged))

        #expect(pending == nil)
    }

    @Test func fullRescanAbsorbsRelayout() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .fullRescan, reason: .startup))
        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged))

        #expect(pending == nil)
    }

    @Test func fullRescanAbsorbsImmediateRelayout() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .fullRescan, reason: .startup))
        manager.enqueue(makeRefresh(kind: .immediateRelayout, reason: .workspaceTransition))

        #expect(pending == nil)
    }

    @Test func fullRescanAbsorbsWindowRemoval() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .fullRescan, reason: .startup))
        manager.enqueue(makeRefreshWithRemoval())

        #expect(pending == nil)
    }

    @Test func fullRescanAbsorbsVisibilityRefresh() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .fullRescan, reason: .startup))
        manager.enqueue(makeRefresh(kind: .visibilityRefresh, reason: .appHidden))

        #expect(pending == nil)
    }

    // MARK: - Merge Matrix: visibilityRefresh

    @Test func visibilityRefreshMergesVisibilityRefresh() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .visibilityRefresh, reason: .appHidden))
        manager.enqueue(makeRefresh(kind: .visibilityRefresh, reason: .appUnhidden))

        #expect(pending == nil)
    }

    @Test func visibilityRefreshUpgradesToFullRescan() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .visibilityRefresh, reason: .appHidden))
        manager.enqueue(makeRefresh(kind: .fullRescan, reason: .startup))

        #expect(pending == nil)
    }

    @Test func visibilityRefreshUpgradesToWindowRemoval() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .visibilityRefresh, reason: .appHidden))
        manager.enqueue(makeRefreshWithRemoval())

        #expect(pending == nil)
    }

    @Test func visibilityRefreshUpgradesToImmediateRelayout() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .visibilityRefresh, reason: .appHidden))
        manager.enqueue(makeRefresh(kind: .immediateRelayout, reason: .workspaceTransition))

        #expect(pending == nil)
    }

    @Test func visibilityRefreshUpgradesToRelayout() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .visibilityRefresh, reason: .appHidden))
        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged))

        #expect(pending == nil)
    }

    // MARK: - Merge Matrix: windowRemoval

    @Test func windowRemovalMergesWindowRemovalPayloads() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        let ws1 = UUID()
        let ws2 = UUID()

        manager.enqueue(makeRefreshWithRemoval(workspaceId: ws1))
        manager.enqueue(makeRefreshWithRemoval(workspaceId: ws2))

        #expect(pending == nil)
    }

    @Test func windowRemovalAddsImmediateRelayoutAsFollowUp() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefreshWithRemoval())
        manager.enqueue(makeRefresh(kind: .immediateRelayout, reason: .workspaceTransition))

        #expect(pending == nil)
    }

    @Test func windowRemovalAddsRelayoutAsFollowUp() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefreshWithRemoval())
        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged))

        #expect(pending == nil)
    }

    @Test func windowRemovalUpgradesToFullRescan() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefreshWithRemoval())
        manager.enqueue(makeRefresh(kind: .fullRescan, reason: .startup))

        #expect(pending == nil)
    }

    @Test func windowRemovalAbsorbsVisibilityRefresh() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefreshWithRemoval())
        manager.enqueue(makeRefresh(kind: .visibilityRefresh, reason: .appHidden))

        #expect(pending == nil)
    }

    // MARK: - Merge Matrix: immediateRelayout

    @Test func immediateRelayoutMergesImmediateRelayout() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .immediateRelayout, reason: .workspaceTransition))
        manager.enqueue(makeRefresh(kind: .immediateRelayout, reason: .windowRuleReevaluation))

        #expect(pending == nil)
    }

    @Test func immediateRelayoutKeepsPriorityOverRelayout() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .immediateRelayout, reason: .workspaceTransition))
        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged))

        #expect(pending == nil)
    }

    @Test func immediateRelayoutUpgradesToFullRescan() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .immediateRelayout, reason: .workspaceTransition))
        manager.enqueue(makeRefresh(kind: .fullRescan, reason: .startup))

        #expect(pending == nil)
    }

    @Test func immediateRelayoutUpgradesToWindowRemoval() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .immediateRelayout, reason: .workspaceTransition))
        manager.enqueue(makeRefreshWithRemoval())

        #expect(pending == nil)
    }

    @Test func immediateRelayoutAbsorbsVisibilityRefresh() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .immediateRelayout, reason: .workspaceTransition))
        manager.enqueue(makeRefresh(kind: .visibilityRefresh, reason: .appHidden))

        #expect(pending == nil)
    }

    // MARK: - Merge Matrix: relayout

    @Test func relayoutMergesRelayout() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged))
        manager.enqueue(makeRefresh(kind: .relayout, reason: .windowRuleReevaluation))

        #expect(pending == nil)
    }

    @Test func relayoutUpgradesToImmediateRelayout() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged))
        manager.enqueue(makeRefresh(kind: .immediateRelayout, reason: .workspaceTransition))

        #expect(pending == nil)
    }

    @Test func relayoutUpgradesToFullRescan() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged))
        manager.enqueue(makeRefresh(kind: .fullRescan, reason: .startup))

        #expect(pending == nil)
    }

    @Test func relayoutUpgradesToWindowRemoval() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged))
        manager.enqueue(makeRefreshWithRemoval())

        #expect(pending == nil)
    }

    @Test func relayoutAbsorbsVisibilityRefresh() {
        var pending: LayoutRefreshController.ScheduledRefresh?
        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { refresh, _ in
                pending = refresh
            }
        )

        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged))
        manager.enqueue(makeRefresh(kind: .visibilityRefresh, reason: .appHidden))

        #expect(pending == nil)
    }

    // MARK: - Workspace ID Merging

    @Test func workspaceIdsMergeCorrectlyAcrossMerges() {
        var completed: [LayoutRefreshController.ScheduledRefresh] = []
        let manager = RefreshQueueManager(
            executor: { refresh in
                completed.append(refresh)
                return true
            },
            onComplete: { _, _ in }
        )

        let ws1 = UUID()
        let ws2 = UUID()
        let ws3 = UUID()

        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged, workspaceIds: [ws1]))
        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged, workspaceIds: [ws2]))
        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged, workspaceIds: [ws3]))

        #expect(completed.isEmpty)
    }

    @Test func emptyWorkspaceIdsStayEmpty() {
        var completed: [LayoutRefreshController.ScheduledRefresh] = []
        let manager = RefreshQueueManager(
            executor: { refresh in
                completed.append(refresh)
                return true
            },
            onComplete: { _, _ in }
        )

        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged, workspaceIds: []))
        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged, workspaceIds: []))

        #expect(completed.isEmpty)
    }

    @Test func oneEmptyOnePopulatedWorkspaceIdsBecomesEmpty() {
        var completed: [LayoutRefreshController.ScheduledRefresh] = []
        let manager = RefreshQueueManager(
            executor: { refresh in
                completed.append(refresh)
                return true
            },
            onComplete: { _, _ in }
        )

        let ws1 = UUID()

        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged, workspaceIds: [ws1]))
        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged, workspaceIds: []))

        #expect(completed.isEmpty)
    }

    // MARK: - Post-Layout Actions

    @Test func postLayoutActionsMergeAcrossRefreshes() {
        var executedActions: [String] = []

        let manager = RefreshQueueManager(
            executor: { _ in true },
            onComplete: { _, _ in }
        )

        var refresh1 = makeRefresh(kind: .relayout, reason: .gapsChanged)
        refresh1.postLayoutActions = [
            { executedActions.append("action1") }
        ]

        var refresh2 = makeRefresh(kind: .relayout, reason: .windowRuleReevaluation)
        refresh2.postLayoutActions = [
            { executedActions.append("action2") }
        ]

        manager.enqueue(refresh1)
        manager.enqueue(refresh2)
    }

    // MARK: - Visibility Reconciliation

    @Test func visibilityReconciliationMergesAcrossRefreshes() {
        var completed: [LayoutRefreshController.ScheduledRefresh] = []
        let manager = RefreshQueueManager(
            executor: { refresh in
                completed.append(refresh)
                return true
            },
            onComplete: { _, _ in }
        )

        var refresh1 = makeRefresh(kind: .relayout, reason: .gapsChanged)
        refresh1.needsVisibilityReconciliation = true
        refresh1.visibilityReason = .appHidden

        let refresh2 = makeRefresh(kind: .relayout, reason: .windowRuleReevaluation)

        manager.enqueue(refresh1)
        manager.enqueue(refresh2)

        #expect(completed.isEmpty)
    }

    @Test func visibilityRefreshSetsReconciliationFlag() {
        var completed: [LayoutRefreshController.ScheduledRefresh] = []
        let manager = RefreshQueueManager(
            executor: { refresh in
                completed.append(refresh)
                return true
            },
            onComplete: { _, _ in }
        )

        manager.enqueue(makeRefresh(kind: .relayout, reason: .gapsChanged))
        manager.enqueue(makeRefresh(kind: .visibilityRefresh, reason: .appHidden))

        #expect(completed.isEmpty)
    }
}
