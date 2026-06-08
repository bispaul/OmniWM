# Build 66 Integration + SkyLight Guard Scoping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore lost build 66 mechanisms (retry cap, safety fixes, catalog poisoning) and scope the SkyLight destroy guard to wake+reconfig windows only — fixing Ghostty tab phantom columns while preserving Fix C wake protection.

**Architecture:** Three streams in one cohesive change. Stream 1 restores the stabilization retry cap (admission layer). Stream 2 manually applies thread safety, crash, and catalog poisoning fixes from backup/code-review-jun4. Stream 3 scopes the SkyLight guard using Fix C's wakePhase (pre-armed in willSleep to close the CGS timing race). All streams are independently revertible.

**Tech Stack:** Swift 6.2, Apple Testing framework (`@Test @MainActor`), `@MainActor` concurrency, SPM, OSAllocatedUnfairLock

**Spec:** `docs/superpowers/specs/2026-06-08-build66-integration-design.md`

---

## File Map

| File | Stream | Changes |
|------|--------|---------|
| `Sources/OmniWM/Core/Controller/AXEventHandler.swift` | 1, 3 | Retry cap + guard scoping |
| `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` | 3 | `isAwaitingRestore` + willSleep pre-arming |
| `Sources/OmniWM/Core/Controller/WMController.swift` | 2 | Catalog poisoning (transitionWindowMode) |
| `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift` | 2 | Catalog poisoning (setWindowMode) |
| `Sources/OmniWM/Core/Border/BorderWindow.swift` | 2 | nextStubWindowId → OSAllocatedUnfairLock |
| `Sources/OmniWM/Core/Support/CGGeometry+Extensions.swift` | 2 | ScreenCoordinateSpace statics → OSAllocatedUnfairLock |
| `Sources/OmniWM/Core/Ax/RunLoopJob.swift` | 2 | action → OSAllocatedUnfairLock |
| `Sources/OmniWM/Core/Input/Hotkeys.swift` | 2 | deinit calls stop() |
| `Sources/OmniWM/QuakeTerminal/QuakeTerminalController.swift` | 2 | passUnretained → passRetained |
| `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift` | 2 | cleanupEmptyColumn activeColumnIndex |
| `Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift` | 2 | singleWindowRect NaN guard |
| `Tests/OmniWMTests/AXEventHandlerTests.swift` | 1, 3 | Retry cap + guard scoping tests |
| `Tests/OmniWMTests/WakeRestoreTests.swift` | 3 | willSleep pre-arming test |

---

