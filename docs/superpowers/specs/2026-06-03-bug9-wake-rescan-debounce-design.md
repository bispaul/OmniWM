# Bug #9 Fix: Wake-Aware Rescan Debouncing

## Problem

After sleep/wake, macOS disconnects and reconnects external monitors over 1-20 seconds. Hiro fires fullRescan on both the wake event AND each monitor connect/disconnect event, producing 14+ redundant rescans. Windows get assigned to wrong monitors (e.g., 32" workspace windows assigned to 27" display) before all monitors reconnect. Column widths reset to `columnWidthPresets[0]` (33%) instead of preserving pre-sleep widths.

## Root Cause

Two independent triggers fire rescans prematurely:
1. `systemWake` handler calls `requestFullRescan(reason: .unlock)` immediately
2. Each `DisplayConfigurationObserver` event calls `handleMonitorConfigurationChanged` → `applyMonitorConfigurationChanged` → `requestFullRescan`

The `DisplayConfigurationObserver` debounce (100ms) only coalesces events within 100ms — it doesn't wait for all monitors to reconnect (which takes 3.6s+ in observed logs).

## Fix

Add wake stabilization logic to `ServiceLifecycleManager`. After a display-on wake, defer all rescans until the expected number of monitors are back online, with a safety timeout.

### Design

**New state in `ServiceLifecycleManager`:**
- `expectedMonitorCount: Int?` — set on wake to `controller.workspaceManager.monitors.count` (pre-sleep count), cleared when stabilization completes
- `wakeStabilizationTask: Task<Void, Never>?` — the safety timeout task

**Modified wake handler (`setupSleepWakeObservation`):**
1. Record `systemWake` event (unchanged)
2. Check if stabilization is needed:
   - If `expectedMonitorCount <= 1` (laptop-only or uninitialized): skip stabilization, fire rescan immediately as before
   - **DarkWake guard:** If `Monitor.current().count <= 1` AND pre-sleep count was >1, this may be a DarkWake (display stays off, monitors not reconnecting). Do NOT enter stabilization — instead defer to the first `didChangeScreenParametersNotification` to trigger stabilization. Set a flag `awaitingDisplayWake = true` but don't start the timeout yet.
3. If multi-monitor and not DarkWake: set `expectedMonitorCount`, start 30s safety timeout, do NOT call `requestFullRescan`
4. Log: `"systemWake: deferring rescan, expecting N monitors"` or `"systemWake: single monitor, rescan immediately"` or `"systemWake: possible DarkWake, awaiting display event"`

**Modified `applyMonitorConfigurationChanged`:**
1. If `awaitingDisplayWake` is set and a display event arrives: enter stabilization now (set `expectedMonitorCount` from pre-sleep count, start 30s timeout, clear `awaitingDisplayWake`)
2. If `expectedMonitorCount` is nil and `awaitingDisplayWake` is false (not in wake stabilization): behave as before — apply config AND fire rescan
3. If in wake stabilization:
   - Call `controller.workspaceManager.applyMonitorConfigurationChange(currentMonitors)` with `performPostUpdateActions: false` — this updates workspace manager topology but skips `syncMonitorsToNiriEngine`, garbage collection, and `requestFullRescan`. The final rescan after stabilization will rebuild the layout engine state via the full `performPostUpdateActions: true` path.
   - Check `currentMonitors.count >= expectedMonitorCount`
   - If yes: call `completeWakeStabilization()` — clears state, fires ONE `applyMonitorConfigurationChanged(currentMonitors: Monitor.current(), performPostUpdateActions: true)` followed by `requestFullRescan(reason: .monitorConfigurationChanged)`
   - If no: log current count, return without rescan
   - Log: `"wakeStabilization: currentMonitors=M expected=N"` or `"wakeStabilization: complete, firing rescan"`

