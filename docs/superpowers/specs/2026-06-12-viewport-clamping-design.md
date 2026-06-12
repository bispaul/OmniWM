# Viewport Clamping After Column Operations

**Date:** 2026-06-12
**Build:** 105 (target)
**Branch:** fix/scope-relayout-to-workspace
**Bug:** #7/27 column gap after moveToWorkspace (cross-display transfer)

## Problem

After a cross-display Niri→Niri window transfer (e.g., TextEdit WS8→WS1 via IPC `move-to-workspace`), the source workspace shows a ~1283px gap on the right side of a 2560px display. The desktop wallpaper is visible through the gap.

## Root Cause (Diagnostic Evidence)

Confirmed with diagnostic logging on build 104:

```
wsId=6B1B42F3 (WS8, source):
  applyPolicies=true, requiresRecalc=true          ← pipeline DID run
  applyOverspread: totalWidth=3835 viewportSpan=2560 fits=false  ← columns don't fit
  ensureContainerVisible: active column (1277px) shown, 1283px empty
  
  col[0] cachedWidth=1277 isFullWidth=false
  col[1] cachedWidth=1277 isFullWidth=false
  col[2] cachedWidth=1277 isFullWidth=false
```

The viewport pipeline runs correctly but has no **over-scroll prevention**. When `applyOverspread` returns `false` (columns too wide), `ensureContainerVisible` scrolls to show only the active column. The remaining viewport space extends past the last column — showing empty wallpaper.

`scrollByPixels` (gesture path) already prevents this with clamping at line 207. The layout pipeline has no equivalent.

## Design

### Part 1: `clampViewportOffset()` Helper

New method on `ViewportState` in `ViewportState+ColumnTransitions.swift`. Extracted from existing `scrollByPixels` clamping logic.

```swift
@discardableResult
mutating func clampViewportOffset(
    containers: [NiriContainer],
    gap: CGFloat,
    viewportSpan: CGFloat,
    sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
    scale: CGFloat = 2.0
) -> Bool {
    guard !containers.isEmpty else { return false }
    guard !viewOffsetPixels.isAnimating, !viewOffsetPixels.isGesture else { return false }

    let totalW = totalSpan(containers: containers, gap: gap, sizeKeyPath: sizeKeyPath)

    let maxOffset: CGFloat = 0
    let minOffset = viewportSpan - totalW
    guard minOffset < maxOffset else { return false }

    let current = stationary()
    let safeMin = min(minOffset, maxOffset)
    let safeMax = max(minOffset, maxOffset)
    let clamped = current.clamped(to: safeMin...safeMax)
    let pixelEpsilon: CGFloat = 1.0 / max(scale, 1.0)
    guard abs(clamped - current) > pixelEpsilon else { return false }

    viewOffsetPixels = .static(clamped)
    return true
}
```

