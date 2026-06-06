import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct DisplayEligibilityTests {

    @Test func windowIsOnFullscreenSpaceReturnsFalseForNormalWindow() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 9901)

        let result = SkyLight.shared.windowIsOnFullscreenSpace(windowId: token.windowId)
        #expect(!result)
    }
}
