import Foundation

@MainActor
final class WindowLifecycleCoordinator {
    private weak var controller: WMController?
    private var pendingTask: Task<Void, Never>?
    private var pendingTargets: Set<WindowRuleReevaluationTarget> = []

    init(controller: WMController) {
        self.controller = controller
    }

    func scheduleReevaluation(
        targets: Set<WindowRuleReevaluationTarget>,
        trigger: ReevaluationTrigger
    ) {
        guard let controller,
              controller.windowRuleEngine.needsWindowReevaluation,
              !targets.isEmpty
        else { return }

        pendingTargets.formUnion(targets)
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(25))
            guard let self, let controller = self.controller else { return }
            let targets = self.pendingTargets
            self.pendingTargets.removeAll()
            _ = await controller.reevaluateWindowRules(for: targets)
        }
    }

    func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingTargets.removeAll()
    }
}