**Design decisions:**
- `!isAnimating, !isGesture` guards: prevents snapping during spring animations or trackpad gestures (DA risk #1 and #2)
- `stationary()` not `current()`: reads the intended final position, not mid-animation frame (validated by architect)
- `minOffset < maxOffset` guard: when all columns fit (`totalW <= viewportSpan`), `applyOverspread` already centered them — skip clamping
- `min/max` safe range: prevents `ClosedRange` crash from floating-point rounding (DA risk #3)
- Reuses existing `totalSpan()` helper from `ViewportState+Geometry.swift` — no duplication (designer finding)
- Pixel epsilon: avoids sub-pixel jitter from floating-point rounding
- Returns `Bool`: callers can check if clamping occurred (for logging/diagnostics)

### Coordinate Space (Verified)

`viewOffsetPixels` uses the same coordinate space as `scrollByPixels` (line 203-210). Both compute bounds from `maxOffset = 0` and `minOffset = viewportSpan - totalW`. The clamp operates in viewport-relative space, not absolute layout space — no coordinate conversion needed. Verified against `containerPosition()` and `ensureContainerVisible()` which both read `stationary()` in the same space.

### Why `stationary()` Not `current()` (Deliberate Divergence)

`scrollByPixels` uses `current()` because it reads the mid-flight animated position during live gesture tracking. The clamp uses `stationary()` because it runs as a post-pipeline safety check — it reads the INTENDED final position, not an in-progress frame. The `!isAnimating` and `!isGesture` guards ensure the clamp only runs when the offset is `.static`, in which case `stationary() == current()`. This divergence is safe because the guards guarantee equivalence at the call site. (Senior reviewer finding I2)

### Part 2: Pipeline Integration

In `NiriLayoutHandler.applyViewportPipeline()`, add **inside the `if !didOverspread` block**, after `ensureContainerVisible`:

```swift
let didOverspread = state.applyOverspread(...)
if !didOverspread {
    let settings = engine.effectiveSettings(for: pass.monitor.id)
    state.ensureContainerVisible(...)
    
    // Clamp: prevent viewport from showing space past column bounds.
    // Only runs when columns DON'T fit (applyOverspread returned false).
    // When columns DO fit, applyOverspread already centered them — no clamp needed.
    state.clampViewportOffset(
        containers: columns,
        gap: pass.gap,
        viewportSpan: viewportSpan,
        sizeKeyPath: sizeKeyPath
    )
}
```

**Placement rationale:** The clamp runs ONLY when `applyOverspread` returned `false` (columns don't fit). This prevents the threshold conflict: `applyOverspread` uses `totalWidth <= viewportSpan + gap` while the clamp uses `totalW <= viewportSpan`. Placing inside `if !didOverspread` ensures the clamp never overrides valid centering from `applyOverspread`. (Senior reviewer finding C1)

**Scope caveat:** The clamp is inside the `applyPolicies` guard — it only runs when `applyPolicies=true` (viewport recalc needed, new window, or `requiresViewportRecalc` flag). This is correct for the bug: the transfer sets `requiresViewportRecalc=true` so `applyPolicies=true`. The clamp is NOT a universal safety net for every layout pass — it's a safety net for policy-applying passes that modify viewport state. (Senior reviewer finding I1)

### Part 3: Pathway Consolidation Verification

All 37 `viewOffsetPixels` mutation sites audited (27 direct assignments + 10 `offset(delta:)` mutations):

| Category | Assign | Delta | Clamped? | How |
|----------|--------|-------|----------|-----|
| Pipeline (applyOverspread, ensureContainerVisible, anchorPreservation) | 7 | 3 | ✅ | Part 2 clamp runs after in same pipeline pass |
| Gesture handling (scrollByPixels, begin/end/cancel) | 5 | 0 | ✅ | Own clamping at scrollByPixels line 207 |
| Animation management (advance, snap, reset) | 8 | 2 | ✅ | Targets computed from clamped pipeline; ticks don't exceed target |
| Interactive resize | 1 | 0 | ✅ | Sets `viewportNeedsRecalc=true` → re-enters pipeline |
| Removal handling (NiriLayoutEngine+Windows) | 1 | 1 | ✅ | Sets `viewportNeedsRecalc=true` → re-enters pipeline |
| Session patch (WorkspaceManager:1489) | 1 | 0 | ✅ | Preserves valid spring from previous pipeline |
| Single window reset (NiriLayoutHandler:821) | 1 | 0 | ✅ | `.static(0)` always valid |
| New window insertion (NiriLayoutHandler:625) | 0 | 1 | ✅ | Inside layout pass, pipeline runs after |
| Keyboard navigation (NiriNavigation:219) | 0 | 1 | ⚠️ | Sets offset delta directly; triggers ensureSelectionVisible after which sets `viewportNeedsRecalc` |
| Column animation (NiriLayoutEngine+Animation:43) | 0 | 1 | ✅ | Animation tick; pipeline runs on next DisplayLink |
| Column transition (NiriLayoutHandler:1793) | 0 | 1 | ✅ | Inside layout pass, pipeline runs after |
| Other | 3 | 0 | ✅ | N/A |

**Note:** The clamp runs inside the `applyPolicies` guard, so it only fires on policy-applying passes (when `viewportNeedsRecalc`, `requiresViewportRecalc`, or `newWindowToken` is set). This is sufficient for the bug because transfers always set `requiresViewportRecalc=true`. (Senior reviewer finding C2, I1)

## Edge Cases (Devil's Advocate Verified)

| Case | Risk | Evidence |
|------|------|----------|
| Spring animation in progress | None | `!isAnimating` guard skips clamping |
| Gesture in progress | None | `!isGesture` guard skips; scrollByPixels has own clamp |
| Column width mid-resize | None | Resize sets `viewportNeedsRecalc` → clamp runs with updated widths on next tick |
| Empty workspace | None | `!containers.isEmpty` guard; also caught by existing `guard !columns.isEmpty` in pipeline |
| totalW == viewportSpan exactly | None | `minOffset == maxOffset == 0`, guard skips — columns perfectly fit |
| Newly added column (cachedWidth=0) | None | Widths resolved before pipeline runs |
| Hidden window 1px edge epsilon | None | Epsilon is render-time, not viewport offset |
| Settled spring (complete but not snapped) | None | `isAnimating` checks animation completion state |
| Column removal timing | None | `children.didSet` invalidates cache synchronously |

## Architecture Impact

- **Scope:** ~20 lines new code (1 method + 1 call site)
- **Coupling:** 0 new coupling — method lives on `ViewportState`, same file as `scrollByPixels`
- **God nodes:** 0 growth — no new edges to WorkspaceManager/WMController/AXEventHandler/LRC
- **Niri model:** Preserved — no column width changes, no expansion, viewport scrolls only
- **Scattered pathways (tasks #3-#8):** Not consolidated but **neutralized** — the clamp acts as safety net, preventing any scattered caller from producing an over-scrolled viewport

## What This Does NOT Fix

- `commitWorkspaceTransition` caller inconsistency (13 sites, different `affectedWorkspaces`)
- Animation start decision scattered across 4 mechanisms
- `requestImmediateRelayout` 44 sites with no policy threading
- `focusWindow` 30 sites with racing paths
- `startScrollAnimation` 16 sites with inconsistent conditions

These architecture smells remain but are **less dangerous** — the clamp prevents their most visible symptom (viewport gap).

## Test Plan

1. **Unit: clampViewportOffset basic** — 3 columns at 1277px on 2560px viewport, offset past bounds → clamped to show 2 columns
2. **Unit: clamp skips when columns fit** — 2 columns at 1277px on 2560px viewport → returns false
3. **Unit: clamp skips during animation** — `.spring()` offset → no clamping, returns false
4. **Unit: clamp skips during gesture** — `.gesture()` offset → no clamping, returns false
5. **Unit: clamp skips empty workspace** — 0 columns → returns false
6. **Unit: exact fit boundary** — totalW == viewportSpan exactly → returns false (minOffset == maxOffset == 0)
7. **Unit: float precision safety** — totalW = viewportSpan + 0.001 → no crash from ClosedRange
8. **Unit: applyOverspread/clamp dead zone** — totalW in range (viewportSpan, viewportSpan + gap] → applyOverspread returns true, clamp does NOT run (verifies no conflict per C1)
9. **Unit: clamp respects pixel epsilon** — offset 0.3px past bound on 2x scale → no clamp (within 0.5px epsilon)
10. **Integration: cross-display transfer** — move window WS8→WS1, verify source viewport clamped
11. **Runtime: visual verification** — screenshot before/after, no wallpaper visible
12. **Runtime: IPC verification** — `omniwmctl query windows --workspace 8` shows 2 columns filling viewport
13. **Regression: existing RefreshRoutingTests** — 94/95 still pass (1 pre-existing failure)
14. **Regression: gesture scrolling** — trackpad scroll on Niri workspace, no snap/jump

## Diagnostic Logging

**Keep permanently** (observability infrastructure — architect recommendation):
- `computeLayoutPlan`: `applyPolicies` decision log (pipeline routing visibility)
- `removalHandling`: `isActive`, `removedTokens`, `visibilityCorrected` log (removal-to-viewport correlation)

**Remove before commit** (temporary investigation):
- `applyViewportPipeline`: SKIPPED log, applyOverspread result log
- `applyOverspread`: per-column `cachedWidth`/`isFullWidth` loop (120Hz performance concern)
- `applyOverspread`: totalWidth vs viewportSpan log

## Related

- Memorygraph: `0dd20b3e` (root cause finding)
- Memorygraph: `9e2d0a33` (scattered pathways audit)
- F7 frame coalescing spec: `2026-06-11-f7-frame-coalescing-design.md`
- Previous Fix D viewport centering: `2026-06-11-viewport-centering-fix-design.md`
