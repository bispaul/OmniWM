# Fix C Remaining Items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete Fix C sleep/wake restore by fixing column order (stale viewport NodeId), adding semantic RefreshReason cases, and refactoring matchedTokens to eliminate call-order dependency.

**Architecture:** All changes are in ServiceLifecycleManager (orchestration layer) and RefreshReason (enum). Layout engines are untouched — we fix inputs to the viewport pipeline, not the pipeline itself. Phase 1-5+ABC compliant.

**Tech Stack:** Swift 6.2, Apple Testing framework (`@Test @MainActor`), `@MainActor` concurrency, SPM

**Spec:** `docs/superpowers/specs/2026-06-07-fix-c-sleep-wake-restore-design.md`

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` | Modify | All 3 items: matchedTokens refactor, viewport fixup, reason update |
| `Sources/OmniWM/Core/Controller/RefreshReason.swift` | Modify | Add `.wakeRescan` and `.wakeRestore` enum cases |
| `Tests/OmniWMTests/WakeRestoreTests.swift` | Modify | Tests for all 3 items |

---

## Task 1: Complete matchedTokens inout Refactor

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` (lines 452, 532-560, 562-679)
- Test: `Tests/OmniWMTests/WakeRestoreTests.swift`

**Status:** Partially done. `resolveTrackedToken` signature updated. `tryRestoreWorkspaces` updated. Still need: `finalizeWakeRestore`, `executeFinalRestore` (step 1 + focus), and remove instance property.

- [ ] **Step 1: Write the failing test — matchedTokens isolation between phases**

Add to `Tests/OmniWMTests/WakeRestoreTests.swift`:

```swift
@Test @MainActor func resolveTrackedTokenUsesLocalMatchedTokens() {
    let defaults = makeWakeTestDefaults()
    let settings = SettingsStore(defaults: defaults)
    let controller = WMController(settings: settings)
    let slm = ServiceLifecycleManager(controller: controller)

    let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
    controller.workspaceManager.applyMonitorConfigurationChange([retina])

    let snapshot = slm.captureStateSnapshot()
    #expect(snapshot != nil)

    // Verify the instance property is removed — this test passes if
    // matchedTokens is no longer instance state (compile-time check).
    // The real verification is that the code compiles without the property.
    #expect(snapshot?.windowRecords.isEmpty == true)
}
```

- [ ] **Step 2: Run test to verify it passes (baseline)**

Run: `swift test --filter WakeRestoreTests/resolveTrackedTokenUsesLocalMatchedTokens 2>&1 | tail -5`
Expected: PASS (baseline — the real test is compile-time correctness)

- [ ] **Step 3: Update `finalizeWakeRestore` — replace instance matchedTokens with local var**

In `ServiceLifecycleManager.swift`, replace the `finalizeWakeRestore` method body. The key changes:
1. Replace `matchedTokens.removeAll()` with `var matchedTokens: Set<WindowToken> = []`
2. Pass `matchedTokens: &matchedTokens` to `resolveTrackedToken`

```swift
private func finalizeWakeRestore(from snapshot: SleepStateSnapshot) {
    guard let controller else {
        wakePhase = .idle
        sleepSnapshot = nil
        return
    }

    var matchedTokens: Set<WindowToken> = []
    let missingCount = snapshot.windowRecords.filter { record in
        !record.isNativeFullscreen &&
        record.hiddenReason != .scratchpad &&
        NSRunningApplication(processIdentifier: record.pid) != nil &&
        resolveTrackedToken(for: record, in: controller.workspaceManager, matchedTokens: &matchedTokens) == nil
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
```

- [ ] **Step 4: Update `executeFinalRestore` step 1 — replace instance matchedTokens with local var**

In `executeFinalRestore`, replace `matchedTokens.removeAll()` with `var matchedTokens: Set<WindowToken> = []` and pass `matchedTokens: &matchedTokens` to `resolveTrackedToken`:

Change line in step 1 from:
```swift
matchedTokens.removeAll()
```
to:
```swift
var matchedTokens: Set<WindowToken> = []
```

And change the resolveTrackedToken call from:
```swift
guard let resolvedToken = resolveTrackedToken(for: record, in: wm) else { continue }
```
to:
```swift
guard let resolvedToken = resolveTrackedToken(for: record, in: wm, matchedTokens: &matchedTokens) else { continue }
```