## Task 1: Restore Stabilization Retry Cap

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift`
- Test: `Tests/OmniWMTests/AXEventHandlerTests.swift`

- [ ] **Step 1: Write the failing test — retry cap exhaustion**

Add to `Tests/OmniWMTests/AXEventHandlerTests.swift` before the closing `}` of the test suite:

```swift
@Test @MainActor func stabilizationRetryExhaustsAfterThreeAttempts() {
    let controller = makeAXEventTestController()
    guard let workspaceId = controller.activeWorkspace()?.id else {
        Issue.record("Missing workspace setup")
        return
    }

    let pid: pid_t = 9_300
    let token = WindowToken(pid: pid, windowId: 930)

    // Window not tracked — candidateFailed disposition
    controller.axEventHandler.windowInfoProvider = { windowId in
        WindowServerInfo(id: windowId, pid: pid, level: 0, frame: .zero)
    }

    // Fire 5 create events (undecided → retry)
    for _ in 1...5 {
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 930, spaceId: 0)
        )
    }

    // Window should NOT be tracked (all attempts candidateFailed)
    #expect(controller.workspaceManager.entry(for: token) == nil)
}
```

- [ ] **Step 2: Run test to verify baseline**

Run: `swift test --filter AXEventHandlerTests/stabilizationRetryExhaustsAfterThreeAttempts 2>&1 | tail -5`

- [ ] **Step 3: Add retry count tracking to AXEventHandler**

In `Sources/OmniWM/Core/Controller/AXEventHandler.swift`:

After line 280 (`private static let stabilizationRetryDelay`), add:
```swift
private static let maxStabilizationRetries = 3
```

After line 302 (`private var pendingWindowStabilizationTasks`), add:
```swift
private var stabilizationRetryCount: [WindowToken: Int] = [:]
```

Replace `scheduleWindowStabilizationRetryIfNeeded` (lines 3013-3031) with:
```swift
private func scheduleWindowStabilizationRetryIfNeeded(
    token: WindowToken,
    decision: WindowDecision
) {
    guard decision.disposition == .undecided,
          decision.deferredReason != nil
    else {
        return
    }

    let count = (stabilizationRetryCount[token] ?? 0) + 1
    guard count <= Self.maxStabilizationRetries else {
        WMLog.ax.debug("stabilizationRetry: exhausted token=\(String(describing: token), privacy: .public) attempts=\(count - 1, privacy: .public)")
        stabilizationRetryCount.removeValue(forKey: token)
        return
    }
    stabilizationRetryCount[token] = count

    pendingWindowStabilizationTasks[token]?.cancel()
    pendingWindowStabilizationTasks[token] = Task { @MainActor [weak self] in
        try? await Task.sleep(for: Self.stabilizationRetryDelay)
        guard !Task.isCancelled, let self, let controller = self.controller else { return }
        self.pendingWindowStabilizationTasks.removeValue(forKey: token)
        _ = await controller.reevaluateWindowRules(for: [.window(token)])
    }
}
```

Replace `cancelWindowStabilizationRetry` (lines 3033-3035) with:
```swift
private func cancelWindowStabilizationRetry(for token: WindowToken) {
    pendingWindowStabilizationTasks.removeValue(forKey: token)?.cancel()
    stabilizationRetryCount.removeValue(forKey: token)
}
```

Replace `resetWindowStabilizationState` (lines 2077-2082) with:
```swift
func resetWindowStabilizationState() {
    for (_, task) in pendingWindowStabilizationTasks {
        task.cancel()
    }
    pendingWindowStabilizationTasks.removeAll()
    stabilizationRetryCount.removeAll()
}
```

- [ ] **Step 4: Build and run tests**

Run: `swift build 2>&1 | tail -5 && swift test --filter AXEventHandlerTests 2>&1 | tail -5`
Expected: Build succeeds, all 163+ tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/OmniWM/Core/Controller/AXEventHandler.swift Tests/OmniWMTests/AXEventHandlerTests.swift
git commit -m "fix: restore stabilization retry cap (max=3) from build 66

Restore stabilizationRetryCount dictionary and maxStabilizationRetries=3
that was lost during Phase 1-5 cherry-pick. Phase 4 classifier pre-filters
Chromium internals, retry cap limits survivors (NotificationCenter, other
undecided windows). Without the cap, 146 candidateFailed events per 25min."
```

---

## Task 2: SkyLight Guard Scoping + willSleep Pre-arming

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift`
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift`
- Test: `Tests/OmniWMTests/AXEventHandlerTests.swift`
- Test: `Tests/OmniWMTests/WakeRestoreTests.swift`

- [ ] **Step 1: Write failing test — guard allows destroy when not in wake/reconfig**

Add to `Tests/OmniWMTests/AXEventHandlerTests.swift`:

```swift
@Test @MainActor func destroySuppressedOnlyDuringWakeNotDuringNormalOperation() {
    let controller = makeAXEventTestController()
    guard let workspaceId = controller.activeWorkspace()?.id else {
        Issue.record("Missing workspace setup")
        return
    }

    let pid: pid_t = 9_400
    let token = WindowToken(pid: pid, windowId: 940)
    _ = controller.workspaceManager.addWindow(
        AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 940),
        pid: pid,
        windowId: 940,
        to: workspaceId
    )
    #expect(controller.workspaceManager.entry(for: token) != nil)

    // Window exists in window server (like a Ghostty tab)
    controller.axEventHandler.windowExistsInWindowServerForTests = { windowId in
        windowId == 940
    }

    // During NORMAL operation (wakePhase is .idle, isReconciling is false):
    // destroy should proceed even though window exists in window server
    controller.axEventHandler.cgsEventObserver(
        CGSEventObserver.shared,
        didReceive: .destroyed(windowId: 940, spaceId: 0)
    )

    // Window should be REMOVED (not suppressed)
    #expect(controller.workspaceManager.entry(for: token) == nil,
            "Destroy should proceed during normal operation even if window exists in window server")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AXEventHandlerTests/destroySuppressedOnlyDuringWakeNotDuringNormalOperation 2>&1 | tail -10`
Expected: FAIL — current unconditional guard suppresses the destroy

- [ ] **Step 3: Add `isAwaitingRestore` computed property to ServiceLifecycleManager**

In `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift`, after the `wakePhase` property (line 72), add:

