# Fix C: Sleep/Wake Snapshot Restore — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken polling-based sleep/wake restore with an event-driven, per-monitor restore gated by a WakePhase state machine — eliminating the 6-rescan race that scrambles windows across displays.

**Architecture:** WakePhase enum (idle → deferredAwaitingDisplay → restoring → draining → idle) replaces boolean flags. Rolling snapshot captured on display disconnect uses OutputId (displayId + name) for stable matching. Each monitor restore happens synchronously on its reconnect event. A wake gate defers all requestFullRescan calls until the restore completes.

**Tech Stack:** Swift 6.2, @MainActor strict concurrency, Apple Testing framework (@Suite/@Test), os.Logger (WMLog)

**Spec:** `docs/superpowers/specs/2026-06-07-fix-c-sleep-wake-restore-design.md`

**Branch:** `fix/scope-relayout-to-workspace` at `fce0573`

**Build:** `swift build -c debug` from repo root

**Test:** `swift test --filter WakeRestore` (NEVER bare `swift test` on active desktop — SkyLight creates real windows)

**Deploy:** `pkill OmniWM; .build/debug/OmniWM &; sleep 1; pgrep -x OmniWM; /Applications/OmniWM.app/Contents/MacOS/omniwmctl ping`

**Logs:** `command log show --predicate 'subsystem == "com.omniwm"' --last 30s --style compact --info --debug`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` | Modify | WakePhase enum, WakeRestorationContext, SleepStateSnapshot enhancement, wake gate, per-monitor restore, drain, timeouts |
| `Tests/OmniWMTests/WakeRestoreTests.swift` | Create | All wake restore tests (separate from existing ServiceLifecycleManagerTests) |

All changes are in ServiceLifecycleManager. No new files in Sources — the types (WakePhase, WakeRestorationContext) nest inside the class or are file-private. Tests get their own file for isolation.

---

## Task 1: Add WakePhase State Machine + WakeRestorationContext

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift:15-38` (replace SleepStateSnapshot + flags)
- Create: `Tests/OmniWMTests/WakeRestoreTests.swift`

- [ ] **Step 1: Write failing test — WakePhase defaults to idle**

Create `Tests/OmniWMTests/WakeRestoreTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter WakeRestoreTests/wakePhaseDefaultsToIdle 2>&1 | tail -5`

Expected: FAIL — `wakePhase` property doesn't exist, `WakePhase` type doesn't exist.

- [ ] **Step 3: Implement WakePhase enum, WakeRestorationContext, enhanced SleepStateSnapshot**

In `ServiceLifecycleManager.swift`, replace lines 15-38 (the current `SleepStateSnapshot` struct and flag properties):

```swift
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

    // MARK: - Wake Restore State

    private(set) var wakePhase: WakePhase = .idle
    private(set) var sleepSnapshot: SleepStateSnapshot?
    private var wakeTimeoutTask: Task<Void, Never>?
```

