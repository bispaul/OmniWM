# F7 Frame Coalescing — Selective Animation for Viewport Shifts

**Date**: 2026-06-11
**Build**: 102 (target)
**Branch**: fix/scope-relayout-to-workspace
**Status**: Design approved

## Problem

Every viewport shift triggers `ensureSelectionVisible` → `ensureContainerVisible(animate: true)` → `animateToOffset` → 13-frame spring animation → **39 AX frame writes** (13 CADisplayLink ticks × 3 visible windows). Programmatic shifts (workspace transfers, wake restore, window add/remove) don't need animation — they cause visible "flutter" as windows slide through intermediate positions.

The 39-write pattern exacerbates all 6 open bugs by making intermediate layout states visible:
- Bug #7/27 (column gap after moveToWorkspace) — gap visible during 13-frame slide
- Bug #7/27/15 (Niri viewport gap) — viewport shift exposes gap for ~108ms
- Bug #28 (WhatsApp floating→tiling on wake) — separate root cause (mode not preserved in restore), but flutter makes it worse
- Bug #29 (column reorder on Retina after wake) — needs re-test with signed binary
- Portrait wake window loss — separate root cause, flutter during refocus
- Flutter during moveToWorkspace — directly caused by animation on programmatic transfer

F7 eliminates the animation-induced flutter. Bugs with separate root causes (mode preservation, column ordering) require additional fixes.

## Solution

Two-layer selective animation: keep smooth spring animation for user-initiated column navigation (keyboard, trackpad swipe), write final position directly (1 frame batch) for programmatic shifts.

### Layer 1 — `animate: Bool` parameter on `ensureSelectionVisible`

Add a **non-defaulted** `animate: Bool` parameter that propagates to the existing `ensureContainerVisible(animate:)` mechanism:

```swift
// NiriNavigation.swift — updated signature
func ensureSelectionVisible(
    node: NiriNode,
    in workspaceId: WorkspaceDescriptor.ID,
    motion: MotionSnapshot,
    state: inout ViewportState,
    workingFrame: CGRect,
    gaps: CGFloat,
    animate: Bool,                          // NEW — no default, forced choice
    orientation: Monitor.Orientation = .horizontal,
    animationConfig: SpringConfig? = nil,
    fromContainerIndex: Int? = nil,
    previousActiveContainerPosition: CGFloat? = nil
)
```

Inside, propagates to existing mechanism:
```swift
state.ensureContainerVisible(
    ...
    animate: animate,  // was hardcoded `true`
    ...
)
```

When `animate == false`, `ensureContainerVisible` calls `animateToOffset` which checks `motion.animationsEnabled` — but MORE IMPORTANTLY, the `animate` parameter on `ensureContainerVisible` itself short-circuits:
```swift
if animate {
    animateToOffset(targetOffset, motion: motion, ...)
} else {
    viewOffsetPixels = .static(targetOffset)  // 1 write, no DisplayLink
}
```

### Layer 2 — Typed wrappers for rot prevention

Two convenience methods on `NiriLayoutEngine` that signal intent and prevent categorization rot:

```swift
extension NiriLayoutEngine {
    func ensureSelectionVisibleAfterUserNavigation(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        previousActiveContainerPosition: CGFloat? = nil
    ) {
        ensureSelectionVisible(
            node: node, in: workspaceId, motion: motion,
            state: &state, workingFrame: workingFrame, gaps: gaps,
            animate: true,
            orientation: orientation, animationConfig: animationConfig,
            fromContainerIndex: fromContainerIndex,
            previousActiveContainerPosition: previousActiveContainerPosition
        )
    }

    func ensureSelectionVisibleAfterLayoutChange(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal,
        fromContainerIndex: Int? = nil,
        previousActiveContainerPosition: CGFloat? = nil
    ) {
        ensureSelectionVisible(
            node: node, in: workspaceId, motion: motion,
            state: &state, workingFrame: workingFrame, gaps: gaps,
            animate: false,
            orientation: orientation,
            fromContainerIndex: fromContainerIndex,
            previousActiveContainerPosition: previousActiveContainerPosition
        )
    }
}
```

Wrappers are the preferred call pattern. Direct `ensureSelectionVisible(animate:)` available for edge cases (e.g., conditional animation based on distance).

### Layer 3 — Frame write dedup (DROPPED)

Originally proposed `lastAppliedFrames` dedup from upstream Ledger Pattern A. **Dropped**: `AXManager` already implements both:
- `lastAppliedFrames: [Int: CGRect]` (line 56)
- `shouldSuppressFrameChangeRelayout` (lines 164-174)

Adding a second dedup at the layout level would create inconsistency with the existing AX-level dedup.

