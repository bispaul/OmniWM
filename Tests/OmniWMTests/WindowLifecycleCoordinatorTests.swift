import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct WindowLifecycleCoordinatorTests {
    @Test func scheduleBatchesMultipleTargets() async throws {
        let controller = makeLayoutPlanTestController()
        let coordinator = WindowLifecycleCoordinator(controller: controller)

        let token1 = WindowToken(pid: 1, windowId: 100)
        let token2 = WindowToken(pid: 2, windowId: 200)

        coordinator.scheduleReevaluation(targets: [.window(token1)], trigger: .titleChange)
        coordinator.scheduleReevaluation(targets: [.window(token2)], trigger: .titleChange)

        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func cancelPreventsReevaluation() async throws {
        let controller = makeLayoutPlanTestController()
        let coordinator = WindowLifecycleCoordinator(controller: controller)

        let token = WindowToken(pid: 1, windowId: 100)
        coordinator.scheduleReevaluation(targets: [.window(token)], trigger: .creation)
        coordinator.cancelPending()

        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func emptyTargetsSkipsScheduling() {
        let controller = makeLayoutPlanTestController()
        let coordinator = WindowLifecycleCoordinator(controller: controller)

        coordinator.scheduleReevaluation(targets: [], trigger: .creation)
    }
}