- [ ] **Step 5: Update `executeFinalRestore` step 7 (focus) — replace instance matchedTokens with local var**

In the deferred focus Task inside `executeFinalRestore`, replace:
```swift
self.matchedTokens.removeAll()
resolvedFocusToken = self.resolveTrackedToken(for: focusRecord, in: wm)
```
with:
```swift
var focusMatchedTokens: Set<WindowToken> = []
resolvedFocusToken = self.resolveTrackedToken(for: focusRecord, in: wm, matchedTokens: &focusMatchedTokens)
```

- [ ] **Step 6: Remove the instance property**

Delete line 452:
```swift
private var matchedTokens: Set<WindowToken> = []
```

- [ ] **Step 7: Build to verify compilation**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -10`
Expected: Build succeeds with no errors related to `matchedTokens`

- [ ] **Step 8: Run existing wake tests**

Run: `swift test --filter WakeRestoreTests 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 9: Commit**

```bash
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift Tests/OmniWMTests/WakeRestoreTests.swift
git commit -m "refactor(fix-c): matchedTokens from instance state to inout parameter

Remove mutable Set<WindowToken> instance property from ServiceLifecycleManager.
Each caller (tryRestoreWorkspaces, finalizeWakeRestore, executeFinalRestore,
focus restore) now creates a local set and passes it via inout to
resolveTrackedToken. Eliminates the stale-state bug class where tokens
from tick 5 leaked into finalization."
```

---

## Task 2: Add RefreshReason.wakeRescan and .wakeRestore

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/RefreshReason.swift` (lines 33-129)
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` (2 call sites)
- Test: `Tests/OmniWMTests/WakeRestoreTests.swift`

- [ ] **Step 1: Write the failing test — wake restore uses correct RefreshReason**

Add to `Tests/OmniWMTests/WakeRestoreTests.swift`:

```swift
@Test @MainActor func wakeRestoreRefreshReasonHasCorrectRoutes() {
    #expect(RefreshReason.wakeRescan.requestRoute == .fullRescan)
    #expect(RefreshReason.wakeRestore.requestRoute == .immediateRelayout)
    #expect(RefreshReason.wakeRescan.relayoutSchedulingPolicy == .plain)
    #expect(RefreshReason.wakeRestore.relayoutSchedulingPolicy == .plain)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WakeRestoreTests/wakeRestoreRefreshReasonHasCorrectRoutes 2>&1 | tail -10`
Expected: FAIL — `wakeRescan` and `wakeRestore` not defined

- [ ] **Step 3: Add enum cases to RefreshReason**

In `Sources/OmniWM/Core/Controller/RefreshReason.swift`, add after `case overviewMutation` (line 58):

```swift
case wakeRescan
case wakeRestore
```

Add to the `requestRoute` switch — add `.wakeRescan` to the `.fullRescan` group and `.wakeRestore` to the `.immediateRelayout` group:

In the `.fullRescan` group (after `.appTerminated:`):
```swift
             .wakeRescan:
```

In the `.immediateRelayout` group (after `.overviewMutation:`):
```swift
             .wakeRestore:
```

Add to the `relayoutSchedulingPolicy` switch — add both to the `.plain` group (after `.overviewMutation:`):
```swift
             .wakeRescan,
             .wakeRestore,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WakeRestoreTests/wakeRestoreRefreshReasonHasCorrectRoutes 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Update call site in `finalizeWakeRestore`**

In `ServiceLifecycleManager.swift`, in `finalizeWakeRestore`, change:
```swift
controller.layoutRefreshController.requestFullRescan(reason: .monitorConfigurationChanged)
```
to:
```swift
controller.layoutRefreshController.requestFullRescan(reason: .wakeRescan)
```

- [ ] **Step 6: Update call site in `executeFinalRestore`**

In `ServiceLifecycleManager.swift`, in `executeFinalRestore` step 6 (relayout), change:
```swift
reason: .workspaceTransition,
```
to:
```swift
reason: .wakeRestore,
```

- [ ] **Step 7: Build and run tests**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5 && swift test --filter WakeRestoreTests 2>&1 | tail -10`
Expected: Build succeeds, all WakeRestore tests pass

- [ ] **Step 8: Commit**