```swift
var isAwaitingRestore: Bool {
    if case .awaitingRestore = wakePhase { return true }
    return false
}
```

- [ ] **Step 4: Pre-arm wakePhase in willSleep handler**

In the willSleep handler (around line 858), add the pre-arming line AFTER the existing snapshot logic and BEFORE the log statement. Change:

```swift
                WMLog.ax.info(
                    "systemSleep: snapshot monitors=\(self.sleepSnapshot?.outputIds.count ?? 0, privacy: .public) windows=\(self.sleepSnapshot?.windowRecords.count ?? 0, privacy: .public)"
                )
```

To:

```swift
                if let snapshot = self.sleepSnapshot {
                    self.wakePhase = .awaitingRestore(snapshot)
                }
                WMLog.ax.info(
                    "systemSleep: snapshot monitors=\(self.sleepSnapshot?.outputIds.count ?? 0, privacy: .public) windows=\(self.sleepSnapshot?.windowRecords.count ?? 0, privacy: .public)"
                )
```

- [ ] **Step 5: Scope the guard in handleCGSWindowDestroyed**

In `Sources/OmniWM/Core/Controller/AXEventHandler.swift`, replace the guard in `handleCGSWindowDestroyed` (lines 802-805):

From:
```swift
if windowExistsInWindowServer(windowId) {
    WMLog.ax.info("Window destroyed suppressed (still in window server): windowId=\(windowId, privacy: .public)")
    return
}
```

To:
```swift
let isInProtectedWindow = controller.workspaceManager.isReconciling ||
    controller.serviceLifecycleManager.isAwaitingRestore
if isInProtectedWindow, windowExistsInWindowServer(windowId) {
    WMLog.ax.info("Window destroyed suppressed (wake/reconfig, still in window server): windowId=\(windowId, privacy: .public)")
    return
}
```

- [ ] **Step 6: Scope the guard in replayManagedReplacementEvents**

In the same file, replace the guard in `replayManagedReplacementEvents` (lines 2527-2533):

From:
```swift
let windowId = UInt32(destroy.candidate.token.windowId)
if windowExistsInWindowServer(windowId) {
    WMLog.ax.info(
        "Deferred destroy suppressed (still in window server): windowId=\(windowId, privacy: .public)"
    )
    continue
}
```

To:
```swift
let windowId = UInt32(destroy.candidate.token.windowId)
let isInProtectedWindow = controller?.workspaceManager.isReconciling == true ||
    controller?.serviceLifecycleManager.isAwaitingRestore == true
if isInProtectedWindow, windowExistsInWindowServer(windowId) {
    WMLog.ax.info(
        "Deferred destroy suppressed (wake/reconfig, still in window server): windowId=\(windowId, privacy: .public)"
    )
    continue
}
```

- [ ] **Step 7: Run the failing test — should now pass**

Run: `swift test --filter AXEventHandlerTests/destroySuppressedOnlyDuringWakeNotDuringNormalOperation 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 8: Write test — guard still suppresses during wake**

Add to `Tests/OmniWMTests/AXEventHandlerTests.swift`:

```swift
@Test @MainActor func destroySuppressedDuringWakeWhenWindowExistsInWindowServer() {
    let controller = makeAXEventTestController()
    guard let workspaceId = controller.activeWorkspace()?.id else {
        Issue.record("Missing workspace setup")
        return
    }

    let pid: pid_t = 9_401
    let token = WindowToken(pid: pid, windowId: 941)
    _ = controller.workspaceManager.addWindow(
        AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 941),
        pid: pid,
        windowId: 941,
        to: workspaceId
    )

    controller.axEventHandler.windowExistsInWindowServerForTests = { windowId in
        windowId == 941
    }

    // Simulate wake state: set wakePhase to awaitingRestore
    let snapshot = controller.serviceLifecycleManager.captureStateSnapshot()!
    controller.serviceLifecycleManager.setWakePhaseForTests(.awaitingRestore(snapshot))

    controller.axEventHandler.cgsEventObserver(
        CGSEventObserver.shared,
        didReceive: .destroyed(windowId: 941, spaceId: 0)
    )

    // Window should be KEPT (suppressed during wake)
    #expect(controller.workspaceManager.entry(for: token) != nil,
            "Destroy should be suppressed during wake when window exists in window server")

    // Clean up
    controller.serviceLifecycleManager.setWakePhaseForTests(.idle)
}
```

- [ ] **Step 9: Run both guard tests**

Run: `swift test --filter "AXEventHandlerTests/destroySuppressed" 2>&1 | tail -10`
Expected: Both pass

- [ ] **Step 10: Write test — willSleep pre-arms wakePhase**

Add to `Tests/OmniWMTests/WakeRestoreTests.swift`:

```swift
@Test @MainActor func willSleepPreArmsWakePhaseForGuardProtection() {
    let defaults = makeWakeTestDefaults()
    let settings = SettingsStore(defaults: defaults)
    let controller = WMController(settings: settings)
    let slm = ServiceLifecycleManager(controller: controller)

    let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
    controller.workspaceManager.applyMonitorConfigurationChange([retina])

    // Before sleep: wakePhase is idle
    #expect(!slm.isAwaitingRestore)

    // Simulate sleep
    slm.simulateSleepForTests()

    // After sleep: wakePhase should be pre-armed
    #expect(slm.isAwaitingRestore, "willSleep should pre-arm wakePhase for guard protection")
}
```

- [ ] **Step 11: Run test**

Run: `swift test --filter WakeRestoreTests/willSleepPreArmsWakePhaseForGuardProtection 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 12: Run all wake + AXEventHandler tests**

