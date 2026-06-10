import Foundation

@MainActor
final class WorkspaceAssignmentManager {
    private unowned let workspaceManager: WorkspaceManager

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    @discardableResult
    func addWindow(
        _ ax: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        to workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowToken {
        workspaceManager.addWindow(
            ax, pid: pid, windowId: windowId, to: workspace,
            mode: mode, ruleEffects: ruleEffects,
            managedReplacementMetadata: managedReplacementMetadata
        )
    }

    func setWorkspace(for token: WindowToken, to workspace: WorkspaceDescriptor.ID) {
        workspaceManager.setWorkspace(for: token, to: workspace)
    }
}
