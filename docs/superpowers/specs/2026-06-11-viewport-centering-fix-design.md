# Niri Viewport Centering After Atomic Transfer

**Date:** 2026-06-11
**Build:** 98
**Bugs:** #7/27 (column gap after moveToWorkspace), #15 (cross-monitor), 32" gap
**Branch:** fix/scope-relayout-to-workspace

## Problem

After `atomicTransferWindow` (workspace transfer via Caps+Shift+N), the destination workspace's viewport doesn't center on the transferred column — leaving visual gaps on all Niri displays.

## Root Cause

The atomic transfer path in `WorkspaceNavigationHandler.swift:435-523` is the ONLY transfer path that skips viewport centering. The non-atomic paths (lines 878-894, 1001-1017) correctly call `ensureSelectionVisible` on the destination before committing. The atomic path just calls `applySessionTransfer` without centering `targetState`.

**Regression context:** Commit `64171f9` added centering for the SOURCE workspace but was reverted (`8fbd17e`). The DESTINATION was never addressed. Upstream has centering on both source and destination.

## Expert Panel (4 agents)

| Expert | Finding |
|--------|---------|
| **Call-site mapper** | `applyOverspread` has 1 caller (applyViewportPipeline). `ensureSelectionVisible` has 28 callers — all in navigation/layout, none in atomicTransferWindow. |
| **Upstream comparison** | Upstream calls ensureSelectionVisible on BOTH source and destination after transfers. Fork reverted the source fix; destination was never added. |
| **Devil's Advocate** | Original fix was source-only — wrong target. Destination is the real gap. `animate:false` is a triage choice. Non-atomic paths already do destination centering — this is an established pattern. |
| **Architect** | Non-atomic paths (lines 886, 1010) call `ensureSelectionVisible` on destination then `commitWorkspaceTransition`. Atomic path skips both. Fix should follow the non-atomic pattern. |

## Design

### Change: Add destination viewport centering to atomicTransferWindow

**File:** `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift`
**Location:** After `reassignManagedWindow` (~line 503), before `applySessionTransfer` (~line 513)

Add viewport centering for the transferred column on the DESTINATION workspace, following the exact pattern from the non-atomic path at lines 878-892:

```swift
// After reassignManagedWindow (line 503), before the newSourceFocusToken block:

// Center destination viewport on transferred column
if let movedNode = engine.findNode(for: token),
   let targetMonitor = controller.workspaceManager.monitor(for: targetWorkspaceId)
{
    targetState.selectedNodeId = movedNode.id
    let gap = CGFloat(controller.workspaceManager.gaps)
    let workingFrame = controller.insetWorkingFrame(for: targetMonitor)
    engine.ensureSelectionVisible(
        node: movedNode,
        in: targetWorkspaceId,
        motion: controller.motionPolicy.snapshot(),
        state: &targetState,
        workingFrame: workingFrame,
        gaps: gap
    )
}
```

**Why NOT re-add the `animate:false` parameter:** The non-atomic paths call `ensureSelectionVisible` with default `animate: true` and it works correctly. No need to add a special parameter — follow the established pattern.

**Why NOT fix the source:** The source workspace relayout fires via `requestImmediateRelayout` → `applyViewportPipeline` → `applyOverspread`. If source still has gaps after testing, add source centering in a follow-up.

## What This Fixes

- Bug #7/27: Column gap after moveToWorkspace — destination viewport centers on transferred column
- 32" viewport gap: Same root cause — viewport centering after state changes

## What This Does NOT Fix

- Bug #15 (CADisplayLink global animation): Separate issue — animation scoping, not centering
- Flutter (Phase 4.5 STOP): Separate architectural issue — scroll animation frame writes

## Edge Cases

| Case | Behavior |
|------|----------|
| Transfer to workspace with existing columns | `ensureSelectionVisible` centers on the transferred column, scrolling existing columns as needed |
| Transfer to empty workspace | Single column — `ensureSelectionVisible` centers it |
| Transfer across displays (different dimensions) | `insetWorkingFrame(for: targetMonitor)` uses correct target geometry |
| Multiple rapid transfers | Each transfer centers independently — no accumulation |

## Test Plan

1. **Unit test:** Verify `ensureSelectionVisible` is called with correct parameters after atomic transfer
2. **Runtime:** moveToWorkspace on Retina → verify no gap
3. **Runtime:** moveToWorkspace on 32" → verify no gap
4. **Runtime:** moveToWorkspace cross-display → verify correct centering
5. **Runtime:** Verify source workspace also recenters (via relayout pipeline)

## Files Changed

1. `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift` — add destination centering
2. `Tests/OmniWMTests/` — test for viewport centering after atomic transfer