## Call Site Categorization (26 sites across 8 files)

### User-initiated — `animate: true` (via `ensureSelectionVisibleAfterUserNavigation`)

| File | Line | Method | Reason |
|------|------|--------|--------|
| NiriNavigation.swift | 89 | `moveSelectionCrossContainer` | Keyboard left/right column nav |
| NiriNavigation.swift | 279 | `focusCombined` | Combined focus direction |
| NiriNavigation.swift | 304 | `focusCombined` | Combined focus fallback |
| NiriNavigation.swift | 391 | `focusColumnByIndex` | Explicit column focus |
| NiriNavigation.swift | 529 | `focusWindowDownOrTop` | Wrap-around focus down |
| NiriNavigation.swift | 559 | `focusWindowUpOrBottom` | Wrap-around focus up |
| NiriNavigation.swift | 623 | `focusWindowAtVisualIndex` | Visual index focus |
| NiriNavigation.swift | 653 | `focusPrevious` | Alt+Tab equivalent |
| NiriLayoutEngine+InteractiveMove.swift | 227 | `swapWindowsByMove` | Interactive move swap |
| NiriLayoutEngine+InteractiveMove.swift | 294 | `insertWindowByMove` | Interactive move insert |
| NiriLayoutEngine+InteractiveResize.swift | 253 | `interactiveResizeEnd` | Resize completion |
| NiriLayoutEngine+Sizing.swift | 201 | `ensureSelectionVisibleForPendingWidth` | Column width change |
| NiriLayoutEngine+Sizing.swift | 211 | `ensureSelectionVisibleForPendingWidth` | Column width change (orientation) |
| NiriLayoutHandler.swift | 1168 | `selectTabInNiri` | User clicks tab in column |

### Programmatic — `animate: false` (via `ensureSelectionVisibleAfterLayoutChange`)

| File | Line | Method | Reason |
|------|------|--------|--------|
| NiriLayoutHandler.swift | 692 | `resolveSelection` (removal path) | Window closed, re-center |
| NiriLayoutHandler.swift | 767 | `handleNewWindowArrival` | Window added, show it |
| NiriLayoutHandler.swift | 1658 | `activateNode` | Mixed — see edge cases below |
| WorkspaceNavigationHandler.swift | 512 | `atomicTransferWindow` | Workspace transfer destination |
| WorkspaceNavigationHandler.swift | 917 | `moveFocusedWindow` | Window moved to workspace |
| WorkspaceNavigationHandler.swift | 1041 | `moveWindow(handle:toWorkspaceId:)` | IPC-driven window move |
| NiriLayoutEngine+Windows.swift | 290 | `removeWindows` (removeTileByIdx path) | Tile removed, re-center |
| NiriLayoutEngine+Windows.swift | 472 | `removeWindows` (removeColumnByIdx path) | Column removed, re-center |
| NiriLayoutEngine+ColumnOps.swift | 197 | `insertWindowInNewColumn` | New column created |
| NiriLayoutEngine+ColumnOps.swift | 590 | `consumeWindowIntoColumn` | Window consumed into column |
| NiriLayoutEngine+ColumnOps.swift | 833 | `expelWindowFromColumn` | Window expelled from column |
| NiriLayoutEngine+ColumnOps.swift | 856 | `ensureColumnVisible` (private helper) | Column visibility after move |

### Additional viewport path — `applyViewportPipeline` (FIXED build 103)

`NiriLayoutHandler.swift:100` calls `state.ensureContainerVisible` and line 91 calls `state.applyOverspread` — both defaulted to `animate: true`. These run on EVERY relayout pass, causing 17-frame DisplayLink animation loops on every click/focus change. **Fixed in build 103**: both calls now pass `animate: false`. These are programmatic viewport corrections, not user navigation. Evidence: 17 batches at 120Hz per click → 1-2 batches after fix.

### Edge cases — direct `ensureSelectionVisible(animate:)` call

**`activateNode` (NiriLayoutHandler.swift:1658)**: Mixed-context method with 9 callers — 8 user-initiated (CommandHandler, MouseEventHandler, selectTabInNiri, focusNeighbor) and 1 AX-driven (AXEventHandler:1413, but passes `ensureVisible: false` when viewport is animating). `NodeActivationOptions` already has `startAnimation: Bool = true` (line 2037) — thread this through to `ensureSelectionVisible(animate: options.startAnimation)`. Default `true` is correct since most callers are user-initiated. Callers that need `animate: false` can set `startAnimation: false` in their options.

## Impact