Run: `swift test --filter "WakeRestoreTests|AXEventHandlerTests" 2>&1 | tail -10`
Expected: All pass (existing spuriousCGSDestroy test now verifies wake-scoped behavior)

Note: The existing `spuriousCGSDestroyIsSuppressedWhenWindowStillExistsInWindowServer` test may FAIL because it tests the unconditional guard without setting wake state. If so, update it to set wakePhase before the destroy:

```swift
let snapshot = controller.serviceLifecycleManager.captureStateSnapshot()!
controller.serviceLifecycleManager.setWakePhaseForTests(.awaitingRestore(snapshot))
```

And add cleanup: `controller.serviceLifecycleManager.setWakePhaseForTests(.idle)`

- [ ] **Step 13: Build full project**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 14: Commit**

```bash
git add Sources/OmniWM/Core/Controller/AXEventHandler.swift Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift Tests/OmniWMTests/AXEventHandlerTests.swift Tests/OmniWMTests/WakeRestoreTests.swift
git commit -m "fix(fix-c): scope SkyLight guard to wake+reconfig, pre-arm in willSleep

Change the unconditional SkyLight destroy guard to fire only when
isReconciling (display reconfig) OR isAwaitingRestore (wake window).

Pre-arm wakePhase in willSleep handler instead of startWakeReconciliation.
CGS events race with NSWorkspace.didWakeNotification — test 21 shows CGS
124ms BEFORE systemWake. Pre-arming closes this gap completely.

During normal operation, guard is OFF → Ghostty tab destroys proceed →
no phantom Niri columns (bug #20). During wake, guard is ON → spurious
CGS destroys suppressed → Fix C wake protection preserved.

New cross-component dependency: AXEventHandler reads
controller.serviceLifecycleManager.isAwaitingRestore."
```

---

## Task 3: Thread Safety + Crash Fixes

**Files:** 7 files (manual applies from backup/code-review-jun4 commit 69d324d)

- [ ] **Step 1: BorderWindow — nextStubWindowId atomic**

In `Sources/OmniWM/Core/Border/BorderWindow.swift`, add `import os` at top if not present.

Replace line 19:
```swift
nonisolated(unsafe) private static var nextStubWindowId: UInt32 = 90_000
```
With:
```swift
private static let nextStubWindowIdLock = OSAllocatedUnfairLock(initialState: UInt32(90_000))
```

Update the computed property that uses it (lines 21-25) to use the lock:
```swift
static var stubWindowId: UInt32 {
    nextStubWindowIdLock.withLock { value in
        value += 1
        return value
    }
}
```

- [ ] **Step 2: ScreenCoordinateSpace — 3 statics → OSAllocatedUnfairLock**

In `Sources/OmniWM/Core/Support/CGGeometry+Extensions.swift`, replace lines 67-69:
```swift
private nonisolated(unsafe) static var cachedTransforms: [ScreenTransform]?
private nonisolated(unsafe) static var cachedGlobalFrame: CGRect?
private nonisolated(unsafe) static var screenConfigurationToken: Int = 0
```
With:
```swift
private static let cache = OSAllocatedUnfairLock(initialState: (transforms: [ScreenTransform]?, globalFrame: CGRect?, configToken: Int(0)))
```