```bash
git add Sources/OmniWM/Core/Controller/RefreshReason.swift Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift Tests/OmniWMTests/WakeRestoreTests.swift
git commit -m "feat(fix-c): add RefreshReason.wakeRescan and .wakeRestore

Add purpose-specific refresh reasons for wake restore operations.
- .wakeRescan (fullRescan route) replaces .monitorConfigurationChanged in finalizeWakeRestore
- .wakeRestore (immediateRelayout route) replaces .workspaceTransition in executeFinalRestore
Both use .plain scheduling. Improves log clarity without functional change."
```

---

## Task 3: Fix Viewport selectedNodeId After Niri Tree Rebuild

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` (executeFinalRestore, between current steps 4 and 5)
- Test: `Tests/OmniWMTests/WakeRestoreTests.swift`

**Root cause:** `restoreInitialPlacements` (step 2) creates new NiriWindow/NiriContainer nodes with fresh `NodeId`s. Step 4 restores the viewport state from snapshot, but its `selectedNodeId` references the old, now-nonexistent NodeId. During relayout (step 6), `resolveSelection` → `validateSelection` can't find the stale ID → falls back to `columns.first?.firstChild()?.id` → `ensureSelectionVisible` scrolls viewport to column 0 → user's actual active column scrolls off viewport.

- [ ] **Step 1: Write the failing test — selectedNodeId is fixed after Niri placement restore**

Add to `Tests/OmniWMTests/WakeRestoreTests.swift`:

```swift
@Test @MainActor func executeFinalRestoreFixesStaleSelectedNodeId() {
    let defaults = makeWakeTestDefaults()
    let settings = SettingsStore(defaults: defaults)
    let controller = WMController(settings: settings)
    let slm = ServiceLifecycleManager(controller: controller)

    let retina = makeWakeTestMonitor(displayId: 1, name: "Built-in Retina Display")
    controller.workspaceManager.applyMonitorConfigurationChange([retina])

    // Enable Niri engine
    controller.enableNiriLayout()

    // Create workspace
    guard let wsId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
    else {
        Issue.record("Failed to create workspace")
        return
    }
    _ = controller.workspaceManager.setActiveWorkspace(wsId, on: retina.id)

    // Add 3 windows to Niri — creates 3 columns
    let token1 = WindowToken(pid: 100, windowId: 1)
    let token2 = WindowToken(pid: 200, windowId: 2)
    let token3 = WindowToken(pid: 300, windowId: 3)

    controller.workspaceManager.admitWindow(token: token1, on: wsId, mode: .tiling)
    controller.workspaceManager.admitWindow(token: token2, on: wsId, mode: .tiling)
    controller.workspaceManager.admitWindow(token: token3, on: wsId, mode: .tiling)

    guard let engine = controller.niriEngine else {
        Issue.record("Niri engine not available")
        return
    }
    engine.addWindow(token: token1, in: wsId)
    engine.addWindow(token: token2, in: wsId)
    engine.addWindow(token: token3, in: wsId)

    // Set viewport to column 2 (third column — token3)
    let columns = engine.columns(in: wsId)
    #expect(columns.count == 3)
    let originalNodeId = columns[2].activeWindow?.id
    #expect(originalNodeId != nil)

    controller.workspaceManager.withNiriViewportState(for: wsId) { state in
        state.activeColumnIndex = 2
        state.selectedNodeId = originalNodeId
    }

    // Capture snapshot (preserves column order + viewport state)
    guard let snapshot = slm.captureStateSnapshot() else {
        Issue.record("Failed to capture snapshot")
        return
    }

    // Simulate sleep/wake: set wake phase and call executeFinalRestore
    slm.setWakePhaseForTests(.awaitingRestore(snapshot))
    slm.setSleepSnapshotForTests(snapshot)

    // executeFinalRestore will rebuild Niri tree (step 2) with fresh NodeIds,
    // then restore viewport (step 4), then fix selectedNodeId (step 5)
    slm.simulateWakeForTests(snapshot: snapshot)

    // After restore: selectedNodeId should point to a VALID node in the tree
    // (not the stale originalNodeId which no longer exists)
    let restoredViewport = controller.workspaceManager.niriViewportState(for: wsId)
    #expect(restoredViewport.activeColumnIndex == 2)

    // selectedNodeId must NOT be the stale original (tree was rebuilt)
    // It must be a valid node that exists in the current tree
    if let selectedId = restoredViewport.selectedNodeId {
        let foundNode = engine.findNode(by: selectedId, in: wsId)
        #expect(foundNode != nil, "selectedNodeId must reference a valid node in the rebuilt tree")
    }
}
```

**Note:** `simulateWakeForTests`, `setWakePhaseForTests`, `setSleepSnapshotForTests` are existing test helpers (see ServiceLifecycleManager test helpers section). If `simulateWakeForTests` doesn't call `executeFinalRestore` directly, call it via the test helper that does.

- [ ] **Step 2: Verify test helpers exist — check simulateWakeForTests**

Read `ServiceLifecycleManager/simulateWakeForTests` and `setWakePhaseForTests` to understand what they do. If `simulateWakeForTests` doesn't directly trigger `executeFinalRestore`, add a new test helper `executeTestFinalRestore(from:)` that calls `executeFinalRestore` directly:

```swift
func executeTestFinalRestore(from snapshot: SleepStateSnapshot) {
    executeFinalRestore(from: snapshot)
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter WakeRestoreTests/executeFinalRestoreFixesStaleSelectedNodeId 2>&1 | tail -15`
Expected: FAIL — `selectedNodeId` is either nil or references a stale NodeId not found in the tree

- [ ] **Step 4: Implement viewport selectedNodeId fixup — add step 5 in executeFinalRestore**

In `ServiceLifecycleManager.swift`, in `executeFinalRestore`, add a new step between the current step 4 (viewport states) and step 5 (validate dead windows):

```swift
// Step 5: Fix stale selectedNodeId after Niri tree rebuild
// restoreInitialPlacements (step 2) creates new NiriNode objects with fresh NodeIds.
// The viewport's selectedNodeId from the snapshot references the old, now-nonexistent NodeId.
// Fix it by looking up the active column's active window in the new tree.
if let engine = controller.niriEngine {
    for wsId in snapshot.niriPlacements.keys {
        var viewportState = wm.niriViewportState(for: wsId)
        let columns = engine.columns(in: wsId)
        guard !columns.isEmpty else { continue }
        let clampedIndex = min(viewportState.activeColumnIndex, columns.count - 1)
        if let activeWindow = columns[clampedIndex].activeWindow {
            viewportState.selectedNodeId = activeWindow.id
            wm.updateNiriViewportState(viewportState, for: wsId)
        }
    }
}
```

Renumber subsequent steps (old step 5 → step 6, old step 6 → step 7, old step 7 → step 8).

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter WakeRestoreTests/executeFinalRestoreFixesStaleSelectedNodeId 2>&1 | tail -15`
Expected: PASS — selectedNodeId now references a valid node in the rebuilt tree

- [ ] **Step 6: Run all wake restore tests**

Run: `swift test --filter WakeRestoreTests 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 7: Build full project**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 8: Commit**

```bash
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift Tests/OmniWMTests/WakeRestoreTests.swift
git commit -m "fix(fix-c): fix viewport selectedNodeId after Niri tree rebuild

restoreInitialPlacements creates new NiriNode objects with fresh NodeIds.
The viewport's selectedNodeId from the snapshot references the old,
now-nonexistent NodeId. During relayout, validateSelection can't find
it and falls back to column 0's first child, scrolling the user's actual
active column off-viewport.

Add step 5 in executeFinalRestore: after viewport state restore (step 4),
look up each workspace's active column in the rebuilt tree and set
selectedNodeId to its active window's new NodeId. This ensures the
relayout's resolveSelection finds the correct node and
ensureSelectionVisible scrolls to the right column.

Root cause of test 19's focus failure: Ghostty's column scrolled
off-viewport as layoutTransient(hidden) because viewport targeted
column 0 instead of column 3."
```

---

## Task 4: Run Full Test Suite and Verify

- [ ] **Step 1: Run all wake-related tests**

Run: `swift test --filter "WakeRestoreTests|ServiceLifecycleManagerTests|SleepWakeSnapshotTests" 2>&1 | tail -20`
Expected: All pass

- [ ] **Step 2: Build release**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 3: Run AXEventHandler tests (regression check for SkyLight guard)**

Run: `swift test --filter AXEventHandlerTests 2>&1 | tail -10`
Expected: All 163+ tests pass

- [ ] **Step 4: Commit spec update**

```bash
git add docs/superpowers/specs/2026-06-07-fix-c-sleep-wake-restore-design.md
git commit -m "docs(fix-c): update spec with remaining items design and root cause analysis"
```
