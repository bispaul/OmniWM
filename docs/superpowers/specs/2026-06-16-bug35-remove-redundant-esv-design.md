# Bug #35 Fix: Remove Redundant ESV from Viewport Pipeline

## Problem

Viewport offset drifts by 4px (2 × gap) after workspace switch round-trip.

- Pre-switch: `offset=-1281.0, activeCol=1`
- Post-switch: `offset=-1277.0, activeCol=1`
- Reproduced on 32" display (U32J59x), 3 Niri columns, PID 73727, 2026-06-16

## Root Cause (expert-validated)

`applyViewportPipeline` in `NiriLayoutHandler.swift` runs a redundant second
`ensureContainerVisible` call AFTER `applyAnchorPreservation` has shifted the
offset by a compensatory delta. The "already visible" branch in `computeFitOffset`
preserves this shifted position as the new offset, baking in the drift.

Sequence:
1. `resolveSelection` → ESV → correct offset
2. `applyAnchorPreservation` → shifts offset by small delta
3. **Second ESV** → "already visible" branch returns `currentViewPos - targetPos` → bakes in delta as permanent drift

The second ESV is provably redundant — every path that triggers `applyPolicies=true`
already has its own ESV call or mechanical offset adjustment upstream:

| Trigger | Own ESV? | Source | Notes |
|---|---|---|---|
| `viewportNeedsRecalc` | Yes | `resolveSelection` line 726 | Conditional — see below |
| `newWindowToken` | Yes | `handleNewWindowArrival` line 803 | Always runs for new windows |
| `requiresRecalc` | Partial | Target: `atomicTransfer` line 520. Source: see edge case analysis | Source paths vary — see below |

**`resolveSelection`'s ESV is conditional** (line 714-740). It requires ALL of:
- `!usesSingleWindowAspectRatio` — safe: single-window mode resets viewport at line 848
- `!isGestureOrAnimation` — safe: gesture/animation paths manage viewport themselves
- `snapshot.isActiveWorkspace` — safe: non-active workspaces aren't displayed
- `selectedNodeId` exists and resolves — safe: nil/invalid selection means nothing to center on
- `!visibilityWasCorrected` — safe: correction already positioned the viewport
- Token/fromIndex condition — safe: removal paths adjust via `fromIndexForVisibility`

When any condition fails, ESV is intentionally skipped because the viewport is
already positioned correctly by a different mechanism.

## Fix (Option C')

Remove the second `ensureContainerVisible` call from `applyViewportPipeline`
(lines 115-126). Keep `applyOverspread` and `clampViewportOffset`.

Pipeline changes from:
```
anchorPreservation → overspread → ESV → clamp
```
to:
```
anchorPreservation → overspread → clamp
```

### File: `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift`

In `applyViewportPipeline`, the `applyPolicies=true` branch currently:
```swift
let didOverspread = state.applyOverspread(...)
if !didOverspread {
    let settings = engine.effectiveSettings(for: pass.monitor.id)
    state.ensureContainerVisible(...)  // ← REMOVE this block
    state.clampViewportOffset(...)
}
```

Change to:
```swift
let didOverspread = state.applyOverspread(...)
if !didOverspread {
    state.clampViewportOffset(...)
}
```

~13 lines removed. No lines added. No new parameters. No signature changes.

## Why This Is Safe

- `applyOverspread` computes canonical position independent of `currentViewPos` (idempotent)
- `clampViewportOffset` enforces bounds independent of `currentViewPos` (idempotent)
- `ensureContainerVisible` depends on `currentViewPos` (NOT idempotent) — removing it eliminates the only non-convergent step in the pipeline

### Edge Cases

**Source workspace after `atomicTransfer`:**
`atomicTransfer` uses `moveColumnToWorkspace` → `column.detach()` +
`adjustActiveColumnIndex`. The column is gone before the next layout pass.
`resolveSelection`'s ESV runs normally (removedTokens is empty since the column
was already detached). Anchor preservation sees delta=0 (column gone before
`priorFocusedColumnPosition` captured). Safe — ESV provides full coverage.

