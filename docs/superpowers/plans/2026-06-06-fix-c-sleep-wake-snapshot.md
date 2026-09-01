# Fix C: Sleep/Wake Snapshot Restore — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture window/layout state on sleep, restore it on wake instead of doing a full rescan. Suppress DarkWake false triggers.

**Architecture:** Add `SleepStateSnapshot` to ServiceLifecycleManager. On `willSleepNotification`, capture monitor IDs, per-workspace Niri placements (via existing `persistedPlacements`), viewport states, and focused token. On `didWakeNotification`, if same monitors reconnect, restore from snapshot using existing `restoreInitialPlacements` + viewport state writes instead of `applyMonitorConfigurationChanged`. Add `pendingWakeReconciliation` flag to suppress DarkWake.

**Tech Stack:** Swift, swift-testing framework

**Spec:** `docs/superpowers/specs/2026-06-06-fork-release-plan.md` — Fix C section

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` | Modify | Add snapshot capture on sleep, restore on wake, DarkWake suppression |
| `Tests/OmniWMTests/SleepWakeSnapshotTests.swift` | Create | Tests for Fix C |

---

### Task 1: Snapshot capture on sleep + restore on wake

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift`
- Create: `Tests/OmniWMTests/SleepWakeSnapshotTests.swift`

This is a single task because capture and restore are tightly coupled — you can't test one without the other.

- [ ] **Step 1: Write failing tests**

Create `Tests/OmniWMTests/SleepWakeSnapshotTests.swift`:

```swift
import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct SleepWakeSnapshotTests {

    @Test func captureSnapshotStoresMonitorIdsAndWindowStates() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing context")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 9801)
        engine.syncWindows([token], in: ws1, selectedNodeId: nil)
        _ = controller.workspaceManager.setManagedFocus(token, in: ws1, onMonitor: monitor.id)

        let plans = try? await controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [ws1])
        if let plans { controller.layoutRefreshController.executeLayoutPlans(plans) }
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        // Capture snapshot
        let snapshot = controller.serviceLifecycleManager.captureStateSnapshot()

        #expect(snapshot != nil)
        #expect(snapshot!.monitorIds.contains(monitor.id))
        #expect(snapshot!.focusedToken == token)
        #expect(!snapshot!.niriPlacements.isEmpty)

        // Verify column width was captured
        if let placement = snapshot!.niriPlacements[ws1]?[token] {
            #expect(placement.column.width != .default || placement.columnIndex >= 0)
        }
    }

    @Test func pendingWakeReconciliationDefaultsFalse() {
        let controller = makeLayoutPlanTestController()
        #expect(!controller.serviceLifecycleManager.pendingWakeReconciliation)
    }
}
```