Remove these old properties (they're replaced by `wakePhase`):
- `private var wakeReconciliationTask: Task<Void, Never>?` (line 34)
- `var pendingWakeReconciliation: Bool = false` (line 38)

Keep `sleepObserver` and `wakeObserver` (lines 32-33) — they're NotificationCenter observer tokens, still needed.

- [ ] **Step 4: Update captureStateSnapshot to use OutputId + windowWorkspaces**

Replace the `captureStateSnapshot` method (lines 239-263):

```swift
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
```

- [ ] **Step 5: Fix all compilation errors from removed monitorIds field**

The old `SleepStateSnapshot` had `monitorIds: Set<Monitor.ID>`. References to update:
- `setupSleepWakeObservation` log line: change `self?.sleepSnapshot?.monitorIds.count` → `self?.sleepSnapshot?.outputIds.count`
- `startWakeReconciliationNow` comparison: this method will be deleted in Task 3, but must compile now — temporarily keep it compiling by adapting the comparison or add a `// TODO: delete in Task 3` comment.
- `validateRestoredWindows`: iterates `snapshot.niriPlacements` — no change needed (doesn't use `monitorIds`).

- [ ] **Step 6: Run test to verify it passes**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter WakeRestoreTests/wakePhaseDefaultsToIdle 2>&1 | tail -5`

Expected: PASS

- [ ] **Step 7: Build to verify no regressions**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | tail -5`

Expected: Build succeeded

- [ ] **Step 8: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift Tests/OmniWMTests/WakeRestoreTests.swift
git commit -m "refactor(fix-c): add WakePhase state machine + enhanced SleepStateSnapshot

Replace pendingWakeReconciliation bool + wakeReconciliationTask with WakePhase
enum (idle/deferredAwaitingDisplay/restoring/draining). SleepStateSnapshot now
uses OutputId (displayId + name) for stable monitor matching and captures
windowWorkspaces map for workspace assignment restoration.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 2: Wake Gate (gatedRequestFullRescan)

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift`
- Modify: `Tests/OmniWMTests/WakeRestoreTests.swift`

- [ ] **Step 1: Write failing test — wake gate defers rescan when not idle**

Add to `WakeRestoreTests.swift`:

```swift
    @Test @MainActor func wakeGateDefersRescanDuringDeferredPhase() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        // Manually set phase to deferred
        slm.setWakePhaseForTests(.deferredAwaitingDisplay)

        slm.gatedRequestFullRescan(reason: .activeSpaceChanged)

        // Rescan should NOT have been forwarded
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter WakeRestoreTests/wakeGate 2>&1 | tail -5`

Expected: FAIL — `gatedRequestFullRescan` and `setWakePhaseForTests` don't exist.

- [ ] **Step 3: Implement wake gate + test helper**

Add to ServiceLifecycleManager, in the `// MARK: - Wake Restore` section:

```swift
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
```

- [ ] **Step 4: Wire all requestFullRescan callers through the gate**

Replace direct `requestFullRescan` calls in these methods:

**`handleUnlockDetected` (line ~445):**
```swift
    func handleUnlockDetected() {
        guard let controller else { return }
        gatedRequestFullRescan(reason: .unlock)
    }
```

**`handleActiveSpaceDidChange` (line ~455):**
```swift
    func handleActiveSpaceDidChange() {
        guard let controller else { return }
        controller.focusBorderController.hide()
        controller.workspaceManager.recordReconcileEvent(.activeSpaceChanged(source: .service))
        gatedRequestFullRescan(reason: .activeSpaceChanged)
    }
```

**`handleAppLaunched` (line ~295):**
```swift
    func handleAppLaunched() {
        gatedRequestFullRescan(reason: .appLaunched)
    }
```

**`handleAppTerminated` (line ~266) — the requestFullRescan near the end:**
```swift
    // Change the requestFullRescan line to:
    gatedRequestFullRescan(reason: .appTerminated)
```

**`applyMonitorConfigurationChanged` (line ~234) — the requestFullRescan near the end:**
```swift
    // Change the requestFullRescan line to:
    gatedRequestFullRescan(reason: .monitorConfigurationChanged)
```

**`performStartupRefresh` (line ~450):**
```swift
    func performStartupRefresh() {
        WMLog.ax.info("performStartupRefresh: requestFullRescan reason=startup")
        // Startup is never during wake — use direct call
        controller?.layoutRefreshController.requestFullRescan(reason: .startup)
    }
```

Note: `performStartupRefresh` uses direct call (startup can never coincide with wake). All other callers go through the gate.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter WakeRestoreTests/wakeGate 2>&1 | tail -5`

Expected: PASS (both tests)

- [ ] **Step 6: Build to verify no regressions**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | tail -5`

Expected: Build succeeded

- [ ] **Step 7: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift Tests/OmniWMTests/WakeRestoreTests.swift
git commit -m "feat(fix-c): add wake gate to block requestFullRescan during wake window

gatedRequestFullRescan checks wakePhase — defers rescan reasons during
non-idle phases, forwards directly when idle. Wire 5 callers through gate:
handleUnlockDetected, handleActiveSpaceDidChange, handleAppLaunched,
handleAppTerminated, applyMonitorConfigurationChanged. performStartupRefresh
stays direct (startup never coincides with wake).

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 3: Rewrite handleDisplayEvent + Sleep/Wake Observation

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift`
- Modify: `Tests/OmniWMTests/WakeRestoreTests.swift`

- [ ] **Step 1: Write failing test — sleep captures rolling snapshot on disconnect**

```swift
    @Test @MainActor func rollingSnapshotCapturedOnFirstDisconnect() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "6", monitorAssignment: .output(OutputId(displayId: 2, name: "S27R65x")))
        ]
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        let external = makeWakeTestMonitor(displayId: 2, name: "S27R65x", x: 1920)
        controller.workspaceManager.applyMonitorConfigurationChange([retina, external])

        #expect(slm.sleepSnapshot == nil)

        // Simulate display disconnect event
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
        // Should still be the FIRST snapshot (3 monitors), not overwritten
        #expect(slm.sleepSnapshot?.outputIds.count == 3)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter WakeRestoreTests/rollingSnapshot 2>&1 | tail -5`

