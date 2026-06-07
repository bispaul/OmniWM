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

    enum LayoutEngineType: String {
        case niri
        case dwindle
        case unmanaged
    }

    struct SleepWindowRecord {
        let token: WindowToken
        let pid: pid_t
        let bundleId: String?
        let title: String?
        let workspaceId: WorkspaceDescriptor.ID
        let monitorId: Monitor.ID
        let frame: CGRect
        let mode: TrackedWindowMode
        let isVisible: Bool
        let hiddenReason: WindowModel.HiddenReason?
        let isNativeFullscreen: Bool
        let floatingFrame: CGRect?
        let layoutEngine: LayoutEngineType
    }

    struct SleepStateSnapshot {
        let outputIds: [OutputId]
        let windowRecords: [SleepWindowRecord]
        let niriPlacements: [WorkspaceDescriptor.ID: [WindowToken: PersistedNiriPlacement]]
        let viewportStates: [WorkspaceDescriptor.ID: ViewportState]
        let focusedToken: WindowToken?
        let timestamp: Date

        var expectedMonitorCount: Int { outputIds.count }
    }

    enum WakePhase {
        case idle
        case awaitingRestore(SleepStateSnapshot)
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
    private var restoreTimerTask: Task<Void, Never>?
    private var darkWakeTimeoutTask: Task<Void, Never>?
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

    func handleDisplayEventForTests(_ event: DisplayConfigurationObserver.DisplayEvent) {
        handleDisplayEvent(event)
    }

    private func setupDisplayObserver() {
        displayObserver = DisplayConfigurationObserver()
        displayObserver?.setEventHandler { [weak self] event in
            self?.handleDisplayEvent(event)
        }
    }

    private func handleDisplayEvent(_ event: DisplayConfigurationObserver.DisplayEvent) {
        switch event {
        case let .disconnected(monitorId, outputId):
            if sleepSnapshot == nil, case .idle = wakePhase {
                sleepSnapshot = captureStateSnapshot()
                let monCount = sleepSnapshot?.outputIds.count ?? 0
                WMLog.ax.info("displayDisconnect: rolling snapshot captured monitors=\(monCount, privacy: .public)")
            }
            handleMonitorDisconnect(monitorId: monitorId, outputId: outputId)
        case .connected, .reconfigured:
            break
        }

        if case .awaitingRestore = wakePhase {
            darkWakeTimeoutTask?.cancel()
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

        controller.layoutRefreshController.requestFullRescan(reason: .monitorConfigurationChanged)
        controller.workspaceManager.isReconciling = false
    }

    func captureStateSnapshot() -> SleepStateSnapshot? {
        guard let controller else { return nil }
        let wm = controller.workspaceManager
        let outputIds = wm.monitors.map { OutputId(from: $0) }

        var windowRecords: [SleepWindowRecord] = []
        for entry in wm.allEntries() {
            let monitorId = wm.monitorId(for: entry.workspaceId) ?? wm.monitors.first?.id ?? Monitor.ID(displayId: 0)
            let bundleId = NSRunningApplication(processIdentifier: entry.token.pid)?.bundleIdentifier
            let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.token.windowId))
            let layoutEngine: LayoutEngineType
            if controller.niriEngine?.findNode(for: entry.token) != nil {
                layoutEngine = .niri
            } else if controller.dwindleEngine?.findNode(for: entry.token) != nil {
                layoutEngine = .dwindle
            } else {
                layoutEngine = .unmanaged
            }
            windowRecords.append(SleepWindowRecord(
                token: entry.token,
                pid: entry.token.pid,
                bundleId: bundleId,
                title: title,
                workspaceId: entry.workspaceId,
                monitorId: monitorId,
                frame: entry.observedState.frame ?? .zero,
                mode: entry.mode,
                isVisible: entry.observedState.isVisible,
                hiddenReason: entry.hiddenReason,
                isNativeFullscreen: entry.observedState.isNativeFullscreen,
                floatingFrame: entry.floatingState?.lastFrame,
                layoutEngine: layoutEngine
            ))
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
            windowRecords: windowRecords,
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
        controller.layoutRefreshController.requestFullRescan(reason: .appTerminated)
    }

    func handleGapsChanged() {
        controller?.layoutRefreshController.requestRelayout(reason: .gapsChanged)
    }

    func handleAppLaunched() {
        controller?.layoutRefreshController.requestFullRescan(reason: .appLaunched)
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
        guard let snapshot = sleepSnapshot else {
            WMLog.ax.info("wakeReconciliation: no snapshot, skipping")
            return
        }

        wakePhase = .awaitingRestore(snapshot)
        WMLog.ax.info("wakeReconciliation: progressive restore starting, windows=\(snapshot.windowRecords.count, privacy: .public) monitors=\(snapshot.expectedMonitorCount, privacy: .public)")

        restoreTimerTask?.cancel()
        restoreTimerTask = Task { @MainActor [weak self] in
            for tick in 1...5 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled,
                      case let .awaitingRestore(snap) = self?.wakePhase else { return }
                self?.tryRestoreWorkspaces(from: snap, tick: tick)
            }
            guard case let .awaitingRestore(snap) = self?.wakePhase else { return }
            self?.finalizeWakeRestore(from: snap)
        }

        darkWakeTimeoutTask?.cancel()
        darkWakeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled,
                  case .awaitingRestore = self?.wakePhase else { return }
            WMLog.ax.info("wakeTimeout: 30s, no display events — DarkWake, resetting")
            self?.restoreTimerTask?.cancel()
            self?.wakePhase = .idle
            self?.sleepSnapshot = nil
        }
    }

    private var matchedTokens: Set<WindowToken> = []

    private func resolveTrackedToken(for record: SleepWindowRecord, in wm: WorkspaceManager) -> WindowToken? {
        if wm.entry(for: record.token) != nil, !matchedTokens.contains(record.token) {
            matchedTokens.insert(record.token)
            return record.token
        }
        let candidates = wm.entries(forPid: record.pid).filter { !matchedTokens.contains($0.token) }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 {
            matchedTokens.insert(candidates[0].token)
            return candidates[0].token
        }
        if let snapshotTitle = record.title, !snapshotTitle.isEmpty {
            let liveTitle: (WindowModel.Entry) -> String? = {
                AXWindowService.titlePreferFast(windowId: UInt32($0.token.windowId))
            }
            if let match = candidates.first(where: { liveTitle($0) == snapshotTitle }) {
                matchedTokens.insert(match.token)
                return match.token
            }
        }
        let snapshotSize = record.frame.size
        if let match = candidates.first(where: {
            guard let frame = $0.observedState.frame else { return false }
            return abs(frame.width - snapshotSize.width) < 50 && abs(frame.height - snapshotSize.height) < 50
        }) {
            matchedTokens.insert(match.token)
            return match.token
        }
        if let match = candidates.first(where: { wm.workspace(for: $0.token) == record.workspaceId }) {
            matchedTokens.insert(match.token)
            return match.token
        }
        matchedTokens.insert(candidates[0].token)
        return candidates[0].token
    }

    private func buildTokenRemap(from snapshot: SleepStateSnapshot, wm: WorkspaceManager) -> [WindowToken: WindowToken] {
        matchedTokens.removeAll()
        var remap: [WindowToken: WindowToken] = [:]
        for record in snapshot.windowRecords {
            if let resolved = resolveTrackedToken(for: record, in: wm), resolved != record.token {
                remap[record.token] = resolved
            }
        }
        return remap
    }

    private func isMonitorPresent(for record: SleepWindowRecord, snapshot: SleepStateSnapshot, currentMonitors: [Monitor]) -> Bool {
        let originalOutputId = snapshot.outputIds.first { $0.displayId == record.monitorId.displayId }
        if let originalOutputId {
            return originalOutputId.resolveMonitor(in: currentMonitors) != nil
        }
        return currentMonitors.contains { $0.id == record.monitorId }
    }

    private func tryRestoreWorkspaces(from snapshot: SleepStateSnapshot, tick: Int) {
        guard let controller else { return }
        matchedTokens.removeAll()
        let wm = controller.workspaceManager
        let currentMonitors = Monitor.current()

        var reassignedCount = 0
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []

        for record in snapshot.windowRecords {
            if record.isNativeFullscreen { continue }
            if record.hiddenReason == .scratchpad { continue }
            guard let resolvedToken = resolveTrackedToken(for: record, in: wm) else { continue }
            guard isMonitorPresent(for: record, snapshot: snapshot, currentMonitors: currentMonitors) else { continue }

            if wm.workspace(for: resolvedToken) != record.workspaceId {
                wm.setWorkspace(for: resolvedToken, to: record.workspaceId)
                reassignedCount += 1
                affectedWorkspaceIds.insert(record.workspaceId)
            }
        }

        if reassignedCount > 0, !affectedWorkspaceIds.isEmpty {
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .workspaceTransition,
                affectedWorkspaceIds: affectedWorkspaceIds
            )
        }

        WMLog.ax.info("wakeRestore: tick=\(tick, privacy: .public) reassigned=\(reassignedCount, privacy: .public)")
    }

    private func finalizeWakeRestore(from snapshot: SleepStateSnapshot) {
        guard let controller else {
            wakePhase = .idle
            sleepSnapshot = nil
            return
        }

        let missingCount = snapshot.windowRecords.filter { record in
            !record.isNativeFullscreen &&
            record.hiddenReason != .scratchpad &&
            NSRunningApplication(processIdentifier: record.pid) != nil &&
            resolveTrackedToken(for: record, in: controller.workspaceManager) == nil
        }.count

        if missingCount > 0 {
            WMLog.ax.info("wakeRestore: \(missingCount, privacy: .public) windows missing from tracking, triggering rescan before final restore")
            controller.layoutRefreshController.requestFullRescan(reason: .monitorConfigurationChanged)
            restoreTimerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled,
                      case .awaitingRestore = self?.wakePhase else { return }
                self?.executeFinalRestore(from: snapshot)
            }
            return
        }

        executeFinalRestore(from: snapshot)
    }

    private func executeFinalRestore(from snapshot: SleepStateSnapshot) {
        guard let controller else {
            wakePhase = .idle
            sleepSnapshot = nil
            return
        }

        let wm = controller.workspaceManager
        let currentMonitors = Monitor.current()
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []

        matchedTokens.removeAll()
        var reassignedCount = 0
        for record in snapshot.windowRecords {
            if record.isNativeFullscreen { continue }
            if record.hiddenReason == .scratchpad { continue }
            guard let resolvedToken = resolveTrackedToken(for: record, in: wm) else { continue }

            let monitorPresent = isMonitorPresent(for: record, snapshot: snapshot, currentMonitors: currentMonitors)

            let targetWsId: WorkspaceDescriptor.ID
            if monitorPresent {
                targetWsId = record.workspaceId
            } else if let currentWsId = wm.workspace(for: resolvedToken) {
                targetWsId = currentWsId
            } else {
                targetWsId = record.workspaceId
            }

            if wm.workspace(for: resolvedToken) != targetWsId {
                wm.setWorkspace(for: resolvedToken, to: targetWsId)
                reassignedCount += 1
            }
            if record.mode == .floating, let floatingFrame = record.floatingFrame {
                wm.updateFloatingGeometry(frame: floatingFrame, for: resolvedToken)
            }
            affectedWorkspaceIds.insert(targetWsId)
        }

        // Restore Niri placements with token remapping for recycled IDs
        if let engine = controller.niriEngine {
            let tokenMap = buildTokenRemap(from: snapshot, wm: wm)
            for (wsId, originalPlacements) in snapshot.niriPlacements {
                var remapped: [WindowToken: PersistedNiriPlacement] = [:]
                for (oldToken, placement) in originalPlacements {
                    let newToken = tokenMap[oldToken] ?? oldToken
                    remapped[newToken] = placement
                }
                let tokens = Array(remapped.keys)
                for token in tokens { engine.removeWindow(token: token) }
                engine.restoreInitialPlacements(remapped, matching: tokens, in: wsId)
                affectedWorkspaceIds.insert(wsId)
            }
        }

        // Restore viewport states
        for (wsId, viewportState) in snapshot.viewportStates {
            wm.updateNiriViewportState(viewportState, for: wsId)
        }

        // Restore focus
        if let focusedToken = snapshot.focusedToken,
           let wsId = wm.workspace(for: focusedToken),
           let monitorId = wm.monitorId(for: wsId)
        {
            _ = wm.setManagedFocus(focusedToken, in: wsId, onMonitor: monitorId)
        }

        validateRestoredWindows(from: snapshot)

        if !affectedWorkspaceIds.isEmpty {
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .workspaceTransition,
                affectedWorkspaceIds: affectedWorkspaceIds
            )
        }

        WMLog.ax.info(
            "wakeRestore: finalized reassigned=\(reassignedCount, privacy: .public) total=\(snapshot.windowRecords.count, privacy: .public)"
        )

        wakePhase = .idle
        sleepSnapshot = nil
        darkWakeTimeoutTask?.cancel()
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

    // MARK: - Test Helpers

    func setWakePhaseForTests(_ phase: WakePhase) {
        wakePhase = phase
    }

    func setSleepSnapshotForTests(_ snapshot: SleepStateSnapshot?) {
        sleepSnapshot = snapshot
    }

    func simulateSleepForTests() {
        restoreTimerTask?.cancel()
        darkWakeTimeoutTask?.cancel()
        if sleepSnapshot == nil {
            sleepSnapshot = captureStateSnapshot()
        }
        _ = controller?.workspaceManager.recordReconcileEvent(.systemSleep(source: .service))
    }

    func simulateWakeForTests() {
        startWakeReconciliation()
    }

    func handleUnlockDetected() {
        controller?.layoutRefreshController.requestFullRescan(reason: .unlock)
    }

    func performStartupRefresh() {
        WMLog.ax.info("performStartupRefresh: requestFullRescan reason=startup")
        controller?.layoutRefreshController.requestFullRescan(reason: .startup)
    }

    func handleActiveSpaceDidChange() {
        guard let controller else { return }
        controller.focusBorderController.hide()
        controller.workspaceManager.recordReconcileEvent(.activeSpaceChanged(source: .service))
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
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
                guard let self else { return }
                self.restoreTimerTask?.cancel()
                self.darkWakeTimeoutTask?.cancel()
                if case .idle = self.wakePhase {
                    if self.sleepSnapshot == nil {
                        self.sleepSnapshot = self.captureStateSnapshot()
                    }
                } else {
                    self.wakePhase = .idle
                    self.sleepSnapshot = self.captureStateSnapshot()
                    WMLog.ax.info("systemSleep: re-entrant from non-idle phase, captured fresh snapshot")
                }
                WMLog.ax.info(
                    "systemSleep: snapshot monitors=\(self.sleepSnapshot?.outputIds.count ?? 0, privacy: .public) windows=\(self.sleepSnapshot?.windowRecords.count ?? 0, privacy: .public)"
                )
                _ = self.controller?.workspaceManager.recordReconcileEvent(.systemSleep(source: .service))
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
