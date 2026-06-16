# Bug #35 Fix: Two-Source Viewport Drift Elimination

## Problem

Viewport offset drifts 4-16px after workspace switch round-trip. Two independent sources.

## Source 1: resolveSelection ESV recomputation (16px in test)

`resolveSelection` calls `ensureSelectionVisible` on every layout pass. When the
target column is the SAME as the active column (no navigation), ESV recomputes
offset via `computeVisibleOffset` which takes a different code path than navigation
(fit vs center in `.onOverflow`, or different `currentViewPos` in `.never` mode).

**Fix:** In `resolveSelection` (NiriLayoutHandler.swift:715-740), wrap the ESV
call with a guard: skip when `targetColIdx == state.activeColumnIndex` AND no
structural change (`removedTokens.isEmpty` AND `fromIndexForVisibility == nil`).

Safe because:
- Column width changes trigger `requiresViewportRecalc` → pipeline ESV handles it
- Interactive resize calls ESV directly via its own handler
- Monitor changes trigger full relayout with anchor preservation
- Navigation calls ESV from `focusNeighbor`/`moveSelectionCrossContainer` (different path)

## Source 2: clampViewportOffset bounds formula (8px in test)

`clampViewportOffset` (fork addition, commit 5a50099) uses position-INDEPENDENT
bounds: `minOffset = viewportSpan - totalW - gap`, `maxOffset = 0`.

But viewport offset is RELATIVE to activeColumnIndex:
`viewportLeftEdge = containerPosition(activeColumnIndex) + viewOffset`

The formula only produces correct bounds for activeColumnIndex == 0. For other
columns, it allows left gaps and prevents valid right scrolling.

**Fix:** Make bounds activeColumnIndex-aware:
```swift
let activePos = containerPosition(at: safeIndex, ...)
let minOffset = -activePos - gap              // prevents left gap
let maxOffset = totalW - viewportSpan - activePos + gap  // prevents right gap
```

Gap tolerance (± gap) preserved from commit 5a50099 to match applyOverspread pattern.

Expert-validated: the original proposed formula had min/max swapped (would disable
clamping). Corrected formula verified for activeCol=0, activeCol=last, single
column, and columns-fitting-viewport cases.

## Files Changed

1. `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift` — guard in resolveSelection
2. `Sources/OmniWM/Core/Layout/Niri/ViewportState+ColumnTransitions.swift` — fix clampViewportOffset bounds

## Test Plan

**Existing tests (must still pass):**
- `viewportOffsetPreservedAcrossWorkspaceSwitch` (ViewportGeometryTests)
- `activeColumnVisibleAfterLeftColumnRemoval` (ViewportPipelineTests)
- `viewportPipelineConvergesAfterMultipleRelayouts` (ViewportPipelineTests)

**Must now pass (currently fails):**
- `viewportOffsetStableAfterWorkspaceSwitchRelayout` (ViewportPipelineTests) — 16px drift → <2px

**Existing clamp tests need updating:**
- `clampViewportOffsetClampsOverscrolledOffset` — update expected bounds
- `clampViewportOffsetClampsUnderscrolledOffset` — update expected bounds (currently pre-existing failure)
- Other clamp tests — verify with position-aware bounds

**Runtime verification:**
- Deploy, navigate right, workspace switch × 3, compare offsets in logs (< 2px tolerance)

## Evidence

- Memorygraph: `fb2c982b` (two drift sources), `ac8fec1e` (clamp root cause DA-validated)
- Expert panel: position-aware bounds formula with min/max swap caught and corrected
- Test: `viewportOffsetStableAfterWorkspaceSwitchRelayout` reproduces 16px drift