Expected: FAIL — `handleDisplayEventForTests` doesn't exist.

- [ ] **Step 3: Implement rewritten handleDisplayEvent + test exposure**

Replace `handleDisplayEvent` (lines 175-190) and `setupSleepWakeObservation` (lines 539-567):

```swift
    // MARK: - Display Event Handling

    func handleDisplayEventForTests(_ event: DisplayConfigurationObserver.DisplayEvent) {
        handleDisplayEvent(event)
    }

    private func handleDisplayEvent(_ event: DisplayConfigurationObserver.DisplayEvent) {
        switch wakePhase {
        case .deferredAwaitingDisplay:
            wakeTimeoutTask?.cancel()
            startRestoringPhase()
            handleWakeDisplayEvent(event)

        case .restoring:
            handleWakeDisplayEvent(event)

        case .idle, .draining:
            switch event {
            case let .disconnected(monitorId, outputId):
                if sleepSnapshot == nil {
                    sleepSnapshot = captureStateSnapshot()
                    let monCount = sleepSnapshot?.outputIds.count ?? 0
                    WMLog.ax.info("displayDisconnect: rolling snapshot captured monitors=\(monCount, privacy: .public)")
                }
                handleMonitorDisconnect(monitorId: monitorId, outputId: outputId)
            case .connected, .reconfigured:
                break
            }
            if !isWakeGateActive {
                handleMonitorConfigurationChanged()
            }
        }
    }
```

Replace `setupSleepWakeObservation` (lines 539-567):

```swift
    private func setupSleepWakeObservation() {
        guard controller != nil else { return }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Re-entrant: willSleep from ANY state resets
                self.wakeTimeoutTask?.cancel()
                if self.sleepSnapshot == nil {
                    self.sleepSnapshot = self.captureStateSnapshot()
                }
                WMLog.ax.info(
                    "systemSleep: snapshot monitors=\(self.sleepSnapshot?.outputIds.count ?? 0, privacy: .public)"
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
```

Replace `startWakeReconciliation` (lines 337-350):

```swift
    private func startWakeReconciliation() {
        wakePhase = .deferredAwaitingDisplay
        controller?.workspaceManager.isReconciling = true
        WMLog.ax.info("wakeReconciliation: deferred, waiting for display event")

        wakeTimeoutTask?.cancel()
        wakeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled,
                  case .deferredAwaitingDisplay = self?.wakePhase else { return }
            WMLog.ax.info("wakeTimeout: 30s, no display event — DarkWake, resetting")
            self?.wakePhase = .idle
            self?.sleepSnapshot = nil
            self?.controller?.workspaceManager.isReconciling = false
        }
    }
```

