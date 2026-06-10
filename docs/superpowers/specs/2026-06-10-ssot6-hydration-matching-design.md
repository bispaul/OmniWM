# SSOT #6: RestorePlanner Hydration Matching

**Date:** 2026-06-10
**Build:** 97
**Branch:** fix/scope-relayout-to-workspace
**Memorygraph:** `0486d6ce` (Bug #27), `6ab03ce1` (5 SSOT invariants)

## Problem

RestorePlanner persists a window restore catalog to disk (`~/.local/state/omniwm/runtime-state.json`) with entries containing bundleId, role, subrole, title, workspace, niriPlacement, and monitor preference. On restart, it should match current windows to catalog entries and restore workspace/column positions.

**Two failures:**

1. **Matching fails.** The fallback `ManagedReplacementMetadata` in `prepareCreateCandidate` (AXEventHandler.swift:2039-2048) sets `role: nil, subrole: nil, title: nil, windowLevel: nil, parentWindowId: nil, frame: nil`. The catalog stores `role: "AXWindow", subrole: "AXStandardWindow"`. Soft match compares with `==`, so `nil != "AXWindow"` → 0 matches → hydration never fires.

2. **noMatch spam.** `plannedPersistedHydrationMutation` is called on every `recordReconcileEvent` — focus changes, workspace assignments, hidden state changes — not just window admission. 86 noMatch log entries in 30 minutes of normal operation.

## Root Cause

All discriminating fields (`role`, `subrole`, `title`, `windowLevel`, `parentWindowId`, `frame`) are available in `evaluation.facts` at admission time via `AXWindowFacts` and `WindowServerInfo`, but the fallback path explicitly discards them by passing nil.

The `managedReplacementCorrelator` path (for destroy→create pairs) does populate these fields. The fallback path (first window of each app, or no prior destroy to correlate) does not.

## Expert Panel Review (5 agents)

| Expert | Verdict |
|--------|---------|
| Architect | Approach A at 4.8/5. Preserves design intent, minimal coupling. |
| Devil's Advocate | Found multi-match rejection: `matches.count == 1` guard rejects Chrome (3 identical entries). **Resolved by populating title** — Chrome windows have different tab titles → unique keys. |
| Coder | Mechanically correct. `evaluation.facts.ax.role`, `.subrole`, `.title` confirmed as exact paths. |
| Apple SDK | AX roles stable post-creation. `AXWindow` + `AXStandardWindow` is standard. No edge cases. |
| Event Scoping | Only `windowAdmitted` + `windowRekeyed` should trigger hydration. Consumption tracking already prevents double-processing — spam is pure log noise. |

## Design

### Change 1: Populate fallback metadata

**File:** `Sources/OmniWM/Core/Controller/AXEventHandler.swift`
**Location:** `prepareCreateCandidate`, fallback `ManagedReplacementMetadata` construction (~line 2039-2048)

Replace nil fields with values from `evaluation.facts`:

```swift
// Before:
ManagedReplacementMetadata(
    bundleId: resolvedBundleId,
    workspaceId: workspaceId,
    mode: trackedMode,
    role: nil,
    subrole: nil,
    title: nil,
    windowLevel: nil,
    parentWindowId: nil,
    frame: nil
)

// After:
ManagedReplacementMetadata(
    bundleId: resolvedBundleId,
    workspaceId: workspaceId,
    mode: trackedMode,
    role: evaluation.facts.ax.role,
    subrole: evaluation.facts.ax.subrole,
    title: evaluation.facts.ax.title,
    windowLevel: evaluation.facts.windowServer?.level,
    parentWindowId: evaluation.facts.windowServer?.parentId,
    frame: evaluation.facts.windowServer?.frame
)
```

**Effect:** Catalog entries will have title populated → Chrome windows become distinguishable. Soft match by bundleId+role+subrole+title will succeed. `matches.count == 1` guard passes for both single-window and multi-window apps.

### Change 2: Scope hydration to admission events

**File:** `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift`
**Location:** `recordReconcileEvent` (~line 320)

Guard the `plannedPersistedHydrationMutation` call to only fire for `windowAdmitted` and `windowRekeyed` events:

```swift
// Before:
let persistedHydration = event.token.flatMap { plannedPersistedHydrationMutation(for: $0) }

// After:
let persistedHydration: PersistedHydrationMutation?
if event.isAdmissionEvent {
    persistedHydration = event.token.flatMap { plannedPersistedHydrationMutation(for: $0) }
} else {
    persistedHydration = nil
}
```

Add computed property on `WMEvent`:
```swift
var isAdmissionEvent: Bool {
    switch self {
    case .windowAdmitted, .windowRekeyed: return true
    default: return false
    }
}
```

**Effect:** Eliminates 86 noMatch log entries per 30 minutes. Hydration only fires when a window first enters the system.

## What This Enables

After restart, windows return to their previous:
- **Workspace** (e.g., VSCode on WS1, Slack on WS6)
- **Niri column position** (column index, tile index, width proportion)
- **Monitor** (which display the workspace was on)
- **Floating frame** (if the window was floating)

## What This Does NOT Change

- Hard match path (pid+windowId) still exists for same-session replacement correlation
- `managedReplacementCorrelator` path unchanged — it already populates metadata correctly
- Catalog persistence timing unchanged — saves are already scheduled on window changes
- `matches.count == 1` guard unchanged — title disambiguation handles multi-window apps
- No new persistence format — same `runtime-state.json` structure

## Edge Cases

| Case | Behavior |
|------|----------|
| AX attribute fetch fails | `role`/`subrole`/`title` will be nil → falls back to current behavior (no match). No regression. |
| Two Chrome windows with same tab title | Soft match returns 2 → `matches.count == 1` rejects. Same as current behavior. No regression. |
| Window count changed between sessions | Extra catalog entries are unconsumed. Missing windows just don't match. Graceful degradation. |
| Title changes after admission | Catalog stores title at last save, metadata has title at admission. Match uses admission-time title. May differ if tab changed — acceptable. |

## Test Plan

1. **Unit test:** Verify soft match succeeds when metadata has role+subrole+title populated
2. **Unit test:** Verify hydration only fires for `windowAdmitted`/`windowRekeyed` events
3. **Unit test:** Verify multi-window disambiguation by title (3 Chrome entries with different titles → each matches uniquely)
4. **Runtime:** Restart Hiro, check logs for `planPersistedHydration: matched` instead of `noMatch`
5. **Runtime:** Verify windows return to correct workspaces after restart
6. **Runtime:** Confirm 0 noMatch spam for non-admission events

## Files Changed

1. `Sources/OmniWM/Core/Controller/AXEventHandler.swift` — populate fallback metadata
2. `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift` — scope hydration events
3. `Sources/OmniWM/Core/Reconcile/WMEvent.swift` — add `isAdmissionEvent` computed property
4. `Tests/OmniWMTests/` — new hydration matching tests
