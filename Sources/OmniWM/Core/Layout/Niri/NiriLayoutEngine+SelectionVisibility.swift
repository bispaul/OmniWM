import AppKit

extension NiriLayoutEngine {
    func ensureSelectionVisibleAfterUserNavigation(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        previousActiveContainerPosition: CGFloat? = nil
    ) {
        ensureSelectionVisible(
            node: node,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            animate: true,
            orientation: orientation,
            animationConfig: animationConfig,
            fromContainerIndex: fromContainerIndex,
            previousActiveContainerPosition: previousActiveContainerPosition
        )
    }

    func ensureSelectionVisibleAfterLayoutChange(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal,
        fromContainerIndex: Int? = nil,
        previousActiveContainerPosition: CGFloat? = nil
    ) {
        ensureSelectionVisible(
            node: node,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            animate: false,
            orientation: orientation,
            fromContainerIndex: fromContainerIndex,
            previousActiveContainerPosition: previousActiveContainerPosition
        )
    }
}