| Metric | Before | After |
|--------|--------|-------|
| AX writes per programmatic shift | 39 (13 ticks × 3 windows) | 3 (1 batch × 3 windows) |
| AX writes per user navigation | 39 | 39 (unchanged — smooth scrolling preserved) |
| DisplayLink starts for programmatic shifts | 1 (runs 13 ticks) | 0 (no animation = no DisplayLink) |
| New Graphify edges | — | ~4 (2 wrapper methods) |
| God node coupling change | — | 0 (wrappers on NiriLayoutEngine, not god nodes) |

## Architecture Compliance

### Phase 1-5: All COMPLIANT
- Phase 1 (frame feedback): dedup already at AX level, unaffected
- Phase 2 (dirty flag): workspace dirtied regardless of animation mode
- Phase 3 (viewport pipeline): `.static(offset)` is a first-class ViewOffset type, used in snapshot restoration
- Phase 4 (classify before admit): animation mode independent of classification
- Phase 5 (state reconciliation): `executeFinalRestore` uses separate restore path, not `ensureSelectionVisible`

### Fix A-E: All COMPLIANT
- Fix A (atomic transfer): atomicity preserved with `.static` offset
- Fix B (SkyLight guard): orthogonal
- Fix C (wake restore): settle-then-correct uses `requestImmediateRelayout`, not `ensureSelectionVisible`
- Fix D (viewport scoping): `requiresViewportRecalc` flag respected by both animation modes
- Fix E (lifecycle coordinator): orthogonal

### SSOT #1-6: All COMPLIANT
- SSOT #5 (focus reconciliation): actually IMPROVED — programmatic shifts settle instantly, reducing jitter

### Architecture smells: NONE
- Layout engine purity preserved (wrappers are pure, no AX calls)
- God node coupling unchanged
- Niri column model preserved (`.static()` matches `snapToColumn` restoration pattern)

## Expert Verification

| Agent | Finding |
|-------|---------|
| **Architect** | `animate: Bool` follows existing `ensureContainerVisible` pattern. DisplayLink coordination safe. No smells. |
| **Devil's advocate** | 7 attacks: 1 valid (categorization rot → addressed by no-default + wrappers), 6 mitigated by @MainActor serialization and existing architecture. |
| **Debugger** (upstream Ledger) | Ledger is orthogonal. Two reusable patterns already exist in fork's AXManager. |
| **CodeRabbit reviewer** | 5/5 DA dismissals independently verified as CORRECT against actual code. |
| **Compliance expert** | 20/20 Phase/Fix/SSOT/smell checks pass. Identified and resolved Layer 3 redundancy. |
| **Graphify** | ~4 new edges. No god node growth. No structural path from animation to DisplayLink (temporal coupling only). |
| **CodeRabbit spec review** | 8 issues found: fabricated method names, wrong count (30→26), missing call sites, wrapper parameter gap, `applyViewportPipeline` scope gap, `selectTabInNiri` miscategorized. All fixed in spec revision. |

## Testing Strategy

### Unit tests
1. `ensureContainerVisible(animate: false)` → sets `.static(offset)`, offset value is correct
2. `ensureContainerVisible(animate: true)` → creates `SpringAnimation` (existing behavior)
3. Wrapper methods pass correct `animate` value

### Runtime verification
4. Deploy → move window between workspaces → verify 1 frame batch in logs (not 13)
5. Keyboard navigate columns left/right → verify smooth spring animation preserved
6. Sleep/wake → verify no flutter on focus after wake
7. Window add/remove → verify no animation slide

### Regression checks
8. Chrome tab switching → no verificationMismatch
9. Portrait display focus → correct column selection
10. 3-monitor workspace transfer → correct geometry on destination

## Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| New call sites default to wrong animation mode | LOW | No-default parameter forces explicit choice at compile time |
| Animation velocity discontinuity after programmatic shift | LOW | Programmatic shifts semantically reset navigation context — correct behavior |
| DisplayLink started unnecessarily | NONE | `startScrollAnimationIfNeeded` checks `viewOffsetPixels.isAnimating` AFTER animation decision |
| `applyViewportPipeline` still animates during relayout | MEDIUM | Out of scope for F7 — deferred to Fix D Layer 2. F7 addresses `ensureSelectionVisible` sites only. Some programmatic viewport animation may persist through this path. |
| `ensureSelectionVisibleForPendingWidth` wrapper needs animate decision | LOW | Already categorized as user-initiated (column width changes are user commands). Internal wrapper calls `ensureSelectionVisible` — will need `animate: true` passed through. |

## Non-goals

- Upstream AXFrameApplicationLedger adoption (already have AX-level dedup)
- AnimationContext enum (YAGNI — Bool + wrappers sufficient, follows existing pattern)
- Rate-limiting animation frames (doesn't solve root cause)
- Removing smooth scrolling from user navigation (Niri's core UX)
