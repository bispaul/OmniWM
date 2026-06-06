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

    @Test @MainActor func wakeGateDefersRescanDuringDeferredPhase() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        slm.setWakePhaseForTests(.deferredAwaitingDisplay)

        slm.gatedRequestFullRescan(reason: .activeSpaceChanged)

        #expect(controller.layoutRefreshController.debugCounters.requestedByReason[.activeSpaceChanged] == nil)
    }

    @Test @MainActor func wakeGateForwardsRescanWhenIdle() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        slm.gatedRequestFullRescan(reason: .activeSpaceChanged)

        #expect(controller.layoutRefreshController.debugCounters.requestedByReason[.activeSpaceChanged] == 1)
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

    @Test @MainActor func wakeDisplayEventTransitionsToRestoredState() {
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

        // Capture snapshot with 2 monitors
        let snapshot = slm.captureStateSnapshot()!
        slm.setSleepSnapshotForTests(snapshot)

        // Simulate wake
        slm.setWakePhaseForTests(.deferredAwaitingDisplay)

        // Simulate first display reconnect
        slm.handleDisplayEventForTests(.connected(ext32))

        // Phase should have advanced: either still restoring (waiting for retina) or drained
        switch slm.wakePhase {
        case .restoring(let ctx):
            #expect(ctx.restoredOutputIds.contains(where: { $0.name == "U32J59x" }))
        case .idle:
            // All monitors restored + drained
            break
        default:
            Issue.record("Unexpected phase: \(slm.wakePhase)")
        }
    }

    @Test @MainActor func drainClearsSnapshotAndResetsPhase() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
        ]
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        controller.workspaceManager.applyMonitorConfigurationChange([retina])

        // Capture and set snapshot
        let snapshot = slm.captureStateSnapshot()!
        slm.setSleepSnapshotForTests(snapshot)

        // Simulate wake with deferred phase, then connect the only monitor
        slm.setWakePhaseForTests(.deferredAwaitingDisplay)
        slm.handleDisplayEventForTests(.connected(retina))

        // After the only monitor reconnects, all outputs are restored so drain should fire
        guard case .idle = slm.wakePhase else {
            Issue.record("Expected .idle after drain, got \(slm.wakePhase)")
            return
        }
        #expect(slm.sleepSnapshot == nil)
    }

    @Test @MainActor func drainFlushesDeferredRescanReasons() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
        ]
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        controller.workspaceManager.applyMonitorConfigurationChange([retina])

        let snapshot = slm.captureStateSnapshot()!
        slm.setSleepSnapshotForTests(snapshot)

        // Enter restoring phase with a deferred rescan reason
        slm.setWakePhaseForTests(.deferredAwaitingDisplay)

        // Gate a rescan to accumulate a deferred reason — but first we need restoring phase
        // Trigger display connect to transition to restoring, which will immediately drain
        // (single monitor). Instead, manually set up restoring context with a deferred reason.
        let deadline = Date().addingTimeInterval(15)
        let context = ServiceLifecycleManager.WakeRestorationContext(
            snapshot: snapshot,
            restoredOutputIds: [],
            deferredRescanReasons: [.activeSpaceChanged],
            userModifiedWorkspaceIds: [],
            deadline: deadline
        )
        slm.setWakePhaseForTests(.restoring(context))

        // Now simulate the monitor connect — it will restore + drain
        slm.handleDisplayEventForTests(.connected(retina))

        guard case .idle = slm.wakePhase else {
            Issue.record("Expected .idle after drain, got \(slm.wakePhase)")
            return
        }

        // Deferred reasons should have been flushed as immediateRelayout
        #expect(controller.layoutRefreshController.debugCounters.requestedByReason[.workspaceTransition] != nil)
    }
}
