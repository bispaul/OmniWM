import AppKit
import Foundation

enum ActivationEventSource: String, Sendable {
    case focusedWindowChanged
    case workspaceDidActivateApplication
    case cgsFrontAppChanged

    var isAuthoritative: Bool {
        self == .focusedWindowChanged
    }
}

@MainActor
final class ServiceLifecycleManager {
    // MARK: - Wake Restore Types

    struct SleepStateSnapshot {
        let outputIds: [OutputId]
        let windowWorkspaces: [WindowToken: WorkspaceDescriptor.ID]
        let niriPlacements: [WorkspaceDescriptor.ID: [WindowToken: PersistedNiriPlacement]]
        let viewportStates: [WorkspaceDescriptor.ID: ViewportState]
        let focusedToken: WindowToken?
        let timestamp: Date
    }

    struct WakeRestorationContext {
        let snapshot: SleepStateSnapshot
        var restoredOutputIds: Set<OutputId>
        var deferredRescanReasons: [RefreshReason]
        var userModifiedWorkspaceIds: Set<WorkspaceDescriptor.ID>
        let deadline: Date
    }

    enum WakePhase {
        case idle
        case deferredAwaitingDisplay
        case restoring(WakeRestorationContext)
        case draining
    }

    weak var controller: WMController?

    private var displayObserver: DisplayConfigurationObserver?
    private var appActivationObserver: NSObjectProtocol?
    private var appDeactivationObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var appUnhideObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var permissionCheckerTask: Task<Void, Never>?
    private(set) var isSecureInputActive = false

    // MARK: - Wake Restore State

    private(set) var wakePhase: WakePhase = .idle
    private(set) var sleepSnapshot: SleepStateSnapshot?
    private var wakeTimeoutTask: Task<Void, Never>?
    var accessibilityPermissionStreamProviderForTests: ((Bool) -> AsyncStream<Bool>)?
    var accessibilityPermissionStateProviderForTests: (() -> Bool)?
    var accessibilityPermissionRequestHandlerForTests: (() -> Bool)?

    init(controller: WMController) {
        self.controller = controller
    }

    func start() {
        guard let controller else { return }
        let initialPermissionGranted = currentAccessibilityPermissionGranted()
        controller.updateAccessibilityPermissionGranted(initialPermissionGranted)
        if controller.desiredEnabled,
           initialPermissionGranted,
           !controller.hasStartedServices
        {
            startServices()
        }
        permissionCheckerTask?.cancel()
        permissionCheckerTask = Task { @MainActor [weak self, weak controller] in
            guard let self else { return }
            for await granted in self.accessibilityPermissionStream(initial: true) {
                guard let controller, !Task.isCancelled else { return }

                if granted {
                    controller.updateAccessibilityPermissionGranted(true)
                    if controller.desiredEnabled, !controller.hasStartedServices {
                        self.startServices()
                    }
                } else {
                    _ = self.requestAccessibilityPermission()
                    controller.updateAccessibilityPermissionGranted(false)
                }
            }
        }
    }

    private func startServices() {
        guard let controller, !controller.hasStartedServices else { return }
        controller.hasStartedServices = true
        WMLog.ax.info("startServices: begin")
        controller.reconcileEnabledAndHotkeysState()
        controller.layoutRefreshController.setup()
        controller.axEventHandler.setup()
        controller.axManager.onAppLaunched = { [weak self] _ in
            self?.handleAppLaunched()
        }
        controller.axManager.onAppTerminated = { [weak self] pid in
            self?.handleAppTerminated(pid: pid)
        }
        controller.axManager.onFrameAcceptedAtDifferentSize = { [weak self] windowId, observedFrame in
            self?.handleFrameAcceptedAtDifferentSize(windowId: windowId, observedFrame: observedFrame)
        }
        controller.workspaceManager.onFullscreenColumnCapture = { [weak controller] token, workspaceId in
            guard let engine = controller?.niriEngine,
                  let node = engine.findNode(for: token),
                  let column = engine.column(of: node),
                  let index = engine.columnIndex(of: column, in: workspaceId)
            else { return nil }
            return index
        }
        AppAXContext.onWindowDestroyed = { [weak controller] pid, windowId in
            guard let controller else { return }
            controller.axEventHandler.handleRemoved(pid: pid, winId: windowId)
        }
        AppAXContext.onWindowMiniaturized = { [weak controller] pid, windowId in
            controller?.axEventHandler.handleWindowMiniaturized(pid: pid, windowId: windowId)
        }
        AppAXContext.onFocusedWindowChanged = { [weak controller] pid in
            controller?.axEventHandler.handleAppActivation(
                pid: pid,
                source: .focusedWindowChanged
            )
        }
        setupWorkspaceObservation()
        controller.mouseEventHandler.setup()
        controller.syncMouseWarpPolicy()
        setupDisplayObserver()
        setupAppActivationObserver()
        setupAppDeactivationObserver()
        setupAppHideObservers()
        setupSleepWakeObservation()
        controller.workspaceManager.onGapsChanged = { [weak self] in
            self?.handleGapsChanged()
        }

        performStartupRefresh()
        startSecureInputMonitor()
        startLockScreenObserver()
    }