Update all read/write sites to use `cache.withLock { state in ... }`. Read the build 66 diff (commit 69d324d) for exact call sites.

- [ ] **Step 3: RunLoopJob — action → OSAllocatedUnfairLock**

In `Sources/OmniWM/Core/Ax/RunLoopJob.swift`, replace line 6:
```swift
nonisolated(unsafe) weak var action: RunLoopAction?
```
With a thread-safe accessor using OSAllocatedUnfairLock. Read commit 69d324d for the exact pattern.

- [ ] **Step 4: HotkeyCenter — deinit calls stop()**

In `Sources/OmniWM/Core/Input/Hotkeys.swift`, replace the deinit (line 288) to call `stop()` instead of partial cleanup:
```swift
deinit {
    stop()
}
```

- [ ] **Step 5: QuakeTerminal — passUnretained → passRetained**

In `Sources/OmniWM/QuakeTerminal/QuakeTerminalController.swift`, replace line 104:
```swift
runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
```
With:
```swift
runtimeConfig.userdata = Unmanaged.passRetained(self).toOpaque()
```

And update the callback sites (lines 109, 117, 137, 144) from `takeUnretainedValue()` to `takeRetainedValue()`.

- [ ] **Step 6: Build and test**

Run: `swift build 2>&1 | tail -5 && swift test --filter "AXEventHandlerTests|WakeRestoreTests" 2>&1 | tail -5`
Expected: Build succeeds, all tests pass

- [ ] **Step 7: Commit**

```bash
git add Sources/OmniWM/Core/Border/BorderWindow.swift Sources/OmniWM/Core/Support/CGGeometry+Extensions.swift Sources/OmniWM/Core/Ax/RunLoopJob.swift Sources/OmniWM/Core/Input/Hotkeys.swift Sources/OmniWM/QuakeTerminal/QuakeTerminalController.swift
git commit -m "fix: thread safety + crash fixes from build 68 code review

Manual apply from backup/code-review-jun4 (commit 69d324d):
- BorderWindow.nextStubWindowId: OSAllocatedUnfairLock
- ScreenCoordinateSpace: 3 statics wrapped in OSAllocatedUnfairLock
- RunLoopJob.action: thread-safe accessor
- HotkeyCenter: deinit calls stop() (crash fix)
- QuakeTerminal: passUnretained → passRetained (memory fix)"
```

---

## Task 4: Layout Fixes (cleanupEmptyColumn + Dwindle NaN)

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift`
- Modify: `Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift`

- [ ] **Step 1: Fix cleanupEmptyColumn activeColumnIndex**

In `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift`, replace `cleanupEmptyColumn` (lines 209-218):

```swift
func cleanupEmptyColumn(
    _ column: NiriContainer,
    in workspaceId: WorkspaceDescriptor.ID,
    state: inout ViewportState
) {
    guard column.children.isEmpty else { return }

    let removedIndex = columnIndex(of: column, in: workspaceId)

    column.remove()

    if let removedIndex {
        let newCount = columns(in: workspaceId).count
        if newCount == 0 {
            state.activeColumnIndex = 0
        } else if removedIndex < state.activeColumnIndex {
            state.activeColumnIndex -= 1
        } else if state.activeColumnIndex >= newCount {
            state.activeColumnIndex = newCount - 1
        }
    }
}
```

- [ ] **Step 2: Fix Dwindle singleWindowRect NaN guard**

In `Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift`, find `singleWindowRect(screen:)` and replace the ratio calculation:

From:
```swift
private func singleWindowRect(screen: CGRect) -> CGRect {
    let targetRatio = settings.singleWindowAspectRatio.width / settings.singleWindowAspectRatio.height
```

To:
```swift
private func singleWindowRect(screen: CGRect) -> CGRect {
    guard screen.width >= 1, screen.height >= 1 else { return screen }
    let aspectHeight = max(settings.singleWindowAspectRatio.height, 1)
    let targetRatio = settings.singleWindowAspectRatio.width / aspectHeight
    guard targetRatio.isFinite, targetRatio > 0 else { return screen }
```

- [ ] **Step 3: Build and test**

Run: `swift build 2>&1 | tail -5 && swift test --filter "AXEventHandlerTests|WakeRestoreTests" 2>&1 | tail -5`
Expected: Build succeeds, all tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift
git commit -m "fix: cleanupEmptyColumn activeColumnIndex + Dwindle NaN guard

Manual apply from backup/code-review-jun4 (commit 69d324d):
- cleanupEmptyColumn: adjust activeColumnIndex after column removal (bug #13)
- singleWindowRect: guard against NaN from zero-size aspect ratio (bug #5)"
```

---

## Task 5: Catalog Poisoning Fix

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/WMController.swift`
- Modify: `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift`

- [ ] **Step 1: Fix transitionWindowMode floating→tiling**

In `Sources/OmniWM/Core/Controller/WMController.swift`, in `transitionWindowMode`, find the floating→tiling transition (around line 1815-1822). Change `restoreToFloating: true` to `restoreToFloating: false` in both the `updateFloatingGeometry` call AND the `floatingState.restoreToFloating` assignment:

From:
```swift
                workspaceManager.updateFloatingGeometry(
                    frame: currentFrame,
                    for: token,
                    referenceMonitor: referenceMonitor,
                    restoreToFloating: true
                )
            } else if var floatingState = workspaceManager.floatingState(for: token) {
                floatingState.restoreToFloating = true
                workspaceManager.setFloatingState(floatingState, for: token)
            }
```

To:
```swift
                workspaceManager.updateFloatingGeometry(
                    frame: currentFrame,
                    for: token,
                    referenceMonitor: referenceMonitor,
                    restoreToFloating: false
                )
            } else if var floatingState = workspaceManager.floatingState(for: token) {
                floatingState.restoreToFloating = false
                workspaceManager.setFloatingState(floatingState, for: token)
            }
