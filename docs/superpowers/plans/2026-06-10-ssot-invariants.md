# SSOT Invariant System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish 3 SSOT invariants (display coalescing, focus reconciliation, workspace assignment gate) plus extract WorkspaceAssignmentManager from the 248-edge god node.

**Architecture:** Layered Gates — each invariant is an independent gate with its own tests. Extraction before building: WorkspaceAssignmentManager extracted from WorkspaceManager before the central assignment gate is added. Session-only persistence via in-memory correlation.

**Tech Stack:** Swift 6.3, Apple Testing framework, @MainActor concurrency, macOS Accessibility API, SkyLight private APIs.

**Spec:** `docs/superpowers/specs/2026-06-10-ssot-invariants-design.md`

**Constitution:** `CLAUDE.md` — Gate 0 reproduction, TDD, CodeRabbit before commit, Graphify update, all 9 systems sync.

---

## File Structure

### Build 92 (Display Coalescing)
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` — add debounce field + modify `handleMonitorConfigurationChanged()`
- Test: `Tests/OmniWMTests/ServiceLifecycleManagerTests.swift` — coalescing test

### Build 93 (Focus Reconciliation)
- Modify: `Sources/OmniWM/Core/Controller/WMController.swift` — add `reconcileMacOSFocus()` + `isSystemUIActive()`
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift` — call reconciliation after focus confirmation
- Test: `Tests/OmniWMTests/AXEventHandlerTests.swift` — focus reconciliation test

### Build 94 (WorkspaceAssignmentManager Extraction)
- Create: `Sources/OmniWM/Core/Workspace/WorkspaceAssignmentManager.swift` — extracted type
- Modify: `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift` — delegate to extracted type
- Test: existing tests must continue passing (pure extraction, no behavior change)

### Build 95 (Central Gate + Cache)
- Modify: `Sources/OmniWM/Core/Workspace/WorkspaceAssignmentManager.swift` — add gate + cache + reason enum
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift` — refactor trackPreparedCreate to use gate
- Test: `Tests/OmniWMTests/WorkspaceAssignmentManagerTests.swift` — gate + cache tests

---

## Build 92: Display Event Coalescing

### Task 1: Add debounce to handleMonitorConfigurationChanged

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift:69,256`
- Test: `Tests/OmniWMTests/ServiceLifecycleManagerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test @MainActor func displayEventsAreCoalescedIntoSingleReconfiguration() async {
    let controller = makeServiceLifecycleTestController()
    var reconfigCount = 0
    controller.serviceLifecycleManager.applyMonitorConfigurationChangedCountForTests = {
        reconfigCount += 1
    }

    // Fire 5 rapid display events
    for _ in 0..<5 {
        controller.serviceLifecycleManager.handleDisplayEvent(.connected(monitorId: .init(displayId: 2)))
    }

    // Wait for debounce to settle (300ms + margin)
    try? await Task.sleep(nanoseconds: 400_000_000)

    #expect(reconfigCount == 1, "5 rapid events should coalesce into 1 reconfiguration")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "displayEventsAreCoalescedIntoSingleReconfiguration"`
Expected: FAIL (no debounce exists yet, fires 5 times)

- [ ] **Step 3: Add debounce field to ServiceLifecycleManager**

At `ServiceLifecycleManager.swift:69` (after existing Task properties):
```swift
private var pendingTopologyTask: Task<Void, Never>?
private static let topologyCoalesceInterval: UInt64 = 300_000_000 // 300ms
```

- [ ] **Step 4: Modify handleMonitorConfigurationChanged**

Replace `ServiceLifecycleManager.swift:256`:
```swift
private func handleMonitorConfigurationChanged() {
    pendingTopologyTask?.cancel()
    pendingTopologyTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: Self.topologyCoalesceInterval)
        guard !Task.isCancelled, let self else { return }
        applyMonitorConfigurationChanged(currentMonitors: Monitor.current())
    }
}
```

- [ ] **Step 5: Add ForTests hook for counting**

Add to ServiceLifecycleManager:
```swift
var applyMonitorConfigurationChangedCountForTests: (() -> Void)?
```

At the top of `applyMonitorConfigurationChanged(currentMonitors:)`:
```swift
applyMonitorConfigurationChangedCountForTests?()
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter "displayEventsAreCoalescedIntoSingleReconfiguration"`
Expected: PASS

- [ ] **Step 7: Run full SLM test suite**

Run: `swift test --filter "ServiceLifecycleManager"`
Expected: all existing tests pass

