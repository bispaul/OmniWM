import Foundation

@MainActor final class RefreshQueueManager {
    typealias Executor = (LayoutRefreshController.ScheduledRefresh) async -> Bool
    typealias CompletionHandler = (LayoutRefreshController.ScheduledRefresh, Bool) -> Void

    private(set) var activeRefreshTask: Task<Void, Never>?
    private(set) var activeRefresh: LayoutRefreshController.ScheduledRefresh?
    private(set) var pendingRefresh: LayoutRefreshController.ScheduledRefresh?

    private let executor: Executor
    private let onComplete: CompletionHandler

    init(executor: @escaping Executor, onComplete: @escaping CompletionHandler) {
        self.executor = executor
        self.onComplete = onComplete
    }

    func enqueue(_ refresh: LayoutRefreshController.ScheduledRefresh) {
        if let activeRefresh {
            handleRefresh(refresh, whileActive: activeRefresh)
            return
        }

        mergePendingRefresh(refresh)
        startNextRefreshIfNeeded()
    }

    func cancelActiveTask() {
        activeRefreshTask?.cancel()
    }

    func clearActiveState() {
        activeRefreshTask = nil
        activeRefresh = nil
    }

    func reset() {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        activeRefresh = nil
        pendingRefresh = nil
    }

    private func handleRefresh(
        _ refresh: LayoutRefreshController.ScheduledRefresh,
        whileActive activeRefresh: LayoutRefreshController.ScheduledRefresh
    ) {
        switch (activeRefresh.kind, refresh.kind) {
        case (.fullRescan, .fullRescan):
            mergePendingRefresh(refresh)
        case (.fullRescan, .visibilityRefresh):
            absorbIntoActiveFullRescan(refresh)
        case (.fullRescan, .windowRemoval),
             (.fullRescan, .immediateRelayout),
             (.fullRescan, .relayout):
            mergePendingRefresh(refresh)
        case (.visibilityRefresh, .visibilityRefresh):
            mergePendingRefresh(refresh)
        case (.visibilityRefresh, .fullRescan),
             (.visibilityRefresh, .windowRemoval),
             (.visibilityRefresh, .immediateRelayout),
             (.visibilityRefresh, .relayout):
            mergePendingRefresh(refresh)
            cancelActiveTask()
        case (.windowRemoval, .fullRescan):
            mergePendingRefresh(refresh)
        case (.windowRemoval, _):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .fullRescan):
            mergePendingRefresh(refresh)
            cancelActiveTask()
        case (.immediateRelayout, .immediateRelayout):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .relayout):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .visibilityRefresh):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .windowRemoval):
            mergePendingRefresh(refresh)
            cancelActiveTask()
        case (.relayout, .fullRescan),
             (.relayout, .immediateRelayout),
             (.relayout, .relayout),
             (.relayout, .windowRemoval):
            mergePendingRefresh(refresh)
            cancelActiveTask()
        case (.relayout, .visibilityRefresh):
            mergePendingRefresh(refresh)
        }
    }

    private func absorbIntoActiveFullRescan(_ refresh: LayoutRefreshController.ScheduledRefresh) {
        guard var activeRefresh else { return }
        activeRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        mergeAbsorbedVisibility(into: &activeRefresh, from: refresh)
        self.activeRefresh = activeRefresh
    }

    private func mergePendingRefresh(_ refresh: LayoutRefreshController.ScheduledRefresh) {
        guard var pendingRefresh else {
            self.pendingRefresh = refresh
            return
        }

        let existingAffectedWorkspaceIds = pendingRefresh.affectedWorkspaceIds

        switch (pendingRefresh.kind, refresh.kind) {
        case (.fullRescan, .fullRescan):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.fullRescan, _):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.visibilityRefresh, .fullRescan),
             (.visibilityRefresh, .windowRemoval),
             (.visibilityRefresh, .immediateRelayout),
             (.visibilityRefresh, .relayout):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.visibilityRefresh, .visibilityRefresh):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        case (.windowRemoval, .fullRescan),
             (.immediateRelayout, .fullRescan),
             (.relayout, .fullRescan):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.windowRemoval, .windowRemoval):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.windowRemovalPayloads = mergeWindowRemovalPayloads(
                pendingRefresh.windowRemovalPayloads,
                with: refresh.windowRemovalPayloads
            )
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.windowRemoval, .immediateRelayout):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeFollowUp(
                into: &pendingRefresh,
                kind: .immediateRelayout,
                reason: refresh.reason,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.windowRemoval, .relayout):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeFollowUp(
                into: &pendingRefresh,
                kind: .relayout,
                reason: refresh.reason,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.windowRemoval, .visibilityRefresh):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.immediateRelayout, .windowRemoval):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            upgradedRefresh.followUpRefresh = pendingRefresh.followUpRefresh
            mergeFollowUp(
                into: &upgradedRefresh,
                kind: .immediateRelayout,
                reason: pendingRefresh.reason,
                affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.relayout, .windowRemoval):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            mergeFollowUp(
                into: &upgradedRefresh,
                kind: .relayout,
                reason: pendingRefresh.reason,
                affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.immediateRelayout, .visibilityRefresh),
             (.relayout, .visibilityRefresh):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.immediateRelayout, .immediateRelayout),
             (.relayout, .relayout):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            pendingRefresh.followUpRefresh = mergeFollowUpRefresh(
                pendingRefresh.followUpRefresh,
                with: refresh.followUpRefresh
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.immediateRelayout, .relayout):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeFollowUp(
                into: &pendingRefresh,
                kind: .relayout,
                reason: refresh.reason,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.relayout, .immediateRelayout):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            upgradedRefresh.followUpRefresh = mergeFollowUpRefresh(
                pendingRefresh.followUpRefresh,
                with: refresh.followUpRefresh
            )
            mergeFollowUp(
                into: &upgradedRefresh,
                kind: .relayout,
                reason: pendingRefresh.reason,
                affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        }

        pendingRefresh.affectedWorkspaceIds = mergedAffectedWorkspaceIds(
            pendingRefresh.affectedWorkspaceIds,
            existingAffectedWorkspaceIds
        )
        pendingRefresh.affectedWorkspaceIds = mergedAffectedWorkspaceIds(
            pendingRefresh.affectedWorkspaceIds,
            refresh.affectedWorkspaceIds
        )

        self.pendingRefresh = pendingRefresh
    }

    func startNextRefreshIfNeeded() {
        guard activeRefreshTask == nil, let refresh = pendingRefresh else { return }

        pendingRefresh = nil
        activeRefresh = refresh
        activeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didComplete = await self.executor(refresh)
            self.onComplete(refresh, didComplete)
        }
    }

    func preserveCancelledRefreshState(_ refresh: LayoutRefreshController.ScheduledRefresh) {
        guard var pendingRefresh else {
            self.pendingRefresh = refresh
            return
        }

        if !refresh.postLayoutActions.isEmpty {
            pendingRefresh.postLayoutActions.insert(contentsOf: refresh.postLayoutActions, at: 0)
        }

        pendingRefresh.affectedWorkspaceIds = mergedAffectedWorkspaceIds(
            pendingRefresh.affectedWorkspaceIds,
            refresh.affectedWorkspaceIds
        )

        if refresh.kind == .windowRemoval, !refresh.windowRemovalPayloads.isEmpty {
            pendingRefresh.windowRemovalPayloads = mergeWindowRemovalPayloads(
                refresh.windowRemovalPayloads,
                with: pendingRefresh.windowRemovalPayloads
            )
            if pendingRefresh.kind != .fullRescan, pendingRefresh.kind != .windowRemoval {
                pendingRefresh.kind = .windowRemoval
                pendingRefresh.reason = refresh.reason
            }
        }

        mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        pendingRefresh.followUpRefresh = mergeFollowUpRefresh(
            refresh.followUpRefresh,
            with: pendingRefresh.followUpRefresh
        )

        self.pendingRefresh = pendingRefresh
    }

    private func mergeWindowRemovalPayloads(
        _ existingPayloads: [LayoutRefreshController.WindowRemovalPayload],
        with incomingPayloads: [LayoutRefreshController.WindowRemovalPayload]
    ) -> [LayoutRefreshController.WindowRemovalPayload] {
        existingPayloads + incomingPayloads
    }

    private func mergedAffectedWorkspaceIds(
        _ existing: Set<WorkspaceDescriptor.ID>,
        _ incoming: Set<WorkspaceDescriptor.ID>
    ) -> Set<WorkspaceDescriptor.ID> {
        guard !existing.isEmpty, !incoming.isEmpty else { return [] }
        return existing.union(incoming)
    }

    private func mergeFollowUp(
        into refresh: inout LayoutRefreshController.ScheduledRefresh,
        kind: LayoutRefreshController.ScheduledRefreshKind,
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    ) {
        refresh.followUpRefresh = mergeFollowUpRefresh(
            refresh.followUpRefresh,
            with: .init(kind: kind, reason: reason, affectedWorkspaceIds: affectedWorkspaceIds)
        )
    }

    private func mergeAbsorbedVisibility(
        into refresh: inout LayoutRefreshController.ScheduledRefresh,
        from incoming: LayoutRefreshController.ScheduledRefresh
    ) {
        switch incoming.kind {
        case .visibilityRefresh:
            refresh.needsVisibilityReconciliation = true
            refresh.visibilityReason = incoming.reason
        case .fullRescan,
             .windowRemoval,
             .immediateRelayout,
             .relayout:
            guard incoming.needsVisibilityReconciliation else { return }
            refresh.needsVisibilityReconciliation = true
            refresh.visibilityReason = incoming.visibilityReason ?? refresh.visibilityReason
        }
    }

    private func mergeFollowUpRefresh(
        _ existing: LayoutRefreshController.FollowUpRefresh?,
        with incoming: LayoutRefreshController.FollowUpRefresh?
    ) -> LayoutRefreshController.FollowUpRefresh? {
        switch (existing, incoming) {
        case (nil, nil):
            return nil
        case let (value?, nil),
             let (nil, value?):
            return value
        case let (existing?, incoming?):
            var merged = incoming
            merged.affectedWorkspaceIds = mergedAffectedWorkspaceIds(
                existing.affectedWorkspaceIds,
                incoming.affectedWorkspaceIds
            )
            if existing.kind == .immediateRelayout || incoming.kind == .immediateRelayout {
                if incoming.kind == .immediateRelayout {
                    return merged
                }
                var kept = existing
                kept.affectedWorkspaceIds = mergedAffectedWorkspaceIds(
                    existing.affectedWorkspaceIds,
                    incoming.affectedWorkspaceIds
                )
                return kept
            }
            return merged
        }
    }
}