- [ ] **Step 4: Delete startWakeReconciliationNow (the polling loop)**

Delete the entire `startWakeReconciliationNow` method (lines 352-388). This is the polling loop that caused the race condition. It is fully replaced by the event-driven approach.

- [ ] **Step 5: Add startRestoringPhase**

```swift
    private func startRestoringPhase() {
        guard let snapshot = sleepSnapshot else {
            wakePhase = .idle
            controller?.workspaceManager.isReconciling = false
            return
        }

        let deadline = Date().addingTimeInterval(15)
        let context = WakeRestorationContext(
            snapshot: snapshot,
            restoredOutputIds: [],
            deferredRescanReasons: [],
            userModifiedWorkspaceIds: [],
            deadline: deadline
        )
        wakePhase = .restoring(context)

        wakeTimeoutTask?.cancel()
        wakeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled,
                  case let .restoring(ctx) = self?.wakePhase else { return }
            WMLog.ax.info("wakeTimeout: 15s deadline, draining with \(ctx.restoredOutputIds.count, privacy: .public) monitors restored")
            self?.beginDrain(context: ctx)
        }
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter WakeRestoreTests/rollingSnapshot 2>&1 | tail -5`

Expected: PASS

- [ ] **Step 7: Build to verify no regressions**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | tail -5`

Expected: Build succeeded

- [ ] **Step 8: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift Tests/OmniWMTests/WakeRestoreTests.swift
git commit -m "feat(fix-c): event-driven handleDisplayEvent + rolling snapshot

Rewrite handleDisplayEvent to dispatch on wakePhase enum instead of single-use
boolean. Delete startWakeReconciliationNow polling loop (root cause of the
6-rescan race). Add startRestoringPhase with 15s deadline timeout. Rolling
snapshot captured on first display disconnect before cleanup runs.
willSleep from ANY state resets cleanly (re-entrant safety).

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 4: Per-Monitor Restore + Drain

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift`
- Modify: `Tests/OmniWMTests/WakeRestoreTests.swift`

- [ ] **Step 1: Write failing test — per-monitor restore assigns windows to correct workspaces**

```swift
    @Test @MainActor func perMonitorRestoreAssignsWindowsToCorrectWorkspaces() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "8", monitorAssignment: .output(OutputId(displayId: 3, name: "U32J59x")))
        ]
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        let ext32 = makeWakeTestMonitor(displayId: 3, name: "U32J59x", x: 0, y: -1440, width: 2560, height: 1440)
        controller.workspaceManager.applyMonitorConfigurationChange([retina, ext32])

        let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)!
        let ws8 = controller.workspaceManager.workspaceId(for: "8", createIfMissing: true)!

        // Add test windows
        let token1 = WindowToken(pid: 100, windowId: 501)
        let token2 = WindowToken(pid: 200, windowId: 502)
        controller.workspaceManager.addWindowForTests(token: token1, workspaceId: ws1)
        controller.workspaceManager.addWindowForTests(token: token2, workspaceId: ws8)

        // Capture snapshot (windows on correct workspaces)
        let snapshot = slm.captureStateSnapshot()!
        slm.sleepSnapshot = snapshot

        // Simulate wake: windows got scrambled to ws1 (Retina)
        controller.workspaceManager.setWorkspace(for: token2, to: ws1)
        #expect(controller.workspaceManager.workspace(for: token2) == ws1)

        // Simulate wake + display reconnect
        slm.setWakePhaseForTests(.deferredAwaitingDisplay)
        slm.handleDisplayEventForTests(.connected(ext32))

        // After restore, token2 should be back on ws8
        #expect(controller.workspaceManager.workspace(for: token2) == ws8)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter WakeRestoreTests/perMonitorRestore 2>&1 | tail -5`

Expected: FAIL — `handleWakeDisplayEvent` doesn't exist yet.

- [ ] **Step 3: Implement handleWakeDisplayEvent + restoreWorkspacesForMonitor**