- [ ] **Step 8: Format + lint**

Run: `make format-check && make lint`
Expected: 0 files need formatting, 0 serious violations

- [ ] **Step 9: Commit Build 92**

```bash
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift Tests/OmniWMTests/ServiceLifecycleManagerTests.swift
git commit -m "[fix/scope-relayout-to-workspace] - fix: coalesce display topology events with 300ms trailing-edge debounce (build 92)

handleMonitorConfigurationChanged now cancels pending task and schedules
a new 300ms sleep before calling applyMonitorConfigurationChanged. Reads
full current topology on fire (Monitor.current()), not buffered deltas.
Dark wake with 2 external displays: 1-2 rescans instead of 7.

SSOT invariant #3 (display event coalescing). Build 92.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

- [ ] **Step 10: Deploy + verify**

```bash
swift build -c debug
pkill -x OmniWM; sleep 1; .build/debug/OmniWM &disown
sleep 2; .build/debug/omniwmctl ping
# Verify: sleep Mac, wake, check log for rescan count
/usr/bin/log show --predicate 'processIdentifier == <PID> AND subsystem == "com.omniwm"' --last 2m --info --debug | grep "Full rescan" | wc -l
# Expected: 1-2 (not 7)
```

---

## Build 93: Focus Reconciliation

### Task 2: Add reconcileMacOSFocus to WMController

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/WMController.swift:2831`
- Test: `Tests/OmniWMTests/AXEventHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test @MainActor func focusReconciliationCallsPerformWindowFrontingOnNativeAppSwitch() async {
    let controller = makeAXEventTestController()
    guard let workspaceId = controller.activeWorkspace()?.id else {
        Issue.record("Missing active workspace")
        return
    }

    let windowId: UInt32 = 950
    let pid = getpid()
    let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))

    _ = controller.workspaceManager.addWindow(
        axRef, pid: pid, windowId: Int(windowId), to: workspaceId
    )

    var frontingCalls: [WindowToken] = []
    controller.focusReconciliationHookForTests = { token in
        frontingCalls.append(token)
    }

    // Simulate managedFocusConfirmed event
    controller.axEventHandler.cgsEventObserver(
        CGSEventObserver.shared,
        didReceive: .frontAppChanged(pid: pid)
    )

    #expect(!frontingCalls.isEmpty, "Focus reconciliation should call performWindowFronting after nativeAppSwitch")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "focusReconciliationCallsPerformWindowFrontingOnNativeAppSwitch"`
