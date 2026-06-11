# Fix D Layer 1: Transfer Path Unification

**Date:** 2026-06-11
**Build:** 99
**Branch:** fix/scope-relayout-to-workspace
**Bugs:** #7/27 (viewport gap), #30 (cross-display geometry)
**Memorygraph:** `72434591` (revised Fix D), `10dee287` (4 invariant violations)

## Problem

`atomicTransferWindow` (WorkspaceNavigationHandler.swift:529) is the ONLY transfer path that calls `applySessionTransfer` without following up with `commitWorkspaceTransition`. All other paths are correct:

| Caller | Path | commitWorkspaceTransition? |
|--------|------|---------------------------|
| `atomicTransferWindow` (line 529) | Direct | **MISSING** |
| `transferWindowFromSourceEngine` (lines 593, 637) | Via callers at 700, 872, 960, 1001 | ✓ (all 4 callers have it) |
| `moveColumnToWorkspace` (line 758) | Direct | ✓ (line 776, with PostLayoutAction) |
| `moveColumnToAdjacentWorkspace` (line 827) | Direct | ✓ (line 845, with PostLayoutAction) |

This is not a systemic dual-path issue — it's a single incomplete callsite. The pattern IS established; `atomicTransferWindow` is the outlier.

## Root Cause

`atomicTransferWindow` was written as a fast path for single-window transfers. It commits state via `applySessionTransfer` and returns `true` — skipping the relayout that the non-atomic paths trigger via `commitWorkspaceTransition`. The build 99 `ensureSelectionVisible` fix correctly centers the viewport state, but without `commitWorkspaceTransition` the layout engine never applies frames using the destination monitor's geometry.

## Expert Validation

| Expert | Finding |
|--------|---------|
| **Architect** | Original 3-event Fix D rejected (SRP, god nodes, upstream divergence). Unify through existing pipeline. |
| **Devil's Advocate** | Event explosion, feedback loop risk, simpler alternative exists. Use `commitWorkspaceTransition`. |
| **SSOT verification** | All 6 SSOT invariants preserved. `reassignManagedWindow` goes through assignmentManager gate. |
| **Graphify** | No structural path from `applySessionTransfer` to `commitWorkspaceTransition` — they're intentionally separate (commit vs relayout). |
| **Callsite audit** | 5 callers of `applySessionTransfer`. 4 eventually call `commitWorkspaceTransition`. Only `atomicTransferWindow` doesn't. |

## Why This Is Not a Reactive Patch

1. All other `applySessionTransfer` callers already follow with `commitWorkspaceTransition`
2. `atomicTransferWindow` is the single outlier — completing the pattern, not inventing a new one
3. No new types, no new events, no new coupling
4. SSOT compliant (all 6 invariants verified)
5. Follows upstream pattern (direct dispatch + relayout)

## Design

### Change: Add `commitWorkspaceTransition` to `atomicTransferWindow`

**File:** `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift`
**Location:** After `applySessionTransfer` at line 536, before `return true` at line 538

Following the pattern from `moveColumnToWorkspace` (lines 776-786):

```swift
        applySessionTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            sourceState: sourceState,
            sourceFocusedToken: newSourceFocusToken,
            targetWorkspaceId: targetWorkspaceId,
            targetState: targetState,
            targetFocusedToken: nil
        )

        // ADD: trigger relayout for both affected workspaces
        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: affectedWorkspaceIds(
                sourceWorkspaceId: sourceWorkspaceId,
                targetWorkspaceId: targetWorkspaceId
            ),
            reason: .workspaceTransition
        ) { [weak controller] in
            if let newSourceFocusToken {
                controller?.focusWindow(newSourceFocusToken)
            }
        }

        return true
```

The PostLayoutAction focuses the source workspace's new focus window after relayout completes — matching the pattern at lines 776-786 and 845-855.

### Verify: `affectedWorkspaceIds` helper exists

```swift
private func affectedWorkspaceIds(
    sourceWorkspaceId: WorkspaceDescriptor.ID?,
    targetWorkspaceId: WorkspaceDescriptor.ID?
) -> Set<WorkspaceDescriptor.ID>
```

This helper is already used by lines 776 and 845. Confirmed available.

## What This Fixes

- **Bug #7/27**: Viewport gap — relayout fires `applyViewportPipeline` → `applyOverspread` on destination
- **Bug #30**: Cross-display wrong geometry — relayout reads correct monitor via `monitor(for: targetWorkspaceId)`

## What This Does NOT Fix

- Bug #15 (CADisplayLink global): Animation scoping — separate issue
- Flutter (Phase 4.5 STOP): Scroll animation frame writes — separate architectural issue
- Frame observation feedback: Deferred — needs convergence research

## Edge Cases

| Case | Behavior |
|------|----------|
| Same-display transfer | Both workspaces on same monitor → correct geometry |
| Cross-display transfer | Each workspace uses its own monitor → correct geometry via `monitor(for:)` |
| Source becomes empty after transfer | `applyViewportPipeline` handles empty workspace (no columns → no overspread needed) |
| newSourceFocusToken is nil | PostLayoutAction closure is a no-op → safe |

## Test Plan

1. **Runtime**: moveToWorkspace same-display → no viewport gap
2. **Runtime**: moveToWorkspace cross-display → no verificationMismatch, correct frame geometry
3. **Runtime**: moveColumn to workspace → no regression (already has commitWorkspaceTransition)
4. **Runtime**: Multiple rapid transfers → each relayouts independently

## Files Changed

1. `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift` — add `commitWorkspaceTransition` after `applySessionTransfer` in `atomicTransferWindow`