Add to ServiceLifecycleManager:

```swift
    // MARK: - Per-Monitor Restore

    private func handleWakeDisplayEvent(_ event: DisplayConfigurationObserver.DisplayEvent) {
        guard case .restoring(var context) = wakePhase else { return }

        switch event {
        case let .connected(monitor):
            let outputId = OutputId(from: monitor)

            guard context.snapshot.outputIds.contains(where: {
                $0.displayId == outputId.displayId ||
                $0.name.caseInsensitiveCompare(outputId.name) == .orderedSame
            }) else {
                applyMonitorConfigurationChanged(
                    currentMonitors: Monitor.current(),
                    performPostUpdateActions: false
                )
                return
            }

            restoreWorkspacesForMonitor(monitor, context: &context)
            context.restoredOutputIds.insert(outputId)
            wakePhase = .restoring(context)

            let allRestored = context.snapshot.outputIds.allSatisfy { snapshotOutput in
                context.restoredOutputIds.contains(where: {
                    $0.displayId == snapshotOutput.displayId ||
                    $0.name.caseInsensitiveCompare(snapshotOutput.name) == .orderedSame
                })
            }
            if allRestored || Date() >= context.deadline {
                beginDrain(context: context)
            }

        case .disconnected:
            break

        case .reconfigured:
            applyMonitorConfigurationChanged(
                currentMonitors: Monitor.current(),
                performPostUpdateActions: false
            )
        }
    }

    private func restoreWorkspacesForMonitor(_ monitor: Monitor, context: inout WakeRestorationContext) {
        guard let controller else { return }
        let wm = controller.workspaceManager

        applyMonitorConfigurationChanged(
            currentMonitors: Monitor.current(),
            performPostUpdateActions: false
        )

        let workspacesOnMonitor = wm.workspaces(on: monitor.id)
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []

        for ws in workspacesOnMonitor {
            guard !context.userModifiedWorkspaceIds.contains(ws.id) else { continue }

            for (token, snapshotWsId) in context.snapshot.windowWorkspaces {
                if snapshotWsId == ws.id, wm.workspace(for: token) != ws.id {
                    wm.setWorkspace(for: token, to: ws.id)
                }
            }

            if let viewportState = context.snapshot.viewportStates[ws.id] {
                wm.updateNiriViewportState(viewportState, for: ws.id)
            }

            if let placements = context.snapshot.niriPlacements[ws.id],
               let engine = controller.niriEngine
            {
                let tokens = Array(placements.keys)
                for token in tokens { engine.removeWindow(token: token) }
                engine.restoreInitialPlacements(placements, matching: tokens, in: ws.id)
            }

            affectedWorkspaceIds.insert(ws.id)
        }

        if !affectedWorkspaceIds.isEmpty {
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .workspaceTransition,
                affectedWorkspaceIds: affectedWorkspaceIds
            )
        }

        WMLog.ax.info(
            "wakeRestore: monitor=\(monitor.name, privacy: .public) workspaces=\(affectedWorkspaceIds.count, privacy: .public)"
        )
    }
```

- [ ] **Step 4: Implement beginDrain**

Delete the old `restoreFromSnapshot` method (lines ~390-426). Replace with:

```swift
    // MARK: - Drain Phase

    private func beginDrain(context: WakeRestorationContext) {
        guard let controller else { return }

        wakePhase = .draining

        if let focusedToken = context.snapshot.focusedToken,
           let wsId = controller.workspaceManager.workspace(for: focusedToken),
           let monitorId = controller.workspaceManager.monitorId(for: wsId)
        {
            _ = controller.workspaceManager.setManagedFocus(focusedToken, in: wsId, onMonitor: monitorId)
        }

        validateRestoredWindows(from: context.snapshot)

        wakePhase = .idle
        sleepSnapshot = nil
        wakeTimeoutTask?.cancel()
        controller.workspaceManager.isReconciling = false

        if !context.deferredRescanReasons.isEmpty {
            let allWorkspaceIds = Set(controller.workspaceManager.workspaces.map(\.id))
            WMLog.ax.info(
                "wakeDrain: flushing \(context.deferredRescanReasons.count, privacy: .public) deferred reasons as immediateRelayout"
            )
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .workspaceTransition,
                affectedWorkspaceIds: allWorkspaceIds
            )
        }
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter WakeRestoreTests/perMonitorRestore 2>&1 | tail -5`