Expected: FAIL (focusReconciliationHookForTests doesn't exist yet)

- [ ] **Step 3: Add isSystemUIActive and reconcileMacOSFocus to WMController**

At `WMController.swift` near `performWindowFronting` (line ~2831):

```swift
var focusReconciliationHookForTests: ((WindowToken) -> Void)?

func reconcileMacOSFocus(to token: WindowToken) {
    guard let entry = workspaceManager.entry(for: token),
          !isSystemUIActive(),
          focusPolicyEngine.activeLease?.suppressesFocusFollowsMouse != true
    else { return }

    focusReconciliationHookForTests?(token)
    performWindowFronting(pid: entry.pid, windowId: entry.windowId, axRef: entry.axRef)
}

private func isSystemUIActive() -> Bool {
    if isLockScreenActive { return true }
    guard let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
    let systemBundleIds = [
        "com.apple.Spotlight",
        "com.apple.SecurityAgent",
        "com.apple.notificationcenterui",
        "com.apple.dock"
    ]
    return systemBundleIds.contains(frontBundle)
}
```

- [ ] **Step 4: Wire reconciliation into focus confirmation path**

In `WMController.swift`, find `confirmManagedFocus` (around line 1041) where `managedFocusConfirmed` events are emitted. After the focus border update (`focusBorderController.focusChanged`), add:

```swift
reconcileMacOSFocus(to: token)
```

Also wire it after `handleManagedAppActivation` resolves focus (search for `managedFocusConfirmed` emission points — there are ~3, all need reconciliation).

**Note:** Test helpers `makeServiceLifecycleTestController` and `makeWorkspaceAssignmentTestController` need to be created following the existing `makeAXEventTestController` pattern — minimal WMController with ForTests closures.

**Note:** Spec A2 (ManagedReplacementCorrelator enhancement for native fullscreen detection) is deferred to a follow-up build. The cache (A3) handles the native fullscreen workspace preservation as the primary mechanism for v1. If the cache proves insufficient (timing edge cases), A2 will be added as a refinement.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter "focusReconciliationCallsPerformWindowFrontingOnNativeAppSwitch"`
Expected: PASS

- [ ] **Step 6: Write guard tests**

```swift
@Test @MainActor func focusReconciliationSkippedWhenFocusPolicyLeaseActive() async {
    let controller = makeAXEventTestController()
    // ... setup window ...
    controller.focusPolicyEngine.beginLease(
        owner: .ruleCreatedFloatingWindow,
        reason: "test",
        suppressesFocusFollowsMouse: true,
        duration: 5.0
    )
    var frontingCalls: [WindowToken] = []
    controller.focusReconciliationHookForTests = { token in
        frontingCalls.append(token)
    }
    // Trigger focus change...
    #expect(frontingCalls.isEmpty, "Should skip reconciliation when suppressing lease is active")
}
```

- [ ] **Step 7: Run full AXEventHandler tests**

Run: `swift test --filter "AXEventHandlerTests"`
Expected: all 165+ tests pass

- [ ] **Step 8: Format + lint + commit Build 93**

```bash
make format-check && make lint
git add Sources/OmniWM/Core/Controller/WMController.swift Sources/OmniWM/Core/Controller/AXEventHandler.swift Tests/OmniWMTests/AXEventHandlerTests.swift
git commit -m "[fix/scope-relayout-to-workspace] - fix: always-sync focus reconciliation with macOS keyboard focus (build 93)

After managedFocusConfirmed, call reconcileMacOSFocus which invokes
performWindowFronting (activateApp + focusSpecificWindow + raiseWindow)
to transfer macOS keyboard focus to match Hiro internal focus.

Guards: isSystemUIActive (Spotlight, SecurityAgent, Dock, lock screen),
FocusPolicyLease.suppressesFocusFollowsMouse (floating window create).

Fixes Bug #24: border showed Slack but Caps+F went to Chrome because
nativeAppSwitch updated internal focus without macOS keyboard transfer.

SSOT invariant #5 (focus reconciliation). Build 93.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

- [ ] **Step 9: Deploy + verify Bug #24 fix**

```bash
swift build -c debug
pkill -x OmniWM; sleep 1; .build/debug/OmniWM &disown
sleep 2; .build/debug/omniwmctl ping
# Test: focus Chrome on 32" display, then click Slack on portrait display
# Press Caps+F — should toggleFullscreen on Slack (not Chrome)
```

---

## Build 94: WorkspaceAssignmentManager Extraction

### Task 3: Extract workspace assignment methods from WorkspaceManager

**Files:**
- Create: `Sources/OmniWM/Core/Workspace/WorkspaceAssignmentManager.swift`
- Modify: `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift:2229,2693`

- [ ] **Step 1: Create WorkspaceAssignmentManager with addWindow forwarding**

```swift
@MainActor
final class WorkspaceAssignmentManager {
    private unowned let workspaceManager: WorkspaceManager

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    @discardableResult
    func addWindow(
        _ ax: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        to workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowToken {
        workspaceManager.addWindow(
            ax, pid: pid, windowId: windowId, to: workspace,
            mode: mode, ruleEffects: ruleEffects,
            managedReplacementMetadata: managedReplacementMetadata
        )
    }

    func setWorkspace(for token: WindowToken, to workspace: WorkspaceDescriptor.ID) {
        workspaceManager.setWorkspace(for: token, to: workspace)
    }
}
```

- [ ] **Step 2: Add WorkspaceAssignmentManager property to WorkspaceManager**

```swift
private(set) lazy var assignmentManager = WorkspaceAssignmentManager(workspaceManager: self)
```

- [ ] **Step 3: Verify build compiles**

Run: `swift build -c debug`
Expected: compiles (no callers changed yet — pure addition)

- [ ] **Step 4: Run full test suite for workspace tests**

Run: `swift test --filter "WorkspaceManager"`
Expected: all pass (no behavior change)

- [ ] **Step 5: Format + lint + commit Build 94**

```bash
make format-check && make lint
git add Sources/OmniWM/Core/Workspace/WorkspaceAssignmentManager.swift Sources/OmniWM/Core/Workspace/WorkspaceManager.swift
git commit -m "[fix/scope-relayout-to-workspace] - refactor: extract WorkspaceAssignmentManager from WorkspaceManager (build 94)

New @MainActor class owns addWindow and setWorkspace forwarding.
Pure extraction — no behavior change, no callers modified yet.
Prepares for central workspace assignment gate in build 95.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Build 95: Central Gate + Cache

### Task 4: Add WorkspaceAssignmentReason enum and central gate

**Files:**
- Modify: `Sources/OmniWM/Core/Workspace/WorkspaceAssignmentManager.swift`
- Test: `Tests/OmniWMTests/WorkspaceAssignmentManagerTests.swift`

- [ ] **Step 1: Write failing test for central gate**

Create `Tests/OmniWMTests/WorkspaceAssignmentManagerTests.swift`:

```swift
import Testing
@testable import OmniWM

@Suite(.serialized) struct WorkspaceAssignmentManagerTests {
    @Test @MainActor func assignWindowPreservesWorkspaceFromCacheForRecentlyRemoved() async {
        let controller = makeWorkspaceAssignmentTestController()
        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing workspaces")
            return
        }

        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 800)
        let token = controller.workspaceManager.addWindow(
            axRef, pid: getpid(), windowId: 800, to: ws1
        )

        // Remove window (simulating native fullscreen destroy)
        controller.workspaceManager.removeWindow(token)

        // Re-admit within cache window — should get ws1 back, not ws2
        let result = controller.workspaceManager.assignmentManager.assignWindowToWorkspace(
            axRef, pid: getpid(), windowId: 800, to: ws2, reason: .admission
        )

        let entry = controller.workspaceManager.entry(for: result)
        #expect(entry?.workspaceId == ws1, "Recently-removed window should be restored to cached workspace, not target")
    }

    @Test @MainActor func assignWindowUsesTargetWorkspaceWhenNoCacheHit() async {
        let controller = makeWorkspaceAssignmentTestController()
        guard let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing workspace")
            return
        }

        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 801)
        let result = controller.workspaceManager.assignmentManager.assignWindowToWorkspace(
            axRef, pid: getpid(), windowId: 801, to: ws2, reason: .admission
        )

        let entry = controller.workspaceManager.entry(for: result)
        #expect(entry?.workspaceId == ws2, "No cache hit — should use target workspace")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "WorkspaceAssignmentManagerTests"`
