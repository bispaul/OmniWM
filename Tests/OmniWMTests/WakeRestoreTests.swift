import ApplicationServices
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

    @Test @MainActor func executeFinalRestoreFixesStaleSelectedNodeId() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        controller.workspaceManager.applyMonitorConfigurationChange([retina])

        // Enable Niri engine
        controller.enableNiriLayout()

        // Create workspace
        guard let wsId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        else {
            Issue.record("Failed to create workspace")
            return
        }
        _ = controller.workspaceManager.setActiveWorkspace(wsId, on: retina.id)

        // Add 3 windows — creates 3 Niri columns
        // Use current process PID so validateRestoredWindows doesn't remove them as "dead"
        let livePid = ProcessInfo.processInfo.processIdentifier
        let pid1: pid_t = livePid
        let pid2: pid_t = livePid
        let pid3: pid_t = livePid
        let ax1 = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 1)
        let ax2 = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 2)
        let ax3 = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 3)

        let token1 = controller.workspaceManager.addWindow(ax1, pid: pid1, windowId: 1, to: wsId)
        let token2 = controller.workspaceManager.addWindow(ax2, pid: pid2, windowId: 2, to: wsId)
        let token3 = controller.workspaceManager.addWindow(ax3, pid: pid3, windowId: 3, to: wsId)

        guard let engine = controller.niriEngine else {
            Issue.record("Niri engine not available")
            return
        }
        _ = engine.addWindow(token: token1, to: wsId, afterSelection: nil, focusedToken: nil)
        _ = engine.addWindow(token: token2, to: wsId, afterSelection: nil, focusedToken: nil)
        _ = engine.addWindow(token: token3, to: wsId, afterSelection: nil, focusedToken: nil)

        // Verify 3 columns exist
        let columns = engine.columns(in: wsId)
        #expect(columns.count == 3)

        // Set viewport to column 2 (third column)
        let originalNodeId = columns[2].activeWindow?.id
        #expect(originalNodeId != nil)

        controller.workspaceManager.withNiriViewportState(for: wsId) { state in
            state.activeColumnIndex = 2
            state.selectedNodeId = originalNodeId
        }

        // Capture snapshot
        guard let snapshot = slm.captureStateSnapshot() else {
            Issue.record("Failed to capture snapshot")
            return
        }

        // Verify snapshot has Niri placements
        #expect(snapshot.niriPlacements[wsId] != nil)
        #expect(snapshot.niriPlacements[wsId]?.count == 3)

        // Call executeFinalRestore directly (synchronous)
        slm.executeFinalRestoreForTests(from: snapshot)

        // After restore: selectedNodeId should reference a VALID node
        let restoredViewport = controller.workspaceManager.niriViewportState(for: wsId)
        #expect(restoredViewport.activeColumnIndex == 2)

        if let selectedId = restoredViewport.selectedNodeId {
            let foundNode = engine.findNode(by: selectedId)
            #expect(foundNode != nil, "selectedNodeId must reference a valid node in the rebuilt tree")
        } else {
            Issue.record("selectedNodeId should not be nil after restore")
        }
    }
}
