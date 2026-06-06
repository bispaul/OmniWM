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

1. **WorkspaceNavigationHandler.transferWindowFromSourceEngine** (line ~500): Currently calls `engine.removeWindow` for cross-layout transfers. Change to: if both workspaces use the same engine AND the window is the only window in its column, call `transferWindow`. If different engines (Niri→Dwindle), or if the window is in a tabbed column with other windows, use the existing remove path with Phase 5b's fullscreen restore map.

2. **WorkspaceNavigationHandler.moveWindowToAdjacentWorkspace** (line ~560): Currently calls `reassignManagedWindow` which is a registry-only update. Change to: call `transferWindow` which does registry + engine in one step.

3. **WorkspaceNavigationHandler.moveWindowToWorkspaceOnMonitor** (line ~857): Same pattern — use `transferWindow`.

4. **Fullscreen transition path**: Keep current behavior — remove from engine on fullscreen enter, restore on exit. Phase 5b's `fullscreenRestorePositions` (save column index on enter, restore via `moveColumnToIndex` on exit) is the right approach. Do NOT keep fullscreen windows in the engine — `calculateCombinedLayoutUsingPools` would compute tiled frames for them, conflicting with macOS's fullscreen frame.

**Scope:** Fix A covers same-engine, single-window-column, non-floating transfers. Tabbed columns, cross-engine, and floating windows keep the existing remove+readmit path. This covers ~80%+ of real-world window moves.

**AXRaise after transfer:** Call `performWindowFronting` in the `handleFrameApplyResults` completion path — AFTER the async frame write via `applyFramesParallel` has completed and confirmed. NOT in `commitWorkspaceTransition`'s completion block (which fires before frame writes are confirmed).

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

**Detection using SkyLight/CGS space type:**

Hiro uses SkyLight (SLS) functions, not CGS directly. The Space API functions need to be ADDED to the SkyLight bridge (`Sources/OmniWM/Core/SkyLight/SkyLight.swift`). The actual private API functions are:
- `SLSCopySpacesForWindows(conn, mask, windowArray as CFArray)` → CFArray of space IDs
- `SLSSpaceGetType(conn, spaceId)` → UInt32

Space type values (verify empirically on target macOS version — yabai uses `1` for fullscreen):
- `0` = user/desktop space
- `1` = fullscreen space (per yabai's `extern.h`)
- `4` = tiled fullscreen (unverified)

```swift
static func windowDisplayState(windowId: Int) -> WindowDisplayState {
    let conn = SLSMainConnectionID()
    let windowArray = [CGWindowID(windowId)] as CFArray
    guard let spacesCF = SLSCopySpacesForWindows(conn, 0x7, windowArray) as? [UInt64] else {
        return .normal // fallback if API unavailable
    }
    for spaceId in spacesCF {
        let spaceType = SLSSpaceGetType(conn, spaceId)
        if spaceType == 1 { // fullscreen space (verify on target macOS)
            return .nativeFullscreen
        }
    }
    return .normal
}
```

**Fallback:** If SLS calls fail (function not resolved, SIP restrictions), fall back to current `AXWindowService.isFullscreen` check. Log a warning so we know when the fallback activates.

**Integration:** In `FocusBorderController.renderEligibility`, replace ONLY the `appFullscreen` check:
```swift
// Before:
if isAppFullscreen { return .hide(reason: .appFullscreen) }

// After:
if SkyLight.shared.windowDisplayState(windowId: entry.windowId) == .nativeFullscreen {
    return .hide(reason: .appFullscreen)
}
```

Other `renderEligibility` reasons (notDisplayable, etc.) remain unchanged.

### Verification

1. Add `SLSCopySpacesForWindows` and `SLSSpaceGetType` declarations to SkyLight.swift using the existing `resolveRequired`/`resolveOptional` pattern
2. Verify space type values on macOS 15 (Sequoia) by toggling a window to native fullscreen and logging the type
3. Check yabai's [extern.h](https://github.com/koekeishiya/yabai/blob/master/src/misc/extern.h) for canonical CGS Space constants

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
Instead of full rescan, iterate over restored windows and verify identity + existence:
```swift
func validateRestoredWindows() {
    for (token, entry) in sleepSnapshot.windowStates {
        // Check both existence AND identity — PIDs can be recycled after app restart
        guard let app = NSRunningApplication(processIdentifier: token.pid),
              app.bundleIdentifier != nil,
              isWindowStillAlive(token)
        else {
            removeWindow(token) // clean removal of dead/replaced windows only
            continue
        }
    }
}
```

### DarkWake suppression

DarkWake events (Power Nap, background refresh) fire `didWakeNotification` without user-facing wake. The spec originally proposed IOPMAssertionDeclareUserActivity but that's for declaring activity, not checking it.

**Simpler approach:** Only reconcile when one of:
1. `DisplayConfigurationObserver` fires (screens actually changed) — already debounced at 100ms
2. First user interaction (mouse move, keypress) detected after wake

Do NOT reconcile on bare `didWakeNotification` alone. Instead, set a `pendingWakeReconciliation` flag and let the first real event (display change or user input) trigger reconciliation. This naturally filters DarkWake — no displays change, no user interaction, no reconciliation.

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

**Monitor matching:** Match by `name` (NSScreen localizedName) for consistency with existing `[[monitor]]` config. If two monitors have similar names (e.g., two Samsung displays), support matching by `displayId` as fallback: `id = "display:2"`.

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

### License
Upstream Hiro is MIT-licensed. Fork MUST preserve MIT license with attribution to original author (BarutSRB/Hiro). Add fork-specific copyright line:
```
Copyright (c) 2023 Srdan Barut (original Hiro/OmniWM)
Copyright (c) 2026 Biswadip Paul (fork modifications)
```

### Migration
Write `MIGRATION.md` documenting path changes for existing users:
- IPC socket path change (SketchyBar plugin, shell scripts, launch agents)
- Log subsystem change (log stream predicates)
- Settings directory (if changed)
- The `omniwmctl watch` process must be restarted after upgrades

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