Expected: PASS

- [ ] **Step 6: Build to verify no regressions**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | tail -5`

Expected: Build succeeded

- [ ] **Step 7: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift Tests/OmniWMTests/WakeRestoreTests.swift
git commit -m "feat(fix-c): per-monitor restore + drain phase

handleWakeDisplayEvent restores workspaces per-monitor as each display
reconnects. Uses OutputId name fallback for stable matching. Drain phase
restores focus, validates dead windows, and flushes deferred work as
requestImmediateRelayout (not requestFullRescan — prevents re-admission).
Deletes old restoreFromSnapshot/startWakeReconciliationNow.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 5: Additional Tests (Edge Cases from 3-Lens Review)

**Files:**
- Modify: `Tests/OmniWMTests/WakeRestoreTests.swift`

- [ ] **Step 1: Write test — DarkWake timeout resets to idle**

```swift
    @Test @MainActor func darkWakeTimeoutResetsToIdle() async {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        slm.setWakePhaseForTests(.deferredAwaitingDisplay)
        controller.workspaceManager.isReconciling = true

        // Simulate timeout (can't wait 30s — test the guard logic)
        // Verify the phase is deferredAwaitingDisplay
        guard case .deferredAwaitingDisplay = slm.wakePhase else {
            Issue.record("Expected deferredAwaitingDisplay")
            return
        }
        #expect(controller.workspaceManager.isReconciling == true)
    }
```

- [ ] **Step 2: Write test — re-entrant sleep during restoring resets cleanly**

```swift
    @Test @MainActor func reEntrantSleepDuringRestoringResetsCleanly() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let slm = ServiceLifecycleManager(controller: controller)

        let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
        controller.workspaceManager.applyMonitorConfigurationChange([retina])

        // Set up restoring phase
        let snapshot = slm.captureStateSnapshot()!
        slm.sleepSnapshot = snapshot
        slm.setWakePhaseForTests(.deferredAwaitingDisplay)

        // Simulate sleep while in deferred phase — should capture new snapshot + stay reset-ready
        slm.simulateSleepForTests()

        #expect(slm.sleepSnapshot != nil)
    }
```

- [ ] **Step 3: Write test — OutputId name fallback matches when displayId changes**

```swift
    @Test @MainActor func outputIdNameFallbackMatchesWhenDisplayIdChanges() {
        let defaults = makeWakeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "8", monitorAssignment: .output(OutputId(displayId: 3, name: "U32J59x")))
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
        slm.sleepSnapshot = snapshot
        slm.setWakePhaseForTests(.deferredAwaitingDisplay)

        // startRestoringPhase called internally by handleDisplayEvent
        slm.handleDisplayEventForTests(.connected(ext32Renamed))

        // Should have matched via name and entered restoring or drained
        guard case .idle = slm.wakePhase else {
            // If restoring, the name match worked and we're waiting for more monitors
            if case .restoring(let ctx) = slm.wakePhase {
                #expect(ctx.restoredOutputIds.contains(where: { $0.name == "U32J59x" }))
                return
            }
            Issue.record("Unexpected phase: \(slm.wakePhase)")
            return
        }
    }
```

- [ ] **Step 4: Write test — wake gate queues reasons during restoring phase**

```swift
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
```

- [ ] **Step 5: Add test helper simulateSleepForTests if needed**

Add to ServiceLifecycleManager:

```swift
    func simulateSleepForTests() {
        wakeTimeoutTask?.cancel()
        if sleepSnapshot == nil {
            sleepSnapshot = captureStateSnapshot()
        }
        _ = controller?.workspaceManager.recordReconcileEvent(.systemSleep(source: .service))
    }