Expected: FAIL (assignWindowToWorkspace doesn't exist yet)

- [ ] **Step 3: Add reason enum and cache to WorkspaceAssignmentManager**

```swift
enum WorkspaceAssignmentReason {
    case admission
    case transfer
    case nativeFullscreen
    case displayReconfigure
}

@MainActor
final class WorkspaceAssignmentManager {
    private unowned let workspaceManager: WorkspaceManager
    private var recentlyRemovedWorkspaces: [RecentRemovalKey: RecentRemoval] = []

    private struct RecentRemovalKey: Hashable {
        let pid: pid_t
        let bundleId: String?
    }

    private struct RecentRemoval {
        let workspaceId: WorkspaceDescriptor.ID
        let removedAt: Date
    }

    private static let cacheExpiryInterval: TimeInterval = 2.0

    func recordRemoval(token: WindowToken, workspaceId: WorkspaceDescriptor.ID, bundleId: String?) {
        let key = RecentRemovalKey(pid: token.pid, bundleId: bundleId)
        recentlyRemovedWorkspaces[key] = RecentRemoval(workspaceId: workspaceId, removedAt: Date())
    }

    private func cachedWorkspace(pid: pid_t, bundleId: String?) -> WorkspaceDescriptor.ID? {
        let key = RecentRemovalKey(pid: pid, bundleId: bundleId)
        guard let removal = recentlyRemovedWorkspaces[key],
              Date().timeIntervalSince(removal.removedAt) < Self.cacheExpiryInterval
        else {
            recentlyRemovedWorkspaces.removeValue(forKey: key)
            return nil
        }
        return removal.workspaceId
    }

    @discardableResult
    func assignWindowToWorkspace(
        _ ax: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        to targetWorkspace: WorkspaceDescriptor.ID,
        reason: WorkspaceAssignmentReason,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowToken {
        let token = WindowToken(pid: pid, windowId: windowId)

        // Dedup: skip if already tracked
        if workspaceManager.entry(for: token) != nil {
            WMLog.workspace.info("assignWindowToWorkspace: skipping already-tracked \(windowId)")
            return token
        }

        // Cache lookup for recently-removed windows
        let bundleId = managedReplacementMetadata?.bundleId
        let resolvedWorkspace: WorkspaceDescriptor.ID
        if reason == .admission,
           let cached = cachedWorkspace(pid: pid, bundleId: bundleId) {
            WMLog.workspace.info("assignWindowToWorkspace: restored cached workspace for \(windowId)")
            resolvedWorkspace = cached
        } else {
            resolvedWorkspace = targetWorkspace
        }

        return workspaceManager.addWindow(
            ax, pid: pid, windowId: windowId, to: resolvedWorkspace,
            mode: mode, ruleEffects: ruleEffects,
            managedReplacementMetadata: managedReplacementMetadata
        )
    }
}
```

- [ ] **Step 4: Wire removeWindow to populate cache**

In WorkspaceManager.removeWindow (find the method), before removing the entry:
```swift
if let entry = entry(for: token) {
    let bundleId = appInfoCache?.info(for: entry.pid)?.bundleId
    assignmentManager.recordRemoval(token: token, workspaceId: entry.workspaceId, bundleId: bundleId)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter "WorkspaceAssignmentManagerTests"`
Expected: PASS

- [ ] **Step 6: Refactor trackPreparedCreate to use central gate**

In AXEventHandler.swift, replace the direct addWindow call in trackPreparedCreate (~line 715):

```swift
// OLD:
let trackedToken = controller.workspaceManager.addWindow(...)

// NEW:
let trackedToken = controller.workspaceManager.assignmentManager.assignWindowToWorkspace(
    candidate.axRef,
    pid: candidate.token.pid,
    windowId: candidate.token.windowId,
    to: candidate.workspaceId,
    reason: .admission,
    mode: candidate.mode,
    ruleEffects: candidate.ruleEffects,
    managedReplacementMetadata: candidate.replacementMetadata
)
```

Remove the now-redundant dedup guard at line 703 (subsumed by the gate).

- [ ] **Step 7: Run full test suite**

Run: `swift test --filter "AXEventHandlerTests"`
Expected: all 166+ tests pass (including the dedup test, which now exercises the gate)

- [ ] **Step 8: Format + lint + Graphify**

```bash
make format-check && make lint
graphify update Sources/
# Check: WorkspaceManager edge count should decrease (addWindow callers now go through AssignmentManager)
```

- [ ] **Step 9: Commit Build 95**

```bash
git add Sources/OmniWM/Core/Workspace/WorkspaceAssignmentManager.swift Sources/OmniWM/Core/Workspace/WorkspaceManager.swift Sources/OmniWM/Core/Controller/AXEventHandler.swift Tests/OmniWMTests/WorkspaceAssignmentManagerTests.swift
git commit -m "[fix/scope-relayout-to-workspace] - feat: central workspace assignment gate with cache (build 95)

WorkspaceAssignmentManager.assignWindowToWorkspace() is the single gate
for all workspace assignments. Includes:
- WorkspaceAssignmentReason enum (.admission/.transfer/.nativeFullscreen/.displayReconfigure)
- Dedup guard (subsumes build 91 guard)
- Recently-removed workspace cache (2s TTL, keyed by pid+bundleId)

Cache restores workspace for windows destroyed during native fullscreen
(green button destroy/create cycle) by matching the recreated window to
the cached workspace from the destroyed entry.

Fixes Bug #23: Slack on WS6 → green button → placeholder stays on WS6.

SSOT invariants #1+#2+#4 (window identity + workspace assignment + hydration).
Build 95.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

- [ ] **Step 10: Deploy + verify Bug #23 fix**

```bash
swift build -c debug
pkill -x OmniWM; sleep 1; .build/debug/OmniWM &disown
sleep 2; .build/debug/omniwmctl ping
# Test: put Slack on WS6 (portrait), press green button
# Check IPC: omniwmctl query windows --app Slack
# Expected: workspace=WS6 with layoutReason=native-fullscreen (not WS1)
```

---

## Post-Implementation Checklist

After all 4 builds are deployed:

- [ ] **Success criteria verification:**
  - Bug #23: Slack on WS6 → green button → placeholder stays on WS6
  - Bug #24: Move to portrait, hover Slack, Caps+F → toggleFullscreen goes to Slack
  - Dark wake: <=2 full rescans after display reconnect
  - Zoom launch: 0 duplicate "Adding window" log entries

- [ ] **Graphify coupling check:**
  ```bash
  graphify update Sources/
  graphify explain WorkspaceManager --graph Sources/graphify-out/graph.json
  # Expected: edge count <= 248 (not worse)
  ```

- [ ] **30-minute soak test:**
  - Stream logs: `log stream --predicate 'subsystem == "com.omniwm"' --info --debug`
  - No error-level spam, no crash loops
  - Switch workspaces, move windows, focus across displays

- [ ] **All 9 systems updated:**
  CLAUDE.md, Serena, Memorygraph, Memory MCP, MEMORY.md, evaluation, next-session, Graphify, hooks