    private func startLockScreenObserver() {
        guard let controller else { return }
        controller.lockScreenObserver.onLockDetected = { [weak controller] in
            controller?.isLockScreenActive = true
        }
        controller.lockScreenObserver.onUnlockDetected = { [weak controller] in
            guard let controller else { return }
            controller.isLockScreenActive = false
            controller.serviceLifecycleManager.handleUnlockDetected()
        }
        controller.lockScreenObserver.start()
    }

    private func startSecureInputMonitor() {
        guard let controller else { return }
        controller.secureInputMonitor.start { [weak self] isSecure in
            self?.handleSecureInputChange(isSecure)
        }
    }

    private func handleSecureInputChange(_ isSecure: Bool) {
        guard let controller else { return }
        let didSuppressActiveHotkeys = isSecure && controller.hotkeysEnabled
        isSecureInputActive = isSecure
        controller.reconcileEnabledAndHotkeysState()
        if isSecure {
            if didSuppressActiveHotkeys {
                SecureInputIndicatorController.shared.show()
            }
        } else {
            SecureInputIndicatorController.shared.hide()
        }
    }

    func handleSecureInputChangeForTests(_ isSecure: Bool) {
        handleSecureInputChange(isSecure)
    }

    private func setupDisplayObserver() {
        displayObserver = DisplayConfigurationObserver()
        displayObserver?.setEventHandler { [weak self] event in
            self?.handleDisplayEvent(event)
        }
    }

    private func handleDisplayEvent(_ event: DisplayConfigurationObserver.DisplayEvent) {
        if case .deferredAwaitingDisplay = wakePhase {
            wakePhase = .idle
            wakeTimeoutTask?.cancel()
            startWakeReconciliationNow()
            return
        }

        switch event {
        case let .disconnected(monitorId, outputId):
            handleMonitorDisconnect(monitorId: monitorId, outputId: outputId)
        case .connected,
             .reconfigured:
            break
        }
        handleMonitorConfigurationChanged()
    }

    private func handleMonitorDisconnect(monitorId: Monitor.ID, outputId: OutputId) {
        guard let controller else { return }
        controller.layoutRefreshController.cleanupForMonitorDisconnect(
            displayId: outputId.displayId,
            migrateAnimations: false
        )

        controller.niriEngine?.cleanupRemovedMonitor(monitorId)
        controller.dwindleEngine?.cleanupRemovedMonitor(monitorId)
    }

    private func handleMonitorConfigurationChanged() {
        applyMonitorConfigurationChanged(currentMonitors: Monitor.current())
    }

    func applyMonitorConfigurationChanged(
        currentMonitors: [Monitor],
        performPostUpdateActions: Bool = true
    ) {
        guard let controller else { return }
        // Invalidate border cache so it gets fully recomputed after monitor change
        // (prevents stale geometry when display ID or coordinate space changes, e.g. KVM switch)
        controller.focusBorderController.hide()
        guard !currentMonitors.isEmpty else { return }
        WMLog.workspace
            .info("applyMonitorConfigurationChanged: monitorCount=\(currentMonitors.count, privacy: .public)")
        guard currentMonitors.allSatisfy({ $0.frame.width > 1 && $0.frame.height > 1 }) else { return }

        controller.workspaceManager.isReconciling = true
        controller.workspaceManager.applyMonitorConfigurationChange(currentMonitors)
        controller.syncMouseWarpPolicy(for: controller.workspaceManager.monitors)
        guard performPostUpdateActions else {
            controller.workspaceManager.isReconciling = false
            return
        }

        controller.syncMonitorsToNiriEngine()

        let focusedWsId = controller.workspaceManager.focusedToken
            .flatMap { controller.workspaceManager.workspace(for: $0) }
        controller.workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWsId)

