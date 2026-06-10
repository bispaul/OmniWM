import Foundation
import os

enum WorkspaceAssignmentReason {
    case admission
    case transfer
}

@MainActor
final class WorkspaceAssignmentManager {
    private unowned let workspaceManager: WorkspaceManager

    private struct RecentRemovalKey: Hashable {
        let pid: pid_t
        let bundleId: String?
    }

    private struct RecentRemoval {
        let workspaceId: WorkspaceDescriptor.ID
        let removedAt: Date
    }

    private var recentlyRemovedWorkspaces: [RecentRemovalKey: RecentRemoval] = [:]
    private static let cacheExpiryInterval: TimeInterval = 2.0
    private static let cacheMaxSize = 64
    var clockForTests: (() -> Date)?

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    private func now() -> Date {
        clockForTests?() ?? Date()
    }

    // MARK: - Recently-Removed Cache

    func recordRemoval(token: WindowToken, workspaceId: WorkspaceDescriptor.ID, bundleId: String?) {
        let key = RecentRemovalKey(pid: token.pid, bundleId: bundleId)
        recentlyRemovedWorkspaces[key] = RecentRemoval(workspaceId: workspaceId, removedAt: now())
        if recentlyRemovedWorkspaces.count > Self.cacheMaxSize {
            sweepExpiredEntries()
        }
        WMLog.workspace.info(
            "recordRemoval: cached workspace for pid=\(token.pid, privacy: .public) bundleId=\(bundleId ?? "nil", privacy: .public)"
        )
    }

    private func cachedWorkspace(pid: pid_t, bundleId: String?) -> WorkspaceDescriptor.ID? {
        let key = RecentRemovalKey(pid: pid, bundleId: bundleId)
        guard let removal = recentlyRemovedWorkspaces[key],
              now().timeIntervalSince(removal.removedAt) < Self.cacheExpiryInterval
        else {
            recentlyRemovedWorkspaces.removeValue(forKey: key)
            return nil
        }
        return removal.workspaceId
    }

    private func sweepExpiredEntries() {
        let current = now()
        recentlyRemovedWorkspaces = recentlyRemovedWorkspaces.filter { _, removal in
            current.timeIntervalSince(removal.removedAt) < Self.cacheExpiryInterval
        }
    }

    // MARK: - Central Assignment Gate

    @discardableResult
    func assignWindowToWorkspace(
        _ ax: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        to targetWorkspace: WorkspaceDescriptor.ID,
        reason: WorkspaceAssignmentReason,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowToken {
        let token = WindowToken(pid: pid, windowId: windowId)

        // Dedup: skip if already tracked
        if workspaceManager.entry(for: token) != nil {
            WMLog.workspace.info(
                "assignWindowToWorkspace: skipping already-tracked windowId=\(windowId, privacy: .public)"
            )
            return token
        }

        // Cache lookup for recently-removed windows (admission only)
        let bundleId = managedReplacementMetadata?.bundleId
        let resolvedWorkspace: WorkspaceDescriptor.ID
        if reason == .admission,
           let cached = cachedWorkspace(pid: pid, bundleId: bundleId)
        {
            WMLog.workspace.info(
                "assignWindowToWorkspace: restored cached workspace for windowId=\(windowId, privacy: .public) pid=\(pid, privacy: .public)"
            )
            resolvedWorkspace = cached
        } else {
            resolvedWorkspace = targetWorkspace
        }

        return workspaceManager.addWindow(
            ax, pid: pid, windowId: windowId, to: resolvedWorkspace,
            mode: mode, ruleEffects: ruleEffects,
            managedReplacementMetadata: managedReplacementMetadata
        )
    }

    // MARK: - Direct Forwarding (preserved from Build 94)

    func setWorkspace(for token: WindowToken, to workspace: WorkspaceDescriptor.ID) {
        workspaceManager.setWorkspace(for: token, to: workspace)
    }

    // MARK: - Test Support

    func cachedWorkspaceForTests(pid: pid_t, bundleId: String?) -> WorkspaceDescriptor.ID? {
        cachedWorkspace(pid: pid, bundleId: bundleId)
    }
}
