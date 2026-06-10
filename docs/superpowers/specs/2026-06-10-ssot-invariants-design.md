# SSOT Invariant System Design — OmniWM/Hiro

**Date:** 2026-06-10
**Build:** 91 (branch: fix/scope-relayout-to-workspace)
**Scope:** Comprehensive SSOT — 3 independent concerns, session-only persistence
**Architecture:** Layered Gates with pre-extraction (architect + devil's advocate synthesis)
**Revision:** v2 — incorporates 4-panel expert review (architect 3.9/5 CONDITIONAL PASS, coder critical issues, debugger 6 edge cases, devil's advocate key revision)

## Context

Phase 1-5 + Fix A/B/C/E established individual data paths but never ensured **exclusivity**. 6 missing SSOT invariants were identified, collapsing into 3 independent concerns plus 1 completed fix. Upstream (BarutSRB/Hiro) is dead — we own the codebase. This design addresses the remaining 3 concerns as a coherent system.

## CRITICAL REVISION: Extract Before Building (Devil's Advocate)

WorkspaceManager is a 248-edge god node. The original design added assignWindowToWorkspace() + cache + enum directly to it — feeding the monster. **Revised approach: extract WorkspaceAssignmentManager first** (build 92), then implement concerns against the extracted type (builds 93-95). This prevents god node acceleration and ensures the Graphify success criteria passes.

## Expert Review Corrections

| Original Spec Error | Correction | Source |
|---|---|---|
| 5 addWindow call sites | Actually 3: AXEventHandler:715, LRC:1357, WMController:2228 | Coder |
| atomicTransferWindow calls addWindow | It calls reassignManagedWindow → setWorkspace (different mechanism) | Coder |
| NFS record path calls addWindow | It updates nativeFullscreenRecordsByOriginalToken only (metadata) | Coder |
| kAXFocusedAttribute for focus sync | Read-only on most apps. Use performWindowFronting (activateApp + focusSpecificWindow + raiseWindow) | Coder |
| MonitorService.currentMonitors() | Does not exist. Use Monitor.current() | Architect + Coder |
| isDragInProgress property | Does not exist. Use focusPolicyEngine lease system | Coder |
| isSystemUIActive checks | Missing Dock (com.apple.dock for Cmd+Tab) and recency guard | Debugger |
| ContinuousClock.Instant for cache | Not used in codebase. Use Date or DispatchTime | Coder |

## Known Limitations (Intentional)

- **Crash/restart recovery:** Session-only persistence means kill → relaunch loses all workspace state. bootPersistedWindowRestoreCatalog is stale. Windows scatter to WS1. This is a conscious scope decision — fixing requires disk persistence (deferred).
- **Timing constants:** 100ms correlator, 300ms debounce, 500ms cache, 2s TTL are from one M-series Mac. May need tuning for Intel/load. Consider making configurable via settings.toml.

## Concern A: Window State Continuity (Invariants 1+2+4)

### Problem

5 independent workspace assignment paths exist with no central gate. When macOS destroys and recreates windows (native fullscreen green button, display disconnect), workspace identity is lost because:
1. `suspendManagedWindowForNativeFullscreen` never fires (window destroyed before fullscreen detected)
2. New window admitted to active workspace on whatever display macOS reports
3. No mechanism to correlate the new window back to the destroyed entry's workspace

### Design

**A1. Central `assignWindowToWorkspace()` gate** on WorkspaceManager.

```swift
enum WorkspaceAssignmentReason {
    case admission          // processCreatedWindow → trackPreparedCreate
    case transfer           // atomicTransferWindow, moveToWorkspace
    case nativeFullscreen   // correlator-detected fullscreen destroy/create
    case displayReconfigure // display disconnect/reconnect reassignment
    case nfsRecord          // native fullscreen record update
}

func assignWindowToWorkspace(
    _ token: WindowToken,
    to workspaceId: WorkspaceDescriptor.ID,
    reason: WorkspaceAssignmentReason,
    preserveNativeFullscreenRecord: Bool = true
) -> WindowToken
```

**CORRECTED (per coder review): 3 addWindow paths + 2 non-addWindow paths:**

Admission paths (call addWindow → refactor to assignWindowToWorkspace):
- Path 1: `trackPreparedCreate` (AXEventHandler:715) → `.admission`
- Path 2: LRC rescan (LRC:1357) → `.admission`
- Path 3: WMController discovery (WMController:2228) → `.admission`

Non-admission paths (don't call addWindow — different mechanism):
- Path 4: `atomicTransferWindow` (WNH) → calls `reassignManagedWindow` → `setWorkspace`. Gate intercepts `setWorkspace` with `.transfer` reason.
- Path 5: NFS record (WM:1102) → updates `nativeFullscreenRecordsByOriginalToken` only (metadata). Gate not needed — metadata sync handled by A1's `preserveNativeFullscreenRecord` parameter.

The gate:
- Validates workspace exists (creates if missing for display reconfigure)
- Syncs `nativeFullscreenRecordsByOriginalToken` when `preserveNativeFullscreenRecord` is true
- Logs uniformly: `WMLog.workspace.info("assignWindowToWorkspace: token=\(token) workspace=\(id) reason=\(reason)")`
- The existing admission dedup guard (build 91) is subsumed — the gate checks `entry(for: token)` and handles duplicates via reason-specific logic

**A2. ManagedReplacementCorrelator workspace preservation.**

When the correlator matches a destroy+create pair:
- Check if the destroyed entry had `layoutReason == .nativeFullscreen` OR had a `nativeFullscreenRecord`
- If yes AND timing ≤100ms: preserve `destroyedEntry.workspaceId` and pass to the create path as `assignWindowToWorkspace(.nativeFullscreen)`
- If no: normal correlation (existing behavior)

The 100ms window (not 300ms) prevents false positives on:
- Intentional app restart (Cmd+Q + relaunch) — typically >500ms
- Tab detach in Chrome/Electron — different windowId
- App crash + restart — new PID

**A3. WorkspaceAssignmentCache** — ephemeral in-memory cache.

```swift
private var recentlyRemovedWorkspaces: [WindowToken: (workspaceId: WorkspaceDescriptor.ID, removedAt: ContinuousClock.Instant)] = []
```

On `removeWindow`: store the window's workspace in the cache with timestamp.
On `assignWindowToWorkspace(.admission)`: check cache first — if a recently-removed token matches (same pid+bundleId, ≤500ms), use the cached workspace instead of the active workspace.
Cache entries expire after 2 seconds. Cleaned up lazily on access.

This handles the native fullscreen case AND display disconnect window churn without modifying the correlator's existing matching logic.

**A2/A3 interaction:** The correlator (A2) is the primary mechanism — it matches destroy+create pairs with fullscreen context. The cache (A3) is the fallback for cases the correlator misses (e.g., timing >100ms, or events the correlator doesn't see). Both feed into the central gate (A1) which makes the final assignment.

### Devil's Advocate Mitigations
- **False positive on app restart:** 100ms timing window + fullscreen flag check prevents. Crash-restart (PID change) is a known limitation — won't match.
- **Lost preconditions:** `reason` enum carries path-specific context; gate switches on reason for path-specific validation
- **God node avoidance:** Gate lives on extracted WorkspaceAssignmentManager (build 94), NOT on WorkspaceManager directly. Extraction first.
- **Timing constants:** Consider making configurable via settings.toml for different hardware profiles.

### Debugger Edge Cases (from expert review)
- **Display disconnect during fullscreen:** Gate must validate target workspace's display still exists for ALL reasons, not just `.displayReconfigure`. If target display disconnected, fall back to active workspace on a remaining display.
- **applyMonitorConfigurationChanged bypass:** Make the method `private` after debounce is added, forcing all callers through the debounced path. Document that wake-restore has its own direct path via `requestFullRescan`.
- **Cross-concern timing:** If debounce (300ms) fires while correlator (100ms) has already assigned a workspace, the full-rescan must NOT overwrite the correlator's assignment. The gate's `.nativeFullscreen` reason should take priority over `.displayReconfigure` for the same token within a time window.

### Files
- `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift` — gate method + cache + reason enum
- `Sources/OmniWM/Core/Controller/AXEventHandler.swift` — refactor trackPreparedCreate to use gate
- `Sources/OmniWM/Core/Controller/LayoutRefreshController.swift` — refactor NFS placeholder path
- `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` — refactor display disconnect path
- `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift` — refactor atomicTransfer
- `Sources/OmniWM/Core/Controller/AXEventHandler+ManagedReplacement.swift` — correlator workspace preservation

### Tests
- Unit: assign same token twice with same reason → idempotent
- Unit: assign with `.nativeFullscreen` reason → preserves original workspace
- Unit: cache lookup for recently-removed token → returns cached workspace
- Unit: cache entry expires after 2s → falls through to active workspace
- Integration: simulate destroy+create within 100ms with fullscreen flag → workspace preserved
- Runtime: Slack on WS6, green button → IPC shows placeholder on WS6 (not WS1)

---

## Concern B: Display Event Coalescing (Invariant 3)

### Problem

`ServiceLifecycleManager.handleMonitorConfigurationChanged()` fires independently per display event. Dark wake with 2 external displays: 5 events → 7 full rescans in 4 seconds. DisplayConfigurationObserver's 100ms debounce only delays emission, doesn't coalesce.

### Design

**B1. Trailing-edge debounce in ServiceLifecycleManager.**

```swift
private var pendingTopologyTask: Task<Void, Never>?
private static let topologyCoalesceInterval: UInt64 = 300_000_000 // 300ms

func handleMonitorConfigurationChanged() {
    pendingTopologyTask?.cancel()
    pendingTopologyTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: Self.topologyCoalesceInterval)
        guard !Task.isCancelled else { return }
        let currentMonitors = MonitorService.currentMonitors()
        applyMonitorConfigurationChanged(currentMonitors: currentMonitors)
    }
}
```

Key behaviors:
- **Trailing edge:** each new event resets the timer — only fires after 300ms of silence
- **Full reconciliation:** when it fires, reads ALL current monitors (not just the delta) — handles the devil's advocate concern about hot-plugging multiple monitors
- **Reuses existing pattern:** same `Task.sleep + cancellation` as DisplayConfigurationObserver:50-56

### Devil's Advocate Mitigations
- **300ms too long for single display:** Worst case is 300ms delay before layout updates after plugging in a monitor — acceptable UX tradeoff vs 7 redundant rescans
- **Events lost during coalescing:** No events lost — the handler reads full current state when it fires, not buffered deltas
- **Rapid legitimate changes:** The trailing edge resets on each event, so rapid real changes don't fire until they settle

### Files
- `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` — add field + modify handleMonitorConfigurationChanged

### Tests
- Unit: fire 5 rapid display events → verify applyMonitorConfigurationChanged called exactly once
- Unit: fire events 400ms apart → verify called twice (not coalesced)
- Runtime: sleep Mac, wake, count rescans in log (should be 1-2 instead of 7)

---

## Concern C: Focus Reconciliation (Invariant 5)

### Problem

When Hiro's internal focus changes via `workspaceDidActivateApplication` (nativeAppSwitch), it updates `sessionState.focus` and the border, but does NOT call `AXUIElementSetAttributeValue` to transfer macOS keyboard focus. Result: border shows Slack, hotkeys go to Chrome.

### Design

**C1. Always-sync focus after internal focus change.**

**CORRECTED (per coder review):** `kAXFocusedAttribute` is read-only on most apps. Use the existing `performWindowFronting` pattern (activateApp + focusSpecificWindow + raiseWindow) which already works correctly in the codebase.

```swift
func reconcileMacOSFocus(to token: WindowToken) {
    guard let entry = workspaceManager.entry(for: token),
          !isSystemUIActive(),
          !focusPolicyEngine.hasActiveSuppressingLease() else { return }
    performWindowFronting(token: token, pid: entry.pid, windowId: entry.windowId, axRef: entry.axRef)
}
```

**C2. System UI guard** — expanded per debugger review.

```swift
private func isSystemUIActive() -> Bool {
    guard let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
    let systemBundleIds = [
        "com.apple.Spotlight",
        "com.apple.SecurityAgent",
        "com.apple.notificationcenterui",
        "com.apple.dock"  // Cmd+Tab app switcher (debugger finding)
    ]
    if systemBundleIds.contains(frontBundle) { return true }
    if isLockScreenActive { return true }  // Reuse existing guard (coder finding)
    return false
}
```

**C2b. FocusPolicyLease guard** (debugger finding):
- If a lease with `suppressesFocusFollowsMouse=true` is active, defer reconciliation until lease expires
- Prevents overriding floating-window-create lease (350ms)

**C2c. AX error handling** (debugger finding):
- Check return value of AX calls in performWindowFronting
- On `kAXErrorCannotComplete`: log warning, skip reconciliation for this cycle
- Prevents silent permanent desync when Accessibility permission is revoked

**C3. Reconciliation trigger points:**
- After `managedFocusConfirmed` event — the primary focus change path
- After `nativeAppSwitch` lease fires — when user activates an app on a different display
- NOT during `focusLeaseChanged` (too early — the focus target may not be resolved yet)

### Devil's Advocate Mitigations
- **Spotlight/auth dialogs:** System UI guard checks frontmost app bundle ID before syncing
- **Drag operations:** Track mouse-down/up state, skip sync during drags
- **Focus flicker:** Only sync when the target token actually CHANGED (not on every event)

### Files
- `Sources/OmniWM/Core/Controller/WMController.swift` — reconcileMacOSFocus method (WMController owns focus orchestration)
- `Sources/OmniWM/Core/Controller/AXEventHandler.swift` — add reconciliation call after focus confirmation

### Tests
- Unit: internal focus change → verify AX focus API called with correct token
- Unit: Spotlight active → verify AX focus API NOT called
- Unit: same token focused twice → verify API called only once
- Runtime: move to portrait display, hover Slack, Caps+F → toggleFullscreen goes to Slack (not Chrome)

---

## Concern D: Admission Dedup (Invariant 6) — REVIEW

### Current Fix (build 91, commit b02c172)

Guard in `trackPreparedCreate` at AXEventHandler:703 checks `controller.workspaceManager.entry(for: candidate.token) != nil` before calling `addWindow`.

### Expert Review Findings

**Architect:** The dedup guard is a single-path instance of the central gate pattern. Under Concern A, this guard would be subsumed by the central `assignWindowToWorkspace()` gate, which applies the same check across all 5 paths. Paths (2) LRC rescan and (3) WMController discovery currently lack this guard.

**Devil's advocate:** Risk if an app crashes and restarts with the same windowId — the guard could reject legitimate re-admission. Mitigated by the fact that `entry(for: token)` checks the exact `WindowToken(pid, windowId)` — a restart changes the PID, so the token won't match.

**Verdict:** Fix is correct for its scope. Will be generalized by the central gate in Concern A. The existing guard at AXEventHandler:703 remains active during builds 92-93 (before Concern A ships in build 94) — no changes needed until then.

---

## Execution Order

**REVISED (per devil's advocate): extract first, then build on clean foundation.**

1. **Build 92: Concern B** (display coalescing) — smallest scope, ~20 lines, no workspace state changes. Independent of extraction.
2. **Build 93: Concern C** (focus reconciliation) — medium scope, ~40 lines, fixes daily-use Bug #24. Independent of extraction.
3. **Build 94: Extract WorkspaceAssignmentManager** from WorkspaceManager — move addWindow, setWorkspace, workspace assignment logic, and the admission dedup guard into a focused type. Reduces WorkspaceManager coupling. NO new behavior — pure extraction.
4. **Build 95: Concern A** (window state continuity) — central gate + cache + correlator enhancement, implemented ON the extracted WorkspaceAssignmentManager. Fixes Bug #23 + subsumes dedup.

### Per-Build Verification
- `swift build -c debug` + `swift test --filter <relevant>` + `make format-check` + `make lint`
- CodeRabbit review on diff
- Graphify update + coupling check
- Deploy: kill → rebuild → launch → IPC ping → 30s log stream
- Specific runtime evidence for the concern being fixed
- All 9 persistence systems updated

---

## Success Criteria

After all 3 concerns are implemented:
- [ ] Bug #23: Slack on WS6 → green button → placeholder stays on WS6
- [ ] Bug #24: Move to portrait, hover Slack, Caps+F → toggleFullscreen goes to Slack
- [ ] Dark wake: ≤2 full rescans (not 7) after display reconnect
- [ ] Zoom launch: 0 duplicate "Adding window" log entries
- [ ] No regressions: all existing tests pass, 30min soak test with no error-level log spam
- [ ] Graphify: no new god nodes, no coupling increase on WorkspaceManager