        gatedRequestFullRescan(reason: .monitorConfigurationChanged)
        controller.workspaceManager.isReconciling = false
    }

    func captureStateSnapshot() -> SleepStateSnapshot? {
        guard let controller else { return nil }
        let wm = controller.workspaceManager
        let outputIds = wm.monitors.map { OutputId(from: $0) }

        var windowWorkspaces: [WindowToken: WorkspaceDescriptor.ID] = [:]
        for entry in wm.allEntries() {
            windowWorkspaces[entry.token] = entry.workspaceId
        }

        var niriPlacements: [WorkspaceDescriptor.ID: [WindowToken: PersistedNiriPlacement]] = [:]
        var viewportStates: [WorkspaceDescriptor.ID: ViewportState] = [:]

        if let engine = controller.niriEngine {
            for ws in wm.workspaces {
                let placements = engine.persistedPlacements(in: ws.id)
                if !placements.isEmpty {
                    niriPlacements[ws.id] = placements
                }
                viewportStates[ws.id] = wm.niriViewportState(for: ws.id)
            }
        }

        return SleepStateSnapshot(
            outputIds: outputIds,
            windowWorkspaces: windowWorkspaces,
            niriPlacements: niriPlacements,
            viewportStates: viewportStates,
            focusedToken: wm.focusedToken,
            timestamp: Date()
        )
    }

    func handleAppTerminated(pid: pid_t) {
        guard let controller else { return }
        controller.axEventHandler.cleanupFocusStateForTerminatedApp(pid: pid)
        let removedTokens = controller.workspaceManager.entries(forPid: pid).map(\.token)
        for token in removedTokens {
            controller.cleanupScratchpadWindowResourcesIfNeeded(for: token)
            controller.axManager.removeWindowState(pid: token.pid, windowId: token.windowId)
        }
        let affectedWorkspaces = controller.workspaceManager.removeWindowsForApp(pid: pid)
        for token in removedTokens {
            controller.nativeFullscreenPlaceholderManager.remove(token)
            controller.clearResizePlaceholder(for: token)
        }
        for workspaceId in affectedWorkspaces {
            if let monitorId = controller.workspaceManager.monitorId(for: workspaceId),
               controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
            {
                controller.ensureFocusedTokenValid(in: workspaceId)
            }
        }
        _ = controller.focusBorderController.refresh(forceOrdering: true)
        controller.appInfoCache.evict(pid: pid)
        gatedRequestFullRescan(reason: .appTerminated)
    }

    func handleGapsChanged() {
        controller?.layoutRefreshController.requestRelayout(reason: .gapsChanged)
    }

    func handleAppLaunched() {
        gatedRequestFullRescan(reason: .appLaunched)
    }

    private func handleFrameAcceptedAtDifferentSize(windowId: Int, observedFrame: CGRect) {
        guard let controller else { return }
        guard let entry = controller.workspaceManager.entry(forWindowId: windowId) else {
            WMLog.ax.debug("handleFrameAcceptedAtDifferentSize: no entry for windowId=\(windowId, privacy: .public)")
            return
        }

        let workspaceId = entry.workspaceId
        let token = entry.token
        let acceptedWidth = observedFrame.width

        let effectiveMinWidth: CGFloat
        if let constraints = entry.cachedConstraints?.normalized() {
            let placeholderMin = entry.resizePlaceholderState?.minimumSize.width ?? 0
            effectiveMinWidth = max(constraints.minSize.width, placeholderMin)
        } else {
            effectiveMinWidth = 1
        }
        let flooredWidth = max(acceptedWidth, effectiveMinWidth)

        var widthChanged = false
        if let engine = controller.niriEngine,
           let node = engine.findNode(for: token),
           let column = engine.column(of: node),
           abs(column.cachedWidth - flooredWidth) > 0.5
        {
            WMLog.ax
                .info(
                    "handleFrameAcceptedAtDifferentSize: niri cachedWidth \(column.cachedWidth, privacy: .public) → \(flooredWidth, privacy: .public) windowId=\(windowId, privacy: .public)"
                )
            column.cachedWidth = flooredWidth
            widthChanged = true
        }

        if widthChanged {
            controller.layoutRefreshController.markWorkspaceDirty(workspaceId)
        }
    }

    private func startWakeReconciliation() {
        wakePhase = .deferredAwaitingDisplay
        controller?.workspaceManager.isReconciling = true
        WMLog.ax.info("wakeReconciliation: deferred, waiting for display event")

        wakeTimeoutTask?.cancel()
        wakeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            guard case .deferredAwaitingDisplay = self?.wakePhase else { return }
            WMLog.ax.info("wakeReconciliation: 30s timeout, reconciling without display event")
            self?.wakePhase = .idle
            self?.startWakeReconciliationNow()
        }
    }

    private func startWakeReconciliationNow() {
        guard let controller else { return }
        wakeTimeoutTask?.cancel()
        let expectedOutputIds = sleepSnapshot?.outputIds ?? controller.workspaceManager.monitors.map { OutputId(from: $0) }
        controller.workspaceManager.isReconciling = true

        wakeTimeoutTask = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, !Task.isCancelled {
                let currentIds = Set(Monitor.current().map(\.id))
                if currentIds.count >= expectedOutputIds.count {
                    break
                }
                WMLog.ax.debug(
                    "wakeReconciliation: waiting for monitors current=\(currentIds.count, privacy: .public) expected=\(expectedOutputIds.count, privacy: .public)"
                )
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else {
                self?.controller?.workspaceManager.isReconciling = false
                return
            }

            let currentMonitors = Monitor.current()
            let currentMonitorIds = Set(currentMonitors.map(\.id))
            let snapshotMonitorIds = Set(expectedOutputIds.map { Monitor.ID(displayId: $0.displayId) })

            if let snapshot = self?.sleepSnapshot, currentMonitorIds == snapshotMonitorIds {
                WMLog.ax.info("wakeReconciliation: same monitors, restoring from snapshot")
                self?.restoreFromSnapshot(snapshot)
            } else {
                WMLog.ax.info("wakeReconciliation: monitor change detected, full restoration")
                self?.applyMonitorConfigurationChanged(currentMonitors: currentMonitors)
            }
            self?.sleepSnapshot = nil
            self?.controller?.workspaceManager.isReconciling = false
        }
    }

    private func restoreFromSnapshot(_ snapshot: SleepStateSnapshot) {
        guard let controller else { return }
        let wm = controller.workspaceManager

        // Restore viewport states
        for (wsId, viewportState) in snapshot.viewportStates {
            wm.updateNiriViewportState(viewportState, for: wsId)
        }

        // Restore Niri column placements (widths, indices)
        if let engine = controller.niriEngine {
            for (wsId, placements) in snapshot.niriPlacements {
                // Clear existing windows from the engine tree so restoreInitialPlacements
                // can rebuild columns with persisted widths/states. The guard in
                // restoreInitialPlacements requires missingPlacedTokens to be non-empty.
                let tokens = Array(placements.keys)
                for token in tokens {
                    engine.removeWindow(token: token)
                }
                _ = engine.restoreInitialPlacements(placements, matching: tokens, in: wsId)
            }
        }

        // Restore focus
        if let focusedToken = snapshot.focusedToken,
           let wsId = wm.workspace(for: focusedToken),
           let monitorId = wm.monitorId(for: wsId)
        {
            _ = wm.setManagedFocus(focusedToken, in: wsId, onMonitor: monitorId)
        }

        // Validate windows still exist
        validateRestoredWindows(from: snapshot)

        // Trigger layout reflow
        controller.layoutRefreshController.requestFullRescan(reason: .monitorConfigurationChanged)
    }

    private func validateRestoredWindows(from snapshot: SleepStateSnapshot) {
        guard let controller else { return }
        for (_, placements) in snapshot.niriPlacements {
            for token in placements.keys {
                guard NSRunningApplication(processIdentifier: token.pid) != nil else {
                    WMLog.ax.info(
                        "wakeValidation: removing dead window pid=\(token.pid, privacy: .public) wid=\(token.windowId, privacy: .public)"
                    )
                    _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
                    controller.niriEngine?.removeWindow(token: token)
                    continue
                }
            }
        }
    }

    // MARK: - Wake Gate

    private var isWakeGateActive: Bool {
        if case .idle = wakePhase { return false }
        return true
    }

    func gatedRequestFullRescan(reason: RefreshReason) {
        guard let controller else { return }
        if isWakeGateActive {
            if case .restoring(var context) = wakePhase {
                context.deferredRescanReasons.append(reason)
                wakePhase = .restoring(context)
            }
            WMLog.ax.info("wakeGate: deferred rescan reason=\(reason.rawValue, privacy: .public)")
            return
        }
        controller.layoutRefreshController.requestFullRescan(reason: reason)
    }

    func setWakePhaseForTests(_ phase: WakePhase) {
        wakePhase = phase
    }

    func handleUnlockDetected() {
        gatedRequestFullRescan(reason: .unlock)
    }

    func performStartupRefresh() {
        WMLog.ax.info("performStartupRefresh: requestFullRescan reason=startup")
        controller?.layoutRefreshController.requestFullRescan(reason: .startup)
    }

    func handleActiveSpaceDidChange() {
        guard let controller else { return }
        controller.focusBorderController.hide()
        controller.workspaceManager.recordReconcileEvent(.activeSpaceChanged(source: .service))
        gatedRequestFullRescan(reason: .activeSpaceChanged)
    }

    private func setupWorkspaceObservation() {
        guard controller != nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleActiveSpaceDidChange()
            }
        }
    }

    private func setupAppActivationObserver() {
        guard let controller else { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak controller] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                controller?.axEventHandler.handleAppActivation(
                    pid: pid,
                    source: .workspaceDidActivateApplication
                )
            }
        }
    }

    private func setupAppDeactivationObserver() {
        guard let controller else { return }
        appDeactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak controller] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated {
                controller?.axEventHandler.handleAppDeactivated(pid: app.processIdentifier)
            }
        }
    }

    private func setupAppHideObservers() {
        guard let controller else { return }
        appHideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak controller] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated {
                controller?.axEventHandler.handleAppHidden(pid: app.processIdentifier)
            }
        }

        appUnhideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak controller] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated {
                controller?.axEventHandler.handleAppUnhidden(pid: app.processIdentifier)
            }
        }
    }

    private func setupSleepWakeObservation() {
        guard controller != nil else { return }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleepSnapshot = self?.captureStateSnapshot()
                WMLog.ax.info(
                    "systemSleep: snapshot captured monitors=\(self?.sleepSnapshot?.outputIds.count ?? 0, privacy: .public)"
                )
                _ = self?.controller?.workspaceManager.recordReconcileEvent(.systemSleep(source: .service))
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let controller = self.controller else { return }
                WMLog.ax.info("systemWake: startWakeReconciliation")
                _ = controller.workspaceManager.recordReconcileEvent(.systemWake(source: .service))
                self.startWakeReconciliation()
            }
        }
    }

    func stop() {
        guard let controller else { return }
        controller.hasStartedServices = false

        AppAXContext.onWindowDestroyed = nil
        AppAXContext.onWindowMiniaturized = nil
        AppAXContext.onFocusedWindowChanged = nil
        controller.axManager.onAppLaunched = nil
        controller.axManager.onAppTerminated = nil
        controller.axManager.onFrameAcceptedAtDifferentSize = nil
        controller.workspaceManager.onGapsChanged = nil

        controller.layoutRefreshController.resetState()
        controller.mouseEventHandler.cleanup()
        controller.resetMouseWarpPolicy()
        controller.axEventHandler.cleanup()

        controller.tabbedOverlayManager.removeAll()
        controller.nativeFullscreenPlaceholderManager.removeAll()
        controller.resizePlaceholderManager.removeAll()
        controller.focusBorderController.cleanup()
        controller.cleanupUIOnStop()

        controller.axManager.cleanup()

        displayObserver = nil

        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
        if let observer = appDeactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appDeactivationObserver = nil
        }
        if let observer = appHideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appHideObserver = nil
        }
        if let observer = appUnhideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appUnhideObserver = nil
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepObserver = nil
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }

        controller.secureInputMonitor.stop()
        isSecureInputActive = false
        SecureInputIndicatorController.shared.hide()
        controller.lockScreenObserver.stop()
        permissionCheckerTask?.cancel()
        permissionCheckerTask = nil
        controller.reconcileEnabledAndHotkeysState()
    }

    private func accessibilityPermissionStream(initial: Bool) -> AsyncStream<Bool> {
        accessibilityPermissionStreamProviderForTests?(initial)
            ?? AccessibilityPermissionMonitor.shared.stream(initial: initial)
    }

    private func currentAccessibilityPermissionGranted() -> Bool {
        accessibilityPermissionStateProviderForTests?() ?? AccessibilityPermissionMonitor.shared.isGranted
    }

    @discardableResult
    private func requestAccessibilityPermission() -> Bool {
        accessibilityPermissionRequestHandlerForTests?() ?? controller?.axManager.requestPermission() ?? false
    }
}
