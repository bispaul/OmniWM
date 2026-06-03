import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import Testing

@Suite struct FocusBorderControllerTests {
    @Test @MainActor func nonManagedTargetWithDeadWindowClearsBorder() {
        let defaults = UserDefaults(suiteName: "com.omniwm.border.test.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let borderController = controller.focusBorderController

        borderController.windowExistsProviderForTests = { _ in false }

        let token = WindowToken(pid: 99999, windowId: 99999)
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 99999)
        let target = KeyboardFocusTarget(
            token: token,
            axRef: axRef,
            workspaceId: nil,
            isManaged: false
        )

        _ = borderController.focusChanged(to: target)
        _ = borderController.refresh()

        #expect(borderController.currentTarget == nil)
    }

    @Test @MainActor func nonManagedTargetWithLiveWindowKeepsBorder() {
        let defaults = UserDefaults(suiteName: "com.omnwm.border.test.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let borderController = controller.focusBorderController

        borderController.windowExistsProviderForTests = { _ in true }

        let token = WindowToken(pid: 99998, windowId: 99998)
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 99998)
        let target = KeyboardFocusTarget(
            token: token,
            axRef: axRef,
            workspaceId: nil,
            isManaged: false
        )

        _ = borderController.focusChanged(to: target)

        #expect(borderController.currentTarget != nil)
        #expect(borderController.currentTarget?.token == token)
    }
}
