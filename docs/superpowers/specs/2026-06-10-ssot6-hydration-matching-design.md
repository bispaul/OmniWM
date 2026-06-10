# SSOT #6: RestorePlanner Hydration Matching

**Date:** 2026-06-10
**Build:** 97
**Branch:** fix/scope-relayout-to-workspace
**Memorygraph:** `0486d6ce` (Bug #27), `6ab03ce1` (5 SSOT invariants)

## Problem

RestorePlanner persists a window restore catalog to disk (`~/.local/state/omniwm/runtime-state.json`) with entries containing bundleId, role, subrole, title, workspace, niriPlacement, and monitor preference. On restart, it should match current windows to catalog entries and restore workspace/column positions.

**Two failures:**

1. **Matching fails.** The fallback `ManagedReplacementMetadata` in `prepareCreateCandidate` (AXEventHandler.swift:2039-2048) sets `role: nil, subrole: nil, title: nil, windowLevel: nil, parentWindowId: nil, frame: nil`. The catalog stores `role: "AXWindow", subrole: "AXStandardWindow"`. Soft match compares with `==`, so `nil != "AXWindow"` → 0 matches → hydration never fires. This is the ONLY metadata construction path with nil fields — LayoutRefreshController and WMController paths already populate correctly.

2. **noMatch spam.** `plannedPersistedHydrationMutation` is called on every `recordReconcileEvent` — focus changes, workspace assignments, hidden state changes — not just window admission. 86 noMatch log entries in 30 minutes. Consumption tracking already prevents functional double-processing, but the unnecessary calls waste cycles and pollute logs.

## Root Cause

All discriminating fields (`role`, `subrole`, `title`, `windowLevel`, `parentWindowId`, `frame`) are available in `evaluation.facts` at admission time via `AXWindowFacts` and `WindowServerInfo`, but the fallback path explicitly discards them by passing nil.

The `managedReplacementCorrelator` path (for destroy→create pairs) does populate these fields. The fallback path (first window of each app, or no prior destroy to correlate) does not. Post-admission, `updateManagedReplacementTitle` (AXEventHandler.swift:243/2336) updates titles when AX notifications fire, so catalog entries eventually get correct titles on the next save cycle — but the boot catalog used for hydration never benefits within the same session.

## Expert Panel Reviews

### Round 1 (5 agents — approach selection)

| Expert | Verdict |
|--------|---------|
| Architect | Approach A at 4.8/5. Preserves design intent, minimal coupling. |
| Devil's Advocate | Found multi-match rejection: `matches.count == 1` guard rejects Chrome (3 identical entries). **Resolved by populating title** — Chrome windows have different tab titles → unique keys. |
| Coder | Mechanically correct. `evaluation.facts.ax.role`, `.subrole`, `.title` confirmed as exact paths. All types match. |
| Apple SDK | AX roles stable post-creation. `AXWindow` + `AXStandardWindow` is standard. No edge cases. |
| Event Scoping | Only `windowAdmitted` + `windowRekeyed` should trigger hydration. Consumption tracking already prevents double-processing — spam is pure log noise. |

### Round 2 (6 agents — spec review)

| Expert | Score | Key Finding | Spec Action |
|--------|-------|-------------|-------------|
| Architect | 3.2/5 | Move guard into `plannedPersistedHydrationMutation`, not WMEvent. Only AXEventHandler fallback is broken. | Moved guard location |
| Designer | Works | Windows hydrate during deferred batch — no visual flash. Monitor topology handled robustly. | No change |
| Coder | Correct | All types match. RestorePlannerTests.swift has mock infrastructure. | No change |
| Debugger | No blockers | @MainActor protects concurrent admission. First boot safe. | No change |
| DA | Chrome titles volatile | "New Tab" on restart ≠ saved titles. Frame NOT used in key matching (DA concern rebutted). | Added known limitation |
| Reviewer | **CRITICAL gap** | Two-restart migration lag: first restart won't benefit (boot catalog has nil titles). `updateManagedReplacementTitle` updates post-admission. | Added migration section |

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

**Effect:** Catalog entries will have role/subrole/title populated. Soft match by bundleId+role+subrole succeeds for single-window apps. Title disambiguation handles multi-window apps where titles differ.

**Note:** `frame` is stored in metadata for floating window restoration but is NOT part of `PersistedWindowRestoreBaseKey` matching. It does not affect match/no-match decisions.

### Change 2: Scope hydration to admission events

**File:** `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift`
**Location:** `plannedPersistedHydrationMutation` (~line 579)

Add an event-type guard inside `plannedPersistedHydrationMutation` itself (per architect recommendation — keeps persistence concerns in WorkspaceManager, not the event model):

The caller in `recordReconcileEvent` (~line 320) will pass the event type:

```swift
// Before (line 320):
let persistedHydration = event.token.flatMap { plannedPersistedHydrationMutation(for: $0) }

// After:
let persistedHydration: PersistedHydrationMutation?
switch event {
case .windowAdmitted, .windowRekeyed:
    persistedHydration = event.token.flatMap { plannedPersistedHydrationMutation(for: $0) }
default:
    persistedHydration = nil
}
```

**Effect:** Eliminates 86 unnecessary hydration attempts per 30 minutes. No WMEvent modification needed.

## What This Enables

After restart (see Migration section for timing), windows return to their previous:
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
- WMEvent enum unchanged — no `isAdmissionEvent` property added (guard lives in WorkspaceManager)

## Known Limitations

### Chrome title volatility (no regression)
Chrome opens all windows with "New Tab" on restart before session restore loads actual tabs. If 3 Chrome windows have different saved titles but all restart as "New Tab", soft match returns 3 → `matches.count == 1` rejects all. **This is no regression** — Chrome doesn't hydrate today either. Single-window apps (VSCode, Ghostty, Slack, TextEdit) benefit immediately since they have unique bundleId keys.

### Title-dependent disambiguation
Any multi-window app where all windows share the same title at admission time won't disambiguate. The `matches.count == 1` guard correctly rejects ambiguous matches. This is a design choice — wrong placement is worse than no placement.

## Migration

**Two-restart lag:** The first restart after deploying this fix will NOT restore windows. The boot catalog loaded at startup contains entries from before the fix — with nil titles and nil role/subrole. These entries won't match the newly-populated metadata.

After the first run with the fix, the catalog will be saved with populated fields. The **second restart** will load this enriched catalog and hydration will succeed.

This is acceptable because:
1. It's a one-time transition, not ongoing
2. The fallback behavior (default workspace) is what users see today
3. `updateManagedReplacementTitle` updates titles post-admission, so the saved catalog will have correct titles even if admission-time titles were "New Tab"

## Edge Cases

| Case | Behavior |
|------|----------|
| AX attribute fetch fails | `role`/`subrole`/`title` will be nil → falls back to current behavior (no match). No regression. |
| Two Chrome windows with same tab title | Soft match returns 2 → `matches.count == 1` rejects. Same as current behavior. No regression. |
| Window count changed between sessions | Extra catalog entries are unconsumed. Missing windows just don't match. Graceful degradation. |
| Title changes after admission | `updateManagedReplacementTitle` fires on AX notification → catalog saves updated title. Next restart matches correctly. |
| First boot (no catalog) | `loadPersistedWindowRestoreCatalog()` returns `.empty`. Hydration is a no-op. No crash. |
| Crash without save | 75ms deferred save may not flush. Boot catalog is stale but soft match still works for stable fields. |

## Test Plan

1. **Unit test:** Verify soft match succeeds when metadata has role+subrole+title populated (RestorePlannerTests.swift)
2. **Unit test:** Verify hydration skipped for non-admission events (focus, workspace, hidden state)
3. **Unit test:** Verify multi-window disambiguation by title (3 entries with different titles → each matches uniquely)
4. **Unit test:** Verify `matches.count > 1` rejects when titles are identical
5. **Runtime:** Restart Hiro, check logs for `planPersistedHydration: matched` instead of `noMatch`
6. **Runtime:** Verify windows return to correct workspaces after restart (second restart after fix)
7. **Runtime:** Confirm 0 noMatch spam for non-admission events

## Files Changed

1. `Sources/OmniWM/Core/Controller/AXEventHandler.swift` — populate fallback metadata from `evaluation.facts`
2. `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift` — scope hydration to admission events in `recordReconcileEvent`
3. `Tests/OmniWMTests/RestorePlannerTests.swift` — new hydration matching tests
