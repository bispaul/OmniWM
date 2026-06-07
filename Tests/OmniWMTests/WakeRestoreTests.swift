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

    @Test @MainActor func wakeDisplayEventStaysInRestoringPhase() {
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
        slm.setSleepSnapshotForTests(snapshot)
        slm.setWakePhaseForTests(.deferredAwaitingDisplay)

        slm.handleDisplayEventForTests(.connected(ext32))

        // Settle-then-correct: stays in restoring until 3s settle timer fires
        guard case .restoring = slm.wakePhase else {
            Issue.record("Expected .restoring (settling), got \(slm.wakePhase)")
            return
        }
        // Snapshot preserved until correction runs
        #expect(slm.sleepSnapshot != nil)
    }

    @Test @MainActor func settlePhaseKeepsSnapshotUntilCorrection() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        controller.workspaceManager.applyMonitorConfigurationChange([retina])

        let snapshot = slm.captureStateSnapshot()!
        slm.setSleepSnapshotForTests(snapshot)
        slm.setWakePhaseForTests(.deferredAwaitingDisplay)

        // Connect triggers settle, not immediate correction
        slm.handleDisplayEventForTests(.connected(retina))

        guard case .restoring = slm.wakePhase else {
            Issue.record("Expected .restoring (settling), got \(slm.wakePhase)")
            return
        }
        #expect(slm.sleepSnapshot != nil)
    }

    @Test @MainActor func wakeGateStillActiveInSettlePhase() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        controller.workspaceManager.applyMonitorConfigurationChange([retina])

        let snapshot = slm.captureStateSnapshot()!
        slm.setSleepSnapshotForTests(snapshot)
        slm.setWakePhaseForTests(.deferredAwaitingDisplay)
        slm.handleDisplayEventForTests(.connected(retina))

        // Gate should still be active in settling phase
        slm.gatedRequestFullRescan(reason: .activeSpaceChanged)
        #expect(controller.layoutRefreshController.debugCounters.requestedByReason[.activeSpaceChanged] == nil)
    }

    @Test @MainActor func reEntrantSleepDuringRestoringResetsCleanly() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        controller.workspaceManager.applyMonitorConfigurationChange([retina])

        let snapshot = slm.captureStateSnapshot()!
        slm.setSleepSnapshotForTests(snapshot)
        slm.setWakePhaseForTests(.deferredAwaitingDisplay)

        // Simulate sleep while in deferred phase
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

        // Monitor reconnects with DIFFERENT displayId but same name
        let ext32Renamed = makeWakeTestMonitor(displayId: 99, name: "U32J59x", x: 0, y: -1440, width: 2560, height: 1440)
        slm.setSleepSnapshotForTests(snapshot)
        slm.setWakePhaseForTests(.deferredAwaitingDisplay)

        // Display event should transition to restoring (settling) phase
        slm.handleDisplayEventForTests(.connected(ext32Renamed))

        // Settle-then-correct: stays in restoring, snapshot preserved for correction
        guard case .restoring = slm.wakePhase else {
            Issue.record("Expected .restoring (settling), got \(slm.wakePhase)")
            return
        }
        #expect(slm.sleepSnapshot != nil)
    }

    @Test @MainActor func wakeGateQueuesReasonsDuringRestoringPhase() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        controller.workspaceManager.applyMonitorConfigurationChange([retina])

        let snapshot = slm.captureStateSnapshot()!
        let context = ServiceLifecycleManager.WakeRestorationContext(
            snapshot: snapshot,
            restoredOutputIds: [],
            deferredRescanReasons: [],
            userModifiedWorkspaceIds: [],
            deadline: Date().addingTimeInterval(15)
        )
        slm.setWakePhaseForTests(.restoring(context))

        slm.gatedRequestFullRescan(reason: .activeSpaceChanged)
        slm.gatedRequestFullRescan(reason: .unlock)

        guard case let .restoring(updatedContext) = slm.wakePhase else {
            Issue.record("Expected restoring phase")
            return
        }
        #expect(updatedContext.deferredRescanReasons.count == 2)
        #expect(updatedContext.deferredRescanReasons[0] == .activeSpaceChanged)
        #expect(updatedContext.deferredRescanReasons[1] == .unlock)
    }
}