```

- [ ] **Step 2: Fix setWindowMode — clear restoreToFloating on tiling**

In `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift`, in `setWindowMode` (line ~2511), add after `windows.setMode(mode, for: token)`:

```swift
if mode == .tiling, var floatingState = windows.floatingState(for: token),
   floatingState.restoreToFloating
{
    floatingState.restoreToFloating = false
    windows.setFloatingState(floatingState, for: token)
}
```

- [ ] **Step 3: Build and test**

Run: `swift build 2>&1 | tail -5 && swift test --filter "AXEventHandlerTests|WakeRestoreTests" 2>&1 | tail -5`
Expected: Build succeeds, all tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/OmniWM/Core/Controller/WMController.swift Sources/OmniWM/Core/Workspace/WorkspaceManager.swift
git commit -m "fix: catalog poisoning — clear restoreToFloating on tiling transition (bugs #16/#27/#28)

Manual apply from backup/code-review-jun4 (commit 49eb0df):
- transitionWindowMode floating→tiling: set restoreToFloating=false
- setWindowMode(.tiling): clear restoreToFloating as safety net
Breaks the self-perpetuating cycle: startup→floating→catalog poison→restart→repeat."
```

---

## Task 6: Version Bump + Full Verification

- [ ] **Step 1: Bump build to 81**

In `Info.plist`, change `<string>80</string>` to `<string>81</string>` under `CFBundleVersion`.

- [ ] **Step 2: Run all wake-related tests**

Run: `swift test --filter "WakeRestoreTests|AXEventHandlerTests|ServiceLifecycleManagerTests|SleepWakeSnapshotTests" 2>&1 | tail -20`
Expected: All pass

- [ ] **Step 3: Build debug**

Run: `swift build -c debug 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Info.plist
git commit -m "chore: bump build to 81"
```

- [ ] **Step 5: Deploy for live testing**

```bash
pkill OmniWM
nohup .build/debug/OmniWM > /dev/null 2>&1 &
sleep 2
pgrep -l OmniWM
pkill -f "omniwmctl watch"
nohup /Applications/OmniWM.app/Contents/MacOS/omniwmctl watch --all --exec sketchybar --trigger omniwm_workspace_changed > /dev/null 2>&1 &
omniwmctl ping && omniwmctl query windows | head -5
```

- [ ] **Step 6: Live test — Ghostty tabs**

Navigate Hyper+H/L through Ghostty with multiple tabs. Verify no phantom columns appear.

- [ ] **Step 7: Live test — sleep/wake**

Let Mac sleep naturally. After wake, pull logs:
```bash
command log show --predicate 'subsystem == "com.omniwm"' --last 120s --style compact --info --debug | grep -E "tick=|finalize|reassigned|remapped|focus restored|destroyed suppressed|candidateFailed"
```

Verify: Fix C still works (0 reassigned, focus restored), reduced candidateFailed count, minimal destroy suppressed.
