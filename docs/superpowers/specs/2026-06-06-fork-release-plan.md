# Fork Release Plan — Systemic Fixes + Rename

**Date:** 2026-06-06
**Status:** Spec
**Replaces:** Individual bug tickets — this addresses root causes, not symptoms
**Prerequisite:** Phases 1-5 of holistic architecture overhaul (builds 72-76, complete)

## Background

12 open bugs cluster around 4 systemic root causes. Fixing the roots eliminates the bugs as side effects. AeroSpace has the exact same core issue (mutable tree + remove/readmit = windows randomly jump, [issue #1216](https://github.com/nikitabobko/AeroSpace/issues/1216)) and is planning a full immutable tree rewrite. We can achieve the same stability with targeted routing fixes because Hiro already has the move-in-place primitives — they're just not used consistently.

## Fix A: Atomic Window Transfer

**Root cause:** Cross-workspace move, fullscreen toggle, and sleep/wake all use remove→readmit, creating intermediate state where the window is "nowhere." Event handlers see this torn state and produce cascading side effects (z-order loss, column position loss, focus confusion).

**Bugs eliminated:** #4 (z-order after transition), cross-workspace window drop, Ghostty z-order on cross-monitor move, VSCode fullscreen column loss.

### Design

**New method on WorkspaceManager:**
```swift
func transferWindow(
    _ token: WindowToken,
    from sourceWorkspaceId: WorkspaceDescriptor.ID,
    to targetWorkspaceId: WorkspaceDescriptor.ID,
    columnIndex: Int? = nil
) -> Bool
```

This single synchronous method:
1. Validates both workspaces exist and token is in source
2. Updates `windows` registry (one dictionary write — `entry.workspaceId = target`)
3. Calls `engine.moveWindowToWorkspace(token, from:, to:, atIndex: columnIndex)` which moves the node in the tree without remove+insert
4. Preserves z-order by NOT removing/re-adding the AX subscription
5. Returns success/failure

**Callers that change from remove+readmit to transfer:**

1. **WorkspaceNavigationHandler.transferWindowFromSourceEngine** (line ~500): Currently calls `engine.removeWindow` for cross-layout transfers. Change to: if both workspaces use the same engine, call `transferWindow`. If different engines (Niri→Dwindle), use the existing remove path but with the fullscreen restore map from Phase 5b.

2. **WorkspaceNavigationHandler.moveWindowToAdjacentWorkspace** (line ~560): Currently calls `reassignManagedWindow` which is a registry-only update. Change to: call `transferWindow` which does registry + engine in one step.

3. **WorkspaceNavigationHandler.moveWindowToWorkspaceOnMonitor** (line ~857): Same pattern — use `transferWindow`.

4. **Fullscreen transition path**: Instead of removing window from engine on fullscreen enter, mark it as `layoutReason = .nativeFullscreen` in-place (already done). On fullscreen exit, the window is STILL in the engine (never removed), just needs a relayout. Phase 5b's `fullscreenRestorePositions` becomes unnecessary — the window never left.

**AXRaise after transfer:** Call `performWindowFronting` AFTER the layout refresh applies the new frame, not in the completion block where the frame hasn't been written yet. The `commitWorkspaceTransition` completion block should run after `executeLayoutPlan` has applied frames.

### What changes in the engine

`NiriLayoutEngine.moveWindowToWorkspace` already exists (NiriLayoutEngine+WorkspaceOps.swift:59). It transfers a column from one workspace's column list to another. Verify it preserves:
- Column width (`cachedWidth`)
- Window node properties
- Tab state (if column is tabbed)

Add `moveWindowToWorkspace(token:, from:, to:, atColumnIndex:)` overload that accepts a target column index for ordered insertion.

### Failure modes

If the transfer method encounters an inconsistency (token not in source, target workspace deleted), return false and log. Callers fall back to the existing remove+readmit path. This ensures the new path is fail-safe.

---

## Fix B: Display Eligibility

**Root cause:** `renderEligibility` in the border/focus system checks `AXWindowService.isFullscreen` which returns true for any window whose frame matches the display bounds. On a 27" portrait display, many apps (Slack, VSCode) fill the display without being in native macOS fullscreen.

**Bugs eliminated:** Slack false appFullscreen, VSCode false appFullscreen, border suppression for any maximized app.

### Design

**Distinguish 3 window display states:**
```swift
enum WindowDisplayState {
    case normal
    case maximized      // fills display bounds, same macOS Space
    case nativeFullscreen  // separate macOS Space
}
```

**Detection using CGS space type:**
```swift
static func windowDisplayState(windowId: Int) -> WindowDisplayState {
    let conn = CGSMainConnectionID()
    var spaces = [CGSSpaceID]()
    // Get spaces containing this window
    CGSGetWindowWorkspaces(conn, CGWindowID(windowId), &spaces)
    
    for spaceId in spaces {
        let spaceType = CGSSpaceGetType(conn, spaceId)
        if spaceType == 4 { // kCGSSpaceFullscreen
            return .nativeFullscreen
        }
    }
    return .normal // or .maximized if frame == display bounds
}
```

**Fallback:** If CGS calls fail (SIP restrictions, API changes), fall back to current `isFullscreen` check. Log a warning so we know when the fallback activates.

**Integration:** In `FocusBorderController.renderEligibility`, replace:
```swift
// Before:
if isAppFullscreen { return .hide(reason: .appFullscreen) }

// After:
if windowDisplayState(windowId:) == .nativeFullscreen { return .hide(reason: .appFullscreen) }
```

### Verification

Check that `CGSGetWindowWorkspaces` and `CGSSpaceGetType` are available in the SkyLight module that Hiro already uses. If not, add the function declarations to the existing SkyLight bridge.

---

## Fix C: Sleep/Wake Snapshot Restore

**Root cause:** On wake, Hiro does `requestFullRescan(reason: .unlock)` which rediscovers all windows from scratch — losing column widths, workspace assignments, z-order, and triggering 14+ redundant rescans via DarkWake events.

**Bugs eliminated:** Sleep/wake wrong monitor, DarkWake readmission storm, column width loss, Chrome too small after rescue.

### Design

**State snapshot on sleep:**
```swift
struct SleepStateSnapshot {
    let monitorIds: Set<Monitor.ID>
    let windowStates: [WindowToken: WindowSnapshotEntry]
    let workspaceViewportStates: [WorkspaceDescriptor.ID: ViewportState]
    let focusedToken: WindowToken?
    let timestamp: Date
}

struct WindowSnapshotEntry {
    let workspaceId: WorkspaceDescriptor.ID
    let columnIndex: Int
    let cachedWidth: CGFloat
    let mode: TrackedWindowMode
    let frame: CGRect
}
```

**Sleep handler** (ServiceLifecycleManager):
```swift
// On NSWorkspace.willSleepNotification:
sleepSnapshot = captureStateSnapshot()
```

**Wake handler** (replaces Phase 5d's progressive polling):
```swift
// On NSWorkspace.didWakeNotification:
startWakeReconciliation()

func startWakeReconciliation() {
    isReconciling = true
    // Phase 5d progressive polling (already implemented)
    // Once monitors are ready:
    
    if monitorSetMatches(sleepSnapshot.monitorIds) {
        // Same monitors: restore from snapshot
        restoreFromSnapshot(sleepSnapshot)
        // Targeted validation: check each window still exists
        validateRestoredWindows()
    } else {
        // Different monitors: use topology restoration (existing)
        applyMonitorConfigurationChanged(currentMonitors: Monitor.current())
    }
    
    isReconciling = false
    sleepSnapshot = nil
}
```

**Targeted validation after restore:**
Instead of full rescan, iterate over restored windows and check AX reachability:
```swift
func validateRestoredWindows() {
    for (token, _) in sleepSnapshot.windowStates {
        if !isWindowStillAlive(token) {
            removeWindow(token) // clean removal of dead windows only
        }
    }
}
```

### DarkWake suppression

DarkWake events (Power Nap, background refresh) fire `didWakeNotification` without actual user wake. Detect via `IOPMAssertionDeclareUserActivity` or check if displays are actually on. If DarkWake, skip reconciliation entirely.

---

## Fix D: Monitor Adjacency Configuration

**Root cause:** Geometric inference for "adjacent monitor in direction X" breaks with non-rectangular monitor arrangements (portrait left + landscape above + laptop below).

**Bugs eliminated:** Focus right jumps to wrong monitor, viewport gaps on cross-monitor focus.

### Design

**New settings.toml section:**
```toml
[[monitor-adjacency]]
name = "Built-in Retina Display"
up = "U32J59x"
left = "S27R65x"

[[monitor-adjacency]]
name = "U32J59x"
down = "Built-in Retina Display"

[[monitor-adjacency]]
name = "S27R65x"
right = "Built-in Retina Display"
```

**Resolution order:**
1. Explicit adjacency from config (if defined for this monitor + direction)
2. Geometric inference (current behavior, as fallback)

**Integration:** `WorkspaceManager.adjacentMonitor(from:direction:)` checks explicit config first. Existing callers don't change — they already use this method.

### Viewport gap fix

The viewport gap on cross-monitor focus is partially a separate issue (viewport pipeline not running for cross-monitor focus transitions). The Phase 3 viewport pipeline's `applyPolicies` gate should include cross-monitor transitions: when focus moves to a different monitor, the pipeline should run with `applyPolicies = true` to ensure the viewport is correctly positioned.

---

## Fix E: Rename + Release Prep

**From:** OmniWM / Hiro
**To:** TBD (user chooses name)

### Checklist
- Bundle identifier: `com.barut.OmniWM` → `com.bispaul.<NewName>`
- IPC socket: `~/Library/Caches/com.barut.OmniWM/ipc.sock` → new path
- Binary names: `OmniWM` → `<NewName>`, `omniwmctl` → `<newname>ctl`
- Settings file: `settings.toml` (can keep, it's user-facing)
- Log subsystem: `com.omniwm` → `com.bispaul.<newname>`
- SketchyBar plugin: update `OMNIWM.CTL_PATH` and event names
- AGENTS.md, README, UI strings, About dialog
- Remove upstream-specific code: updater (checks BarutSRB releases), release notes viewer
- GhosttyKit: keep as pre-built binary dependency (same setup)
- App icon: keep or create new
- Code signing: ad-hoc for personal use, or Developer ID for distribution

---

## Implementation Order

| Phase | Fix | Complexity | Bugs killed | Session estimate |
|-------|-----|-----------|-------------|-----------------|
| **A** | Atomic Window Transfer | Medium | 4 | 1 session |
| **B** | Display Eligibility | Low | 3 | 0.5 session |
| **C** | Sleep/Wake Snapshot | High | 4 | 1-2 sessions |
| **D** | Monitor Adjacency | Low | 2 | 0.5 session |
| **E** | Rename + Release | Medium | 0 | 1 session |

**Total: ~4-5 sessions to release-ready.** From 12 open bugs to 0-1.

## Success Criteria

- Zero window loss during workspace switching (Fix A)
- Borders visible on all tiled windows regardless of window size (Fix B)
- Sleep/wake restores exact window layout within 2 seconds (Fix C)
- Directional focus navigation respects physical monitor arrangement (Fix D)
- Clean fork identity with no upstream references (Fix E)
- All existing tests pass + new tests per fix
- 24 hours of daily-driver use with zero manual Hiro restarts needed