- [ ] **Step 2: Run tests — verify compilation failure**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter SleepWakeSnapshotTests 2>&1 | tail -20`

- [ ] **Step 3: Implement SleepStateSnapshot and capture**

In `ServiceLifecycleManager.swift`, add the snapshot struct and capture method.

**Add struct (near the top of the class):**

```swift
struct SleepStateSnapshot {
    let monitorIds: Set<Monitor.ID>
    let niriPlacements: [WorkspaceDescriptor.ID: [WindowToken: PersistedNiriPlacement]]
    let viewportStates: [WorkspaceDescriptor.ID: ViewportState]
    let focusedToken: WindowToken?
    let timestamp: Date
}
```

**Add properties:**

```swift
private(set) var sleepSnapshot: SleepStateSnapshot?
var pendingWakeReconciliation: Bool = false
```

**Add capture method:**

```swift
func captureStateSnapshot() -> SleepStateSnapshot? {
    guard let controller else { return nil }
    let wm = controller.workspaceManager

    let monitorIds = Set(wm.monitors.map(\.id))

    var niriPlacements: [WorkspaceDescriptor.ID: [WindowToken: PersistedNiriPlacement]] = [:]
    var viewportStates: [WorkspaceDescriptor.ID: ViewportState] = [:]

    if let engine = controller.niriEngine {
        for wsId in wm.allWorkspaceIds {
            let placements = engine.persistedPlacements(in: wsId)
            if !placements.isEmpty {
                niriPlacements[wsId] = placements
            }
            viewportStates[wsId] = wm.niriViewportState(for: wsId)
        }
    }

    return SleepStateSnapshot(
        monitorIds: monitorIds,
        niriPlacements: niriPlacements,
        viewportStates: viewportStates,
        focusedToken: wm.focusedToken,
        timestamp: Date()
    )
}
```

**Modify sleep handler** (in `setupSleepWakeObservation`, the willSleepNotification block, around line 419-425):

Add `self?.sleepSnapshot = self?.captureStateSnapshot()` before the recordReconcileEvent call:

```swift
sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.willSleepNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    MainActor.assumeIsolated {
        self?.sleepSnapshot = self?.captureStateSnapshot()
        WMLog.ax.info("systemSleep: snapshot captured monitors=\(self?.sleepSnapshot?.monitorIds.count ?? 0, privacy: .public)")
        _ = self?.controller?.workspaceManager.recordReconcileEvent(.systemSleep(source: .service))
    }
}
```

**Modify wake handler** (in `startWakeReconciliation`, around line 294-319):

After monitors stabilize (after the polling loop), add snapshot restore path:

```swift
// After the polling while loop and guard !Task.isCancelled:
let currentMonitors = Monitor.current()
let currentIds = Set(currentMonitors.map(\.id))

if let snapshot = self?.sleepSnapshot,
   currentIds == snapshot.monitorIds
{
    // Same monitors: restore from snapshot
    WMLog.ax.info("wakeReconciliation: same monitors, restoring from snapshot")
    self?.restoreFromSnapshot(snapshot)
} else {
    // Different monitors or no snapshot: full topology restoration
    WMLog.ax.info("wakeReconciliation: monitor change detected, full restoration")
    self?.applyMonitorConfigurationChanged(currentMonitors: currentMonitors)
}
self?.sleepSnapshot = nil
self?.controller?.workspaceManager.isReconciling = false
```

**Add restore method:**

```swift
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
            let tokens = Array(placements.keys)
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

    // Trigger layout reflow for all workspaces
    controller.layoutRefreshController.requestImmediateRelayout(
        reason: .fullRescan,
        affectedWorkspaceIds: Set(snapshot.niriPlacements.keys)
    )
}

private func validateRestoredWindows(from snapshot: SleepStateSnapshot) {
    guard let controller else { return }
    for (wsId, placements) in snapshot.niriPlacements {
        for token in placements.keys {
            guard let app = NSRunningApplication(processIdentifier: token.pid),
                  app.bundleIdentifier != nil
            else {
                WMLog.ax.info("wakeValidation: removing dead window pid=\(token.pid, privacy: .public) wid=\(token.windowId, privacy: .public)")
                controller.workspaceManager.removeWindow(token)
                controller.niriEngine?.removeWindow(token: token)
                continue
            }
        }
    }
}
```

**IMPORTANT implementation notes:**

1. Check if `allWorkspaceIds` exists on WorkspaceManager. If not, use `workspaceDescriptors` or iterate `sessionState.workspaceSessions.keys`. Read the WorkspaceManager to find the right API.

2. Check if `restoreInitialPlacements` can be called on an already-populated engine (it may expect an empty workspace). If it clears first, that's fine. If not, you may need to clear the workspace's columns first. Read `NiriLayoutEngine+Restore.swift` to verify.

3. `requestImmediateRelayout(reason:affectedWorkspaceIds:)` — verify this method signature exists on LayoutRefreshController. It might be `requestImmediateRelayout(reason:)` without workspace IDs.

4. `removeWindow(token)` on WorkspaceManager — verify this method exists. It might be `removeWindow(_:)` or have a different signature.

5. Use `WMLog.ax.info()` for all logging (matching existing sleep/wake log subsystem).

- [ ] **Step 4: Run tests — verify they pass**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter SleepWakeSnapshotTests 2>&1 | tail -20`