**`completeWakeStabilization()` — extracted helper (keeps methods under SwiftLint's 50-line limit):**
1. Clear `expectedMonitorCount`
2. Cancel `wakeStabilizationTask`
3. Clear `awaitingDisplayWake`
4. Log: `"wakeStabilization: complete, firing rescan"`
5. Call full `applyMonitorConfigurationChanged(currentMonitors: Monitor.current(), performPostUpdateActions: true)`

**Safety timeout (30s):**
- If 30s passes without all monitors reconnecting (e.g., a monitor was physically unplugged during sleep):
  - Verify `Monitor.current()` returns a valid set (non-empty, not just built-in when externals were expected)
  - If valid: fire rescan with available monitors
  - If only built-in and we expected externals: log warning, fire rescan anyway (user may have unplugged everything)
- Clear all stabilization state
- Log: `"wakeStabilization: timeout, firing rescan with M/N monitors"`

**Sleep handler:**
- Clear `expectedMonitorCount`, `awaitingDisplayWake`, and cancel `wakeStabilizationTask` (prevent stale state from previous incomplete wake cycle)

### What This Changes

- `ServiceLifecycleManager` — 3 new properties (`expectedMonitorCount`, `wakeStabilizationTask`, `awaitingDisplayWake`), new `completeWakeStabilization()` helper, modified wake/sleep handlers, modified `applyMonitorConfigurationChanged`
- No changes to `DisplayConfigurationObserver` — 100ms debounce stays
- No changes to layout engine, `RestorePlanner`, or `PersistedWindowRestoreCatalog`
- No changes to `LayoutRefreshController`

### What This Does NOT Change

- Normal (non-wake) monitor connect/disconnect still triggers immediate rescan
- The fullRescan logic itself is untouched
- Column width assignment during re-admission is unchanged (the fix prevents premature re-admission, so widths are preserved in the Niri layout engine's in-memory state)
- During stabilization, windows remain in their pre-sleep positions (not re-laid out). This is better than the current behavior of 14 rescans with wrong assignments.

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Monitor physically unplugged during sleep | 30s timeout fires rescan with reduced count |
| All monitors reconnect in 2s | Rescan fires at 2s (fast path) |
| One monitor takes 20s | Rescan waits until 20s |
| New monitor added during sleep | Count exceeds expected → rescan fires immediately |
| No external monitors (laptop only) | `expectedMonitorCount <= 1` → skip stabilization, rescan immediately |
| Back-to-back sleep/wake cycles | Sleep handler clears stale state |
| DarkWake (display stays off) | `awaitingDisplayWake` set, no timeout started. If user opens lid later, first display event triggers stabilization. If system sleeps again, sleep handler clears state. |
| Clamshell mode → lid opened during wake | Monitor count increases beyond expected → rescan fires when new count reached |
| Monitor B reconnects at 25s, new monitor D at 2s (count=3 at 2s) | Stabilization completes at 2s with A,C,D. Monitor B at 25s triggers normal (non-stabilization) rescan. |
| `applyMonitorConfigurationChange` called with intermediate monitor sets | Uses `performPostUpdateActions: false` — workspace manager tracks topology but layout engine not touched until final rescan |

### Concurrency Notes

- `ServiceLifecycleManager` is `@MainActor`. All new properties are accessed only on MainActor.
- The 30s timeout `Task` is `@MainActor` — uses `try? await Task.sleep(nanoseconds:)` then checks `expectedMonitorCount` on resume. No data races.
- `Monitor.current()` uses `NSScreen.screens` which is synchronous and accurate when called from `didChangeScreenParametersNotification` handler on MainActor. Both reads (in `DisplayConfigurationObserver.handleDisplayChange` and `ServiceLifecycleManager.handleMonitorConfigurationChanged`) are synchronous on MainActor with no suspension point between them.

### Tests

Add to existing test infrastructure, following `@Suite struct` + `@Test @MainActor func` pattern:

1. **Wake defers rescan until expected monitors are back** — simulate wake with 3 expected monitors, verify no rescan fires until 3 monitors are reported
2. **Safety timeout fires rescan** — simulate wake, never reconnect all monitors, verify rescan fires after timeout
3. **Sleep clears stabilization state** — simulate wake then sleep, verify no stale state
4. **Single-monitor wake skips stabilization** — verify immediate rescan when expectedMonitorCount <= 1
5. **DarkWake does not enter stabilization** — simulate wake with Monitor.current().count < expected, verify awaitingDisplayWake is set but no timeout started

### Logging

New logs to add:
- `"systemWake: deferring rescan, expecting N monitors"`
- `"systemWake: single monitor, rescan immediately"`
- `"systemWake: possible DarkWake, awaiting display event"`
- `"wakeStabilization: entered from display event, expecting N monitors"`
- `"wakeStabilization: currentMonitors=M expected=N"`
- `"wakeStabilization: complete, firing rescan"`
- `"wakeStabilization: timeout, firing rescan with M/N monitors"`

## Verification

1. `swift build` compiles
2. Targeted tests pass
3. Restart Hiro with log stream, sleep/wake the Mac:
   - Should see `"systemWake: deferring rescan, expecting 3 monitors"`
   - Should see `"wakeStabilization: currentMonitors=1"` then `"currentMonitors=2"` then `"currentMonitors=3"`
   - Should see ONE `"wakeStabilization: complete, firing rescan"` instead of 14 separate rescans
   - Windows on 32" should keep their pre-sleep column widths
