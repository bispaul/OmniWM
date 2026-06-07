import CoreGraphics
import Foundation
@testable import OmniWM
import Testing

private func makeWakeTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.wakeRestore.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeWakeTestMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat = 0,
    y: CGFloat = 0,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

@Suite struct WakeRestoreTests {
    @Test @MainActor func wakePhaseDefaultsToIdle() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        guard case .idle = slm.wakePhase else {
            Issue.record("Expected .idle, got \(slm.wakePhase)")
            return
        }
    }

    @Test @MainActor func rollingSnapshotCapturedOnFirstDisconnect() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "6", monitorAssignment: .specificDisplay(OutputId(displayId: 2, name: "S27R65x")))
        ]
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        let external = makeWakeTestMonitor(displayId: 2, name: "S27R65x", x: 1920)
        controller.workspaceManager.applyMonitorConfigurationChange([retina, external])

        #expect(slm.sleepSnapshot == nil)

        slm.handleDisplayEventForTests(.disconnected(external.id, OutputId(from: external)))

        #expect(slm.sleepSnapshot != nil)
        #expect(slm.sleepSnapshot?.outputIds.count == 2)
    }

    @Test @MainActor func rollingSnapshotNotOverwrittenBySecondDisconnect() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        let ext1 = makeWakeTestMonitor(displayId: 2, name: "S27R65x", x: 1920)
        let ext2 = makeWakeTestMonitor(displayId: 3, name: "U32J59x", x: 0, y: -1080, width: 2560, height: 1440)
        controller.workspaceManager.applyMonitorConfigurationChange([retina, ext1, ext2])

        slm.handleDisplayEventForTests(.disconnected(ext1.id, OutputId(from: ext1)))
        let firstSnapshot = slm.sleepSnapshot
        #expect(firstSnapshot?.outputIds.count == 3)

        slm.handleDisplayEventForTests(.disconnected(ext2.id, OutputId(from: ext2)))
        #expect(slm.sleepSnapshot?.outputIds.count == 3)
    }

    @Test @MainActor func snapshotCapturesWindowRecords() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        controller.workspaceManager.applyMonitorConfigurationChange([retina])

        let snapshot = slm.captureStateSnapshot()
        #expect(snapshot != nil)
        #expect(snapshot?.expectedMonitorCount == 1)
    }

    @Test @MainActor func rescansNotBlockedDuringWake() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        controller.workspaceManager.applyMonitorConfigurationChange([retina])

        let snapshot = slm.captureStateSnapshot()!
        slm.setSleepSnapshotForTests(snapshot)
        slm.setWakePhaseForTests(.awaitingRestore(snapshot))

        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)

        #expect(controller.layoutRefreshController.debugCounters.requestedByReason[.activeSpaceChanged] == 1)
    }

    @Test @MainActor func reEntrantSleepDuringAwaitingResetsCleanly() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        controller.workspaceManager.applyMonitorConfigurationChange([retina])

        let snapshot = slm.captureStateSnapshot()!
        slm.setSleepSnapshotForTests(snapshot)
        slm.setWakePhaseForTests(.awaitingRestore(snapshot))

        slm.simulateSleepForTests()

        #expect(slm.sleepSnapshot != nil)
    }

    @Test @MainActor func outputIdNameFallbackMatchesWhenDisplayIdChanges() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "8", monitorAssignment: .specificDisplay(OutputId(displayId: 3, name: "U32J59x")))
        ]
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        let ext32 = makeWakeTestMonitor(displayId: 3, name: "U32J59x", x: 0, y: -1440, width: 2560, height: 1440)
        controller.workspaceManager.applyMonitorConfigurationChange([retina, ext32])

        let snapshot = slm.captureStateSnapshot()!
        #expect(snapshot.outputIds.contains(where: { $0.name == "U32J59x" }))

        let outputId = snapshot.outputIds.first { $0.name == "U32J59x" }!
        let ext32Renamed = makeWakeTestMonitor(displayId: 99, name: "U32J59x", x: 0, y: -1440, width: 2560, height: 1440)
        let resolved = outputId.resolveMonitor(in: [retina, ext32Renamed])
        #expect(resolved != nil)
        #expect(resolved?.displayId == 99)
    }

    @Test @MainActor func wakeRestoreRefreshReasonHasCorrectRoutes() {
        #expect(RefreshReason.wakeRescan.requestRoute == .fullRescan)
        #expect(RefreshReason.wakeRestore.requestRoute == .immediateRelayout)
        #expect(RefreshReason.wakeRescan.relayoutSchedulingPolicy == .plain)
        #expect(RefreshReason.wakeRestore.relayoutSchedulingPolicy == .plain)
    }
}
