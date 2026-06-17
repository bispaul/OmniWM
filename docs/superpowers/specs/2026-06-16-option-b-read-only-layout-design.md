# Option B: Read-Only computeLayoutPlan

## Problem

Fork's `computeLayoutPlan` takes `ViewportState` by `inout` and modifies it
via `applyViewportPipeline`. This creates compound viewport mutations and
extra frame writes during workspace switches, causing visible position shifts.
Upstream takes ViewportState by value (read-only) — single viewport writer.

## Fix

Move viewport policy steps from `applyViewportPipeline` (inside computeLayoutPlan)
into `buildRelayoutPlan` (the orchestrator). Make computeLayoutPlan read-only.
Delete applyViewportPipeline.

### New flow in buildRelayoutPlan

```
resolveSelection(&state)           // viewport writer #1
handleNewWindowArrival(&state)      // viewport writer #2
requiresRecalc = state.requiresViewportRecalc
state.requiresViewportRecalc = false
anchorPreservation(&state)          // viewport policy
overspread(&state) [guarded]        // viewport policy
clamp(&state)                       // viewport policy
computeLayoutPlan(state)            // READ-ONLY (by value)
```

### Changes in NiriLayoutHandler.swift

1. **buildRelayoutPlan**: After `handleNewWindowArrival`, before `computeLayoutPlan`:
   - Capture and reset `requiresViewportRecalc`
   - Call `applyAnchorPreservation` with `priorFocusedColumnPosition`
   - Get columns, orientation, sizeKeyPath, viewportSpan (same setup as pipeline)
   - Call `applyOverspread` guarded by `!isAnimating && !isGesture`
   - Call `clampViewportOffset`

2. **computeLayoutPlan**: Change signature:
   - `state: inout ViewportState` → `state: ViewportState`
   - Remove `priorFocusedColumnPosition` parameter
   - Remove `applyViewportPipeline` call
   - Remove `requiresViewportRecalc` capture/reset
   - Keep `requiresRecalc` as a parameter (for animation directives)

3. **Delete applyViewportPipeline** method entirely (~78 lines)

### Why no ensureContainerVisible in the pipeline

The pipeline's ESV was redundant WITH the Bug #35 ESV guard in place:
- `viewportNeedsRecalc`: resolveSelection's ESV already ran (that's what set the flag)
- `newWindowToken`: handleNewWindowArrival's ESV already ran
- `requiresRecalc`: cross-workspace moves produce removal/addition, both have upstream ESV

Test `activeColumnVisibleAfterLeftColumnRemoval` passes without pipeline ESV.

### Frame ordering change

Frames now computed with post-policy viewport state (anchor + overspread + clamp
already applied). Previously computed with pre-policy state. This is more correct:
frames match the committed viewport state. One-frame lag between frame positions
and viewport offset is eliminated.

## Files Changed

1. `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift` — ~78 lines removed,
   ~20 added. Net reduction ~58 lines.

## Test Plan

1. All existing viewport tests must pass (203/203)
2. Runtime: workspace switch × 3, compare layout plan count per switch
3. Visual: verify no position snaps during workspace transitions

## Evidence

- Upstream comparison: computeLayoutPlan takes ViewportState by value
- Architect: all applyPolicies triggers have upstream ESV coverage
- DA: frame ordering change is semantic but correct. Pipeline ESV redundant.
- Bug #35 ESV guard makes pipeline ESV provably redundant