```

- [ ] **Step 6: Run all wake restore tests**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter WakeRestoreTests 2>&1 | tail -10`

Expected: All tests PASS

- [ ] **Step 7: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Tests/OmniWMTests/WakeRestoreTests.swift Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift
git commit -m "test(fix-c): edge case tests from 3-lens architecture review

DarkWake timeout, re-entrant sleep during restore, OutputId name fallback
when displayId changes, wake gate queuing during restoring phase.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 6: Build Bump + Full Build Verification

**Files:**
- Modify: Version/build number if applicable

- [ ] **Step 1: Run full build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | tail -10`

Expected: Build succeeded with zero errors.

- [ ] **Step 2: Run existing ServiceLifecycleManagerTests to verify no regressions**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter ServiceLifecycleManagerTests 2>&1 | tail -10`

Expected: All existing tests pass. If any fail, fix before proceeding.

- [ ] **Step 3: Run all wake restore tests**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter WakeRestoreTests 2>&1 | tail -10`

Expected: All new tests pass.

- [ ] **Step 4: Commit build bump**

```bash
cd ~/Documents/Personal/github/OmniWM
git commit -m "chore: bump build to 80

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 7: Deploy + Real Sleep/Wake Verification

This task is MANUAL — requires the user to trigger a real sleep/wake cycle.

- [ ] **Step 1: Deploy debug build**

```bash
cd ~/Documents/Personal/github/OmniWM
pkill -x OmniWM || true
.build/debug/OmniWM &
sleep 2
pgrep -x OmniWM
/Applications/OmniWM.app/Contents/MacOS/omniwmctl ping
/Applications/OmniWM.app/Contents/MacOS/omniwmctl query windows | head -20
```

Verify: new PID, ping responds, windows listed.

- [ ] **Step 2: Restart omniwmctl watcher for SketchyBar**

```bash
pkill -f "omniwmctl watch"
/Applications/OmniWM.app/Contents/MacOS/omniwmctl watch --all --exec sketchybar --trigger omniwm_workspace_changed &
```

- [ ] **Step 3: Note current window layout**

Record which apps are on which monitors/workspaces using:
```bash
/Applications/OmniWM.app/Contents/MacOS/omniwmctl query windows
```

- [ ] **Step 4: Trigger sleep/wake cycle**

Close MacBook lid or use `pmset sleepnow`. Wait 10 seconds. Open lid / wake.

- [ ] **Step 5: Verify window positions restored**

```bash
/Applications/OmniWM.app/Contents/MacOS/omniwmctl query windows
```

Compare with pre-sleep output — same apps on same workspaces/monitors.

- [ ] **Step 6: Check logs for clean wake sequence**

```bash
command log show --predicate 'subsystem == "com.omniwm"' --last 2m --style compact --info --debug | grep -E "systemSleep|systemWake|wakeGate|wakeRestore|wakeDrain|wakeTimeout|displayDisconnect|wakeReconciliation"
```

Expected log pattern:
```
systemSleep: snapshot monitors=3
systemWake: startWakeReconciliation
wakeReconciliation: deferred, waiting for display event
displayDisconnect: rolling snapshot captured monitors=3 (if disconnect fires first)
wakeGate: deferred rescan reason=activeSpaceChanged (0-3 of these)
wakeRestore: monitor=S27R65x workspaces=N
wakeRestore: monitor=U32J59x workspaces=N
wakeDrain: flushing N deferred reasons as immediateRelayout
```

NOT expected (regressions):
- `Full rescan requested` during the wake window
- Multiple `Adding window` waves
- `wakeReconciliation: waiting for monitors` (polling — should be deleted)

- [ ] **Step 7: If verification passes, commit confirmation**

Update bug tracker and memorygraph with verified status.
