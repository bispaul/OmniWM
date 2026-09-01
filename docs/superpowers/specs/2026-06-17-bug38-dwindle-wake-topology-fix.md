# Bug #38: Dwindle Wake Topology Fix

## Problem

When a display momentarily disconnects during wake (or hot-plug), windows on Dwindle workspaces get laid out with wrong-display geometry. The sequence:

1. Display:2 (portrait 27") disconnects during wake (~1-2s window)
2. WS6 (Dwindle, home=display:2) loses its home monitor
3. `effectiveMonitor(for: ws6)` falls back to display:3 (32" landscape)
4. Dwindle layout computes frames using display:3 geometry (2560x1440)
5. Frame writes attempt to move windows to display:3 coordinates — some succeed, updating `lastAppliedFrames`
6. Display:2 reconnects, workspace mapping restores
7. Recovery relayout computes correct display:2 frames, BUT frame writes are **skipped** by `frameWithinConvergence` check because `lastAppliedFrames` holds stale values close enough to the target

Result: Chrome shows "too small to render" at x=2560 (display:3 coords) on the portrait display.

## Evidence

- 2026-06-17 16:46 wake logs: display:2 disconnected for 1.7s, zero frame writes for WS6 windows after reconnect
- 2026-06-17 17:43 physical unplug: diagnostic logs confirm `dwindleLayout: processing ws=6 displayId=3` during disconnect, and that the recovery relayout DOES run with correct geometry but frame writes may be skipped
- Self-correction observed after ~10-30s in the physical unplug test (but not in the original 16:46 wake)
- Bug is intermittent — depends on whether the specific display disconnects during wake (hardware timing)

## Devil's Advocate Review

### Change 1 (isReconciling guard) — REJECTED

Originally proposed: skip Dwindle layout when `isReconciling == true` and workspace is on a fallback monitor.

**Flaw**: `isReconciling` is cleared at the end of `applyMonitorConfigurationChanged` (line 311), BEFORE the async relayout runs. The guard would never fire during the actual Dwindle layout — it's a timing no-op.

```
T=0:       display disconnects → isReconciling = true
T=300ms:   applyMonitorConfigurationChanged runs
T=300ms+ε: requestFullRescan enqueued → isReconciling = false
T=300ms+δ: async relayout runs → isReconciling is FALSE (guard never fires)
```

Deferring `isReconciling = false` to a postLayoutAction would change the flag's lifetime with broader behavioral impact — excessive risk for this fix.

## Fix: Single Surgical Change

### Invalidate frame cache on monitor reconnect

**Files**:
- `Sources/OmniWM/Core/AX/AXManager.swift` — new method
- `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` — call site

**Root cause**: When the recovery relayout runs with correct display:2 geometry, the convergence check in `AXManager.applyFramesParallel` compares the target frame against `lastAppliedFrames[windowId]`. If the stale entry is close enough (within `FrameTolerance.frameWrite` or learned `sizeQuantum`), the write is skipped.

**Fix**: When a previously-disconnected monitor reconnects, invalidate the frame cache (`lastAppliedFrames` + `sizeQuantumByWindowId`) for all windows on workspaces assigned to the reconnected monitor. This ensures the recovery relayout's frame writes are not skipped.

#### New method: `AXManager.invalidateFrameCache(for:)`

```swift
func invalidateFrameCache(for windowId: Int) {
    lastAppliedFrames.removeValue(forKey: windowId)
    sizeQuantumByWindowId.removeValue(forKey: windowId)
}
```

Clears both `lastAppliedFrames` (convergence baseline) and `sizeQuantumByWindowId` (learned snap quantum — invalid after topology change since the quantum was learned for a different monitor's geometry).

Does NOT clear: `pendingFrameWrites`, `recentFrameWriteFailures`, `retryBudgetByWindowId` — these are transient and will be refreshed by the next write attempt.

#### Call site: `ServiceLifecycleManager.applyMonitorConfigurationChanged`

Insert between `applyMonitorConfigurationChange` and `requestFullRescan`:

```swift
// Existing:
controller.workspaceManager.isReconciling = true
let previousMonitorIds = Set(controller.workspaceManager.monitors.map(\.id))  // NEW: capture before
controller.workspaceManager.applyMonitorConfigurationChange(currentMonitors)
// ... existing syncMouseWarpPolicy, syncMonitorsToNiriEngine, garbageCollect ...

// NEW: invalidate frame cache for windows on reconnected monitors
let reconnectedMonitorIds = Set(currentMonitors.map(\.id)).subtracting(previousMonitorIds)
if !reconnectedMonitorIds.isEmpty {
    var invalidatedCount = 0
    for workspace in controller.workspaceManager.workspaces {
        guard let monitorId = controller.workspaceManager.monitorId(for: workspace.id),
              reconnectedMonitorIds.contains(monitorId)
        else { continue }
        for entry in controller.workspaceManager.entries(in: workspace.id) {
            controller.axManager.invalidateFrameCache(for: entry.token.windowId)
            invalidatedCount += 1
        }
    }
    WMLog.ax.info(
        "monitorReconnect: invalidated frame cache for \(invalidatedCount, privacy: .public) windows on \(reconnectedMonitorIds.count, privacy: .public) monitor(s)"
    )
}

// Existing:
controller.layoutRefreshController.requestFullRescan(reason: .monitorConfigurationChanged)
reconciliationSafetyTask?.cancel()
controller.workspaceManager.isReconciling = false
```

### Why this is safe

1. **No new data structures**: Uses existing maps, just removes entries
2. **Idempotent**: Clearing a non-existent entry is a no-op
3. **Convergence check still works**: The next successful frame write re-populates `lastAppliedFrames` via `confirmFrameWrite`. Future convergence checks work normally.
4. **Quantum re-learned**: The next `verificationMismatch` re-learns the quantum for the correct monitor via `learnSizeQuantum`
5. **Niri windows also covered**: The clearing logic applies to ALL workspaces on the reconnected monitor, not just Dwindle — Niri benefits too

### What this does NOT change

- No new data structures or caches
- No changes to the RestorePlanner or TopologyTransitionPlan
- No changes to `isReconciling` lifetime or semantics
- No changes to the Niri layout engine internals
- No changes to the sleep/wake `executeFinalRestore` path

### Test plan

1. **Unit test**: `invalidateFrameCache` clears both `lastAppliedFrames` and `sizeQuantumByWindowId`
2. **Unit test**: `applyMonitorConfigurationChanged` calls `invalidateFrameCache` for windows on reconnected monitors only (not surviving monitors)
3. **Integration**: Physical display unplug/replug — WS6 windows should retain correct positions immediately (no 10-30s self-correction delay)
4. **Integration**: Sleep/wake with display disconnect — WS6 windows at correct coordinates
5. **Regression**: Normal sleep/wake (no disconnect) — no behavior change (reconnectedMonitorIds is empty → no invalidation)
6. **Regression**: Workspace switch, focus navigation — no behavior change
