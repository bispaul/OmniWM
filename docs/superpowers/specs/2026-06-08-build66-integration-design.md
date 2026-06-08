# Build 66 Integration + SkyLight Guard Scoping — Design Spec

## Problem

Post-Phase 1-5 log analysis (test 21, build 80) shows three categories of issues caused by lost/missing mechanisms:

| Issue | Count (25min) | Root Cause |
|-------|---------------|------------|
| candidateFailed events | 146 | stabilizationRetryCount removed during Phase 1-5 |
| Destroy suppressed (incl. 53 for own border window) | 146 | SkyLight guard is unconditional — suppresses tab/border destroys too |
| Ghostty phantom Niri columns (bug #20) | ongoing | SkyLight guard prevents tab window cleanup |

Additionally, safety fixes from backup/code-review-jun4 (builds 67-70) were reverted as a batch but the individual fixes were sound.

## Scope

Three work streams, designed as one cohesive change:

1. **Restore stabilization retry cap** — bring back maxStabilizationRetries=3 from build 66
2. **Selective cherry-picks** — thread safety, crash fixes, catalog poisoning from backup/code-review-jun4
3. **SkyLight guard scoping** — pre-arm in willSleep, scope to wake+reconfig windows only

**Revertibility:** Streams are independently revertible. Stream 1 (retry cap) is self-contained in `scheduleWindowStabilizationRetryIfNeeded`. Stream 2 (cherry-picks) are isolated per-file fixes. Stream 3 (guard scoping) is the only one touching the guard logic. If Stream 3 causes a wake regression, revert it by restoring the unconditional guard — Streams 1 and 2 are unaffected.

## Architecture

### Stream 1: Restore Stabilization Retry Cap

Build 66 (commit 4e85d94) had `stabilizationRetryCount: [WindowToken: Int]` with `maxStabilizationRetries = 3`. Phase 4 classifier pre-filters Chromium internals. The retry cap limits survivors (NotificationCenter, other undecided-disposition windows).

Both mechanisms are complementary at different layers:
- Phase 4 classifier: reject BEFORE AX resolution (cheap)
- Retry cap: limit retries AFTER AX resolution fails (prevents storm)

**Changes in AXEventHandler.swift:**
- Restore `private var stabilizationRetryCount: [WindowToken: Int] = [:]`
- Restore `private static let maxStabilizationRetries = 3`
- In `scheduleWindowStabilizationRetryIfNeeded`: count tracking + guard at max
- In `cancelWindowStabilizationRetry`: clean up count
- In `resetWindowStabilizationState`: clean up count dictionary

### Stream 2: Selective Manual Applies

From backup/code-review-jun4 commit 69d324d (build 68) and 49eb0df (build 69).

**IMPORTANT: Do NOT `git cherry-pick` these commits.** They are large multi-fix commits that will conflict with Phase 1-5 changes. Instead, **manually apply each fix** by reading the diff hunks and applying them to the current code.

| Fix | Source | File | Risk | Phase 1-5 Interaction |
|-----|--------|------|------|----------------------|
| ScreenCoordinateSpace: 3 statics → OSAllocatedUnfairLock | 69d324d | `Sources/OmniWM/Core/Geometry/CGGeometry+Extensions.swift` | LOW | None — pure concurrency |
| RunLoopJob.action: OSAllocatedUnfairLock | 69d324d | `Sources/OmniWM/Core/Support/Thread+RunLoop.swift` | LOW | None |
| MouseEventHandler: CGEventTap callback → main dispatch | 69d324d | `Sources/OmniWM/Core/Controller/MouseEventHandler.swift` | LOW | None |
| SecureInputMonitor: wrap `sharedMonitor` static in OSAllocatedUnfairLock | 69d324d | `Sources/OmniWM/Core/Controller/SecureInputMonitor.swift` | LOW | None — the issue is the static, not the callback |
| BorderWindow.nextStubWindowId: OSAllocatedUnfairLock | 69d324d | `Sources/OmniWM/Core/Border/BorderWindow.swift` | LOW | None |
| HotkeyCenter: deinit calls `stop()` (adds `unregisterAll` + `RemoveEventHandler`) | 69d324d | `Sources/OmniWM/Hotkeys/Hotkeys.swift` | LOW | Crash fix — current deinit only calls partial cleanup |
| QuakeTerminal: passUnretained → passRetained for GhosttyKit callbacks | 69d324d | `Sources/OmniWM/QuakeTerminal/QuakeTerminalController.swift` | LOW | Memory fix |
| cleanupEmptyColumn: adjust activeColumnIndex after removal (bug #13) | 69d324d | `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift` | MEDIUM | Niri state — could affect column selection after close |
| Dwindle: guard singleWindowRect against NaN from zero-size (bug #5) | 69d324d | `Sources/OmniWM/Core/Layout/Dwindle/DwindleNode.swift` | LOW | Layout guard |
| Catalog poisoning: `transitionWindowMode` floating→tiling sets `restoreToFloating=false` | 49eb0df | `Sources/OmniWM/Core/Controller/WMController.swift` (line ~1819) | MEDIUM | Only the **floating→tiling** direction. Tiling→floating keeps `restoreToFloating=true` (correct). |
| Catalog poisoning: `setWindowMode(.tiling)` clears `restoreToFloating` | 49eb0df | `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift` | MEDIUM | Safety net for all code paths that transition to tiling |

**IMPORTANT for 49eb0df:** This commit also contains the verificationMismatch cooldown (bug #29) and miniaturize Task cancellation (bug #31). Apply ONLY the restoreToFloating hunks. Skip the cooldown and miniaturize changes.

**DO NOT cherry-pick:**
- verificationMismatch cooldown (bug #29) — Phase 1b deliberately removed all cooldowns. Accept-and-adapt handles the functional impact.
- Cooldown force-apply fix (build 70) — only needed if cooldown cherry-picked.

### Stream 3: SkyLight Guard Scoping

#### Root Cause of Bug #20

The unconditional SkyLight guard in `handleCGSWindowDestroyed` suppresses ALL CGS destroy events when `windowExistsInWindowServer(windowId)` returns true. This is correct for wake (spurious destroys while windows are alive) but incorrect for:
- Ghostty tab switches (hidden tab windows exist but should be removed from tracking)
- OmniWM's own border windows (create/destroy cycling)

#### Why Previous Conditional Guard Failed

Commit 0f94b6f used `isReconciling` to scope the guard. `isReconciling` only covers the synchronous `applyMonitorConfigurationChanged` call (~50ms). CGS spurious destroys fire during the progressive ticks (seconds later), when `isReconciling` is already false.

**Why `isReconciling` DOES work for display disconnect (but not wake):** Display-reconfig CGS destroys fire synchronously during `applyMonitorConfigurationChanged` while `isReconciling=true`. Wake CGS destroys fire progressively over 15-18 seconds, long after `isReconciling` has been cleared. Different event delivery patterns require different temporal scopes.

#### Why isOnScreen Won't Work

During wake, macOS disconnects displays → windows become off-screen → CGS fires destroys. Both wake windows and Ghostty tabs are off-screen. Indistinguishable by visibility.

#### Solution: Pre-arm Guard in willSleep

`wakePhase` (added by Fix C) covers the exact 15-18 second wake window. But the guard must be armed BEFORE systemWake because CGS events can fire before the didWakeNotification.

**Evidence from 3 sleep/wake tests:**

| Test | CGS events vs systemWake | Timing |
|------|--------------------------|--------|
| Test 16 | 117ms AFTER | Safe with didWake arming |
| Test 20 | 145ms AFTER | Safe with didWake arming |
| Test 21 | 124ms BEFORE | **RACE — would fail with didWake arming** |

The race is a macOS run loop scheduling issue — which notification (NSWorkspace vs CGS) gets processed first is non-deterministic.

**Fix: set wakePhase in willSleep, not in startWakeReconciliation.**

The actual willSleep handler has two code paths:
```swift
// Path A: normal sleep (wakePhase == .idle)
if sleepSnapshot == nil {
    sleepSnapshot = captureStateSnapshot()
}

// Path B: re-entrant sleep (wake was in progress)
wakePhase = .idle
sleepSnapshot = captureStateSnapshot()
```

Add pre-arming AFTER both paths:
```swift
// NEW — pre-arm guard for wake protection
if let snapshot = self.sleepSnapshot {
    self.wakePhase = .awaitingRestore(snapshot)
}
```

This uses `self.sleepSnapshot` (the stored snapshot from whichever path executed), not a local variable.

Guard becomes:
```swift
let isInProtectedWindow =
    controller.workspaceManager.isReconciling ||
    controller.serviceLifecycleManager.isAwaitingRestore

if isInProtectedWindow && windowExistsInWindowServer(windowId) {
    suppress
}
```

Add `var isAwaitingRestore: Bool` computed property on ServiceLifecycleManager. This is a **new cross-component dependency** — AXEventHandler now accesses `controller.serviceLifecycleManager` (previously it only accessed `controller.workspaceManager`).

Update **two** guard sites: `handleCGSWindowDestroyed` (line ~800) and `replayManagedReplacementEvents` (line ~2527). A third `windowExistsInWindowServer` call exists in `flushManagedReplacementBurst` (~line 2491) — this is for create/destroy pair matching, NOT suppression, so it does NOT need the guard.

**Note:** `startWakeReconciliation` currently sets `wakePhase = .awaitingRestore(snapshot)` at line 426. With willSleep pre-arming, this is redundant but idempotent — keep it as a safety net for the edge case where didWake fires without a prior willSleep (e.g., after a crash restart during sleep).

#### Timeline with Fix

```
willSleep → capture snapshot → wakePhase = .awaitingRestore (guard ON)
  ↓
System sleeps (no events — harmless; DarkWake events also suppressed — acceptable,
  DarkWake has no real user window events, just system maintenance)
  ↓
CGS early destroys (may fire before systemWake) → guard ON → suppressed ✅
  ↓
systemWake → startWakeReconciliation (wakePhase already armed)
  ↓
Ticks 1-5 + finalization → guard ON → wake protection ✅
  ↓
executeFinalRestore end → wakePhase = .idle (guard OFF)
  ↓
Normal operation → tab/border destroys proceed → no phantom columns ✅
```

#### Edge Cases

| Case | Behavior | Safe? |
|------|----------|-------|
| DarkWake timeout (30s) | wakePhase → .idle, guard OFF | ✅ |
| DarkWake Power Nap events during sleep | Guard ON, events suppressed. No user windows involved in Power Nap. | ✅ (acceptable) |
| Re-entrant sleep (wake in progress) | Recapture snapshot, re-arm | ✅ |
| Power loss during sleep | Fresh boot, wakePhase initializes .idle | ✅ |
| Tab switch during 15-18s wake window | Suppressed (guard ON). After `wakePhase = .idle`, next AX event cycle or user interaction triggers the WM to re-evaluate windows. Stale tab entries are not harmful — they're orphaned nodes that get cleaned up on the next relayout or window create/destroy cycle. Accepted risk for 15-18s window. | ✅ (acceptable) |
| Display disconnect (no wake) | isReconciling = true during synchronous applyMonitorConfigurationChanged. Guard ON for ~50ms. | ✅ |
| Border windows during wake | Border windows may churn during wake relayouts. Guard suppresses their destroys during wake. After wake, border window lifecycle resumes normally. No functional impact — borders are visual-only. | ✅ (acceptable) |

## Phase 1-5 + ABC Compatibility

| Phase/Fix | Interaction | Compatible? |
|-----------|-------------|-------------|
| Phase 1 (accept-and-adapt) | Retry cap is admission layer, not frame writes | ✅ |
| Phase 2 (dirty reflow) | No interaction | ✅ |
| Phase 3 (viewport pipeline) | No interaction | ✅ |
| Phase 4 (classifier) | Complementary — classifier pre-filters, cap limits survivors | ✅ |
| Phase 5 (reconciliation) | Guard uses existing isReconciling + wakePhase | ✅ |
| Fix A (atomic transfer) | Transfer bypasses destroy path | ✅ |
| Fix B (display eligibility) | About admission, not destruction | ✅ |
| Fix C (sleep/wake restore) | Guard scoped to wakePhase — covers exact wake window | ✅ |
| Fix D (viewport scoping) | Guard is event-layer, Fix D is layout-layer | ✅ |

## Expected Outcomes

| Metric | Before | After |
|--------|--------|-------|
| candidateFailed (25min) | 146 | ~15-20 (capped at 3 retries/token) |
| Destroy suppressed (normal operation) | 146 | ~0 (only during wake/reconfig) |
| Border window destroy storm | 53 | 0 |
| Ghostty phantom columns | ongoing | Fixed |
| Thread safety data races | 6 (ScreenCoordinateSpace ×3, RunLoopJob, MouseEventHandler, SecureInputMonitor + BorderWindow) | 0 |
| Crash/memory risks (HotkeyCenter deinit, QuakeTerminal passRetained) | 2 | 0 |
| Catalog poisoning (restart→floating) | ongoing | Fixed |

## Test Plan

1. **Unit:** Retry cap test (exhaustion at 3), guard scoping test (mock wakePhase + isReconciling)
2. **Build:** `swift build`
3. **Filtered:** `swift test --filter "WakeRestoreTests|AXEventHandlerTests"`
4. **Live sleep/wake:** Verify Fix C still works with scoped guard
5. **Live Ghostty tabs:** Verify phantom columns gone during normal operation
6. **Log analysis:** Verify reduced candidateFailed + destroy suppressed counts

## Files Changed

| File | Stream | Changes |
|------|--------|---------|
| `Sources/OmniWM/Core/Controller/AXEventHandler.swift` | 1, 3 | Retry cap restore + guard scoping (new dependency on serviceLifecycleManager) |
| `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` | 3 | `isAwaitingRestore` computed property + willSleep pre-arming |
| `Sources/OmniWM/Core/Controller/WMController.swift` | 2 | Catalog poisoning: `transitionWindowMode` floating→tiling `restoreToFloating=false` |
| `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift` | 2 | Catalog poisoning: `setWindowMode(.tiling)` clears `restoreToFloating` |
| `Sources/OmniWM/Core/Geometry/CGGeometry+Extensions.swift` | 2 | ScreenCoordinateSpace: 3 statics → OSAllocatedUnfairLock |
| `Sources/OmniWM/Core/Support/Thread+RunLoop.swift` | 2 | RunLoopJob.action: OSAllocatedUnfairLock |
| `Sources/OmniWM/Core/Controller/MouseEventHandler.swift` | 2 | CGEventTap callback → main dispatch |
| `Sources/OmniWM/Core/Controller/SecureInputMonitor.swift` | 2 | `sharedMonitor` static → OSAllocatedUnfairLock |
| `Sources/OmniWM/Core/Border/BorderWindow.swift` | 2 | nextStubWindowId: OSAllocatedUnfairLock |
| `Sources/OmniWM/Hotkeys/Hotkeys.swift` | 2 | deinit calls `stop()` (adds unregisterAll + RemoveEventHandler) |
| `Sources/OmniWM/QuakeTerminal/QuakeTerminalController.swift` | 2 | passUnretained → passRetained |
| `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift` | 2 | cleanupEmptyColumn activeColumnIndex adjustment (bug #13) |
| `Sources/OmniWM/Core/Layout/Dwindle/DwindleNode.swift` | 2 | NaN guard for zero-size Fill Screen (bug #5) |
| `Tests/OmniWMTests/WakeRestoreTests.swift` | 3 | Guard scoping tests |
| `Tests/OmniWMTests/AXEventHandlerTests.swift` | 1 | Retry cap tests |