- [ ] **Step 5: Run full test suite**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test 2>&1 | tail -5`

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift Tests/OmniWMTests/SleepWakeSnapshotTests.swift
git commit -m "feat(fix-c): sleep/wake snapshot capture and restore

Capture SleepStateSnapshot on willSleepNotification: monitor IDs,
per-workspace Niri placements (column widths/indices via existing
persistedPlacements), viewport states, focused token.

On wake, if same monitors reconnect, restore from snapshot using
restoreInitialPlacements instead of full rescan. Validates windows
still exist after restore (removes dead PIDs). Falls back to full
topology restoration if monitors changed.

Eliminates column width loss, workspace reassignment errors, and
redundant rescans on same-monitor wake.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: DarkWake suppression

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift`
- Test: `Tests/OmniWMTests/SleepWakeSnapshotTests.swift` (append)

- [ ] **Step 1: Write failing test**

```swift
    @Test func darkWakeSuppressesConciliation() async {
        let controller = makeLayoutPlanTestController()

        // Simulate wake without display change
        controller.serviceLifecycleManager.pendingWakeReconciliation = true

        // Without a display event or user input, reconciliation should not trigger
        #expect(controller.serviceLifecycleManager.pendingWakeReconciliation)

        // Simulate display event arrival
        controller.serviceLifecycleManager.pendingWakeReconciliation = false
        #expect(!controller.serviceLifecycleManager.pendingWakeReconciliation)
    }
```

- [ ] **Step 2: Modify wake handler for DarkWake suppression**

In `startWakeReconciliation`, instead of immediately starting the polling task, set `pendingWakeReconciliation = true` and return. The actual reconciliation starts when:
1. `DisplayConfigurationObserver` fires a connect/reconfigure event, OR
2. A timeout fires (e.g., 30 seconds safety net)

In `handleDisplayEvent` (around line 158-174), add:

```swift
if pendingWakeReconciliation {
    pendingWakeReconciliation = false
    startWakeReconciliationNow()
}
```

Rename the current `startWakeReconciliation` body to `startWakeReconciliationNow` and have `startWakeReconciliation` set the flag + start a safety timeout:

```swift
private func startWakeReconciliation() {
    pendingWakeReconciliation = true
    WMLog.ax.info("wakeReconciliation: deferred, waiting for display event or timeout")

    // Safety timeout — if no display event arrives in 30s, reconcile anyway
    wakeReconciliationTask?.cancel()
    wakeReconciliationTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
        guard !Task.isCancelled, self?.pendingWakeReconciliation == true else { return }
        WMLog.ax.info("wakeReconciliation: timeout, reconciling without display event")
        self?.pendingWakeReconciliation = false
        self?.startWakeReconciliationNow()
    }
}
```

- [ ] **Step 3: Run tests — verify they pass**
- [ ] **Step 4: Run full test suite**
- [ ] **Step 5: Commit**

```bash
git commit -m "feat(fix-c): DarkWake suppression — defer reconciliation until display event

On wake, set pendingWakeReconciliation flag instead of immediately
polling. Actual reconciliation triggers when DisplayConfigurationObserver
fires (screens changed) or after 30s safety timeout. Filters DarkWake
events (Power Nap) which fire didWakeNotification without display changes.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Build, deploy, verify

Follow MANDATORY deploy sequence from memorygraph.

- [ ] **Step 1:** Bump build to 79 in Info.plist
- [ ] **Step 2:** Full test suite
- [ ] **Step 3:** Build
- [ ] **Step 4:** Deploy: kill → launch .build/debug/OmniWM → verify PID → omniwmctl ping → restart watcher
- [ ] **Step 5:** Verify via logs with `--info --debug`:
   - Close laptop lid (sleep), reopen → check logs for "snapshot captured" + "same monitors, restoring from snapshot"
   - Column widths should be preserved after wake
- [ ] **Step 6:** Commit build bump