**Column removal where `removedIdx < activeIdx` (window close, not transfer):**
`removeColumnByIdx` mechanically adjusts viewport at line 448 (+removedWidth+gap).
`resolveSelection`'s ESV is skipped (removedTokens non-empty, fromIndexForVisibility
nil). `applyAnchorPreservation` computes delta from pre-removal position and shifts
offset by the SAME magnitude — creating double compensation. Without the pipeline
ESV, only `clampViewportOffset` corrects. Clamp caps at `maxOffset=0`, keeping the
active column visible at the viewport's left edge (sub-optimal but not off-screen).
The NEXT layout pass (any window event) runs `resolveSelection`'s ESV with no
removal tokens, correcting to optimal position. Self-heals within one frame.

**Fullscreen/fullwidth toggle:**
`toggleFullWidth` runs its own ESV via `ensureSelectionVisibleForPendingWidth`
(NiriLayoutEngine+Sizing.swift:181-221). During the resulting animation,
`applyPolicies=false` (pipeline ESV unreachable). After animation settles,
`resolveSelection` ESV runs normally. Safe.

**`applyAnchorPreservation` + `clampViewportOffset` without ESV:**
Clamping prevents out-of-bounds offsets but does NOT guarantee the active column
is fully visible. If anchor preservation shifts the offset such that the column
is only 1px visible at the viewport edge, clamping won't fix it. For the bug's
scenario (workspace switch round-trip), `resolveSelection`'s ESV has already
positioned correctly. For novel geometry changes, `resolveSelection`'s ESV
handles the correction on the next layout pass. No gap in coverage.

## Test Plan

**Existing tests (must still pass):**
1. `viewportOffsetStableAcrossRelayoutAfterNavigation`
2. `viewportOffsetPreservedAcrossWorkspaceSwitch`

**New tests:**
3. Column removal where `removedIdx < activeIdx` — active column remains visible (at least at viewport left edge), corrects to optimal on next pass
4. Anchor preservation + clamp without ESV — after column width change shifts offset, active column remains within viewport bounds
5. Fullscreen toggle followed by relayout — offset must not drift
6. Pipeline convergence — calling pipeline N times produces stable offset (idempotence)

**Full suite:**
7. `swift test --filter "ViewportGeometryTests|ViewportPipelineTests|NiriLayoutEngineTests|AtomicWindowTransferTests"`

**Runtime verification:**
8. Deploy binary, navigate right on 3-column workspace
9. Workspace switch round-trip × 3 — compare `offset` field in `computeLayoutPlan` logs, tolerance `abs(pre - post) < 2`
10. Close window to LEFT of active column — verify no column goes off-screen
11. Move window to another workspace — verify source workspace offset stable

## Follow-up: Option B (Architectural Cleanup)

Separate PR. Move viewport policy steps (anchor preservation, overspread, clamp)
from `applyViewportPipeline` into `buildRelayoutPlan` as sequential steps.
Make `computeLayoutPlan` take `ViewportState` by value (read-only). Delete
`applyViewportPipeline` entirely. Matches upstream's single-writer architecture.

## Expert Review Summary

| Reviewer | Verdict | Findings |
|----------|---------|----------|
| Architect | All claims VERIFIED | Line numbers corrected (115-126, line 803) |
| Devil's Advocate | Safe to ship | Double-compensation on left-of-active removal (self-heals). atomicTransfer reasoning corrected. |
| Test Engineer | Tests feasible | 2 additional tests: anchor+clamp visibility, pipeline convergence |

## Evidence

- Memorygraph: `043902f5` (reproduction evidence)
- Memorygraph: `b9da807e` (session final)
- Expert validation: upstream comparison (upstream has no pipeline, no drift),
  devil's advocate (confirmed second ESV is the root cause),
  architect (recommended C', verified all trigger paths have own ESV)
