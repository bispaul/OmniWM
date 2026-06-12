# Column Transfer Pipeline Consolidation

**Date:** 2026-06-12
**Build:** 106 (target)
**Branch:** fix/scope-relayout-to-workspace
**Bug:** #7/27 column gap after cross-display moveToWorkspace
**Pattern:** F7 (explicit policy parameter at scattered call sites)

## Problem

Fork's `atomicTransferWindow` (Fix A) and hotkey `moveColumnToWorkspace` use `engine.moveColumnToWorkspace` which is missing 2 operations that upstream's `moveWindowToWorkspace` provides:

1. **`activeColumnIndex` adjustment** — after column removal, the source viewport's `activeColumnIndex` is stale. Viewport offset is calculated relative to the active column — stale index = wrong offset = gap.
2. **`initializeNewColumnWidth`** — transferred column keeps source display's proportion width (e.g., 861px from 1728px Retina instead of 1277px for 2560px display).

Upstream avoids this because it uses `moveWindowToWorkspace` which creates a NEW column with `initializeNewColumnWidth` and calls `cleanupEmptyColumn` (adjusts `activeColumnIndex`). Upstream never moves whole columns cross-display.

**Evidence (diagnostic logging, build 104-105):**
- WS8 after transfer: TextEdit x=418 (418px left gap), cachedWidth=861 (from Retina, not 1277 for 32")
- WS1 after return transfer: Ghostty end=863, Finder start=1725 (862px middle gap)
- `computeLayoutPlan` log: `applyPolicies=false`, `removedTokens=0` — engine doesn't detect the gap
- Graphify: NO structural path from `atomicTransferWindow` to `cleanupEmptyColumn` or `initializeNewColumnWidth`

## Root Cause (Upstream Comparison)

| Operation | Upstream `moveWindowToWorkspace` | Fork `moveColumnToWorkspace` |
|-----------|--------------------------------|------------------------------|
| Column width for target | `initializeNewColumnWidth` ✅ | Keeps source width ❌ |
| Source `activeColumnIndex` | `cleanupEmptyColumn` ✅ | Not adjusted ❌ |
| Source empty column cleanup | `cleanupEmptyColumn` ✅ | N/A (column moved, not empty) ✅ |

## Design

### Part 1: Engine-Level Fix (F7 Pattern)

Modify BOTH overloads of `moveColumnToWorkspace` in `NiriLayoutEngine+WorkspaceOps.swift`:

**Overload 1** (line 58-102, without `atColumnIndex`):
**Overload 2** (line 104-153, with `atColumnIndex`):

Add to both:

```swift
func moveColumnToWorkspace(
    _ column: NiriContainer,
    from sourceWorkspaceId: WorkspaceDescriptor.ID,
    to targetWorkspaceId: WorkspaceDescriptor.ID,
    sourceState: inout ViewportState,
    targetState: inout ViewportState,
    atColumnIndex: Int? = nil,           // overload 2 only
    resetColumnWidth: Bool = true        // NEW — safe default recalculates
) -> WorkspaceMoveResult? {
    // ... existing guards ...
    
    // Capture removed index BEFORE detach
    let removedIndex = columnIndex(of: column, in: sourceWorkspaceId)
    
    column.detach()
    
    // ... existing appendChild / atColumnIndex insertion ...
    
    // NEW: Adjust activeColumnIndex on source
    // Uses shared helper (also called by cleanupEmptyColumn) — DRY
    adjustActiveColumnIndex(
        &sourceState,
        afterRemovalAt: removedIndex,
        newColumnCount: columns(in: sourceWorkspaceId).count
    )
    
    // NEW: Recalculate column width for target display
    if resetColumnWidth {
        initializeNewColumnWidth(column, in: targetWorkspaceId)
    }
    
    // ... existing selectedNodeId assignment + return ...
}
```

**Design decisions:**
- `resetColumnWidth: Bool = true` — safe default. Recalculates unless caller explicitly opts out. New callers get correct cross-display behavior without needing to know about monitors. (Expert reviewer recommendation: safer fail-safe)
- `activeColumnIndex` adjustment is UNCONDITIONAL — there's no case where stale index is correct after column removal
- Index captured BEFORE `detach()` — after detach, the column is no longer in the source children
- DRY: extract shared `adjustActiveColumnIndex(_:afterRemovalAt:newColumnCount:)` helper, called from BOTH `moveColumnToWorkspace` and `cleanupEmptyColumn` — eliminates duplication and divergence risk (DA finding)

### Part 2: Caller Updates

| Caller | File:Line | `resetColumnWidth` | Rationale |
|--------|-----------|-------------------|-----------|
| `atomicTransferWindow` | WorkspaceNavigationHandler.swift:486 | `sourceMonitorId != targetMonitorId` | Preserve width same-display (Fix A intent), recalculate cross-display |
| `moveColumnToAdjacentWorkspace` | WorkspaceNavigationHandler.swift:752 | `false` | Always same monitor (`resolveOrCreateAdjacentWorkspace` binds to `monitorId`) |
| `moveColumnToWorkspace` (hotkey) | WorkspaceNavigationHandler.swift:822 | `sourceMonitorId != targetMonitorId` | Named workspace can be on any monitor |

Width reset check pattern for callers:
```swift
let sourceMonitorId = controller.workspaceManager.monitorId(for: sourceWsId)
let targetMonitorId = controller.workspaceManager.monitorId(for: targetWsId)
let isCrossDisplay = sourceMonitorId != targetMonitorId
// Also check workspace layout settings — two workspaces on the SAME monitor
// can have different maxVisibleColumns, requiring width recalculation
let sourceMaxCols = controller.settings.effectiveMaxVisibleColumns(for: sourceWsId)
let targetMaxCols = controller.settings.effectiveMaxVisibleColumns(for: targetWsId)
let needsWidthReset = isCrossDisplay || sourceMaxCols != targetMaxCols
// pass resetColumnWidth: needsWidthReset
```

Thread safety: all callers are `@MainActor`-isolated (Swift 6.3 strict concurrency). No concurrent caller risk — `inout` parameters serialize access at the MainActor level.

### Part 3: Viewport Clamping Safety Net (Already Committed)

The viewport clamp (`clampViewportOffset`) in `applyViewportPipeline` remains as a safety net:
- Runs on every layout pass (applyPolicies=true: inside `!didOverspread`; applyPolicies=false: unconditional)
- Prevents viewport from extending past column bounds
- Catches edge cases that the engine fix doesn't cover

Commits: 99403af, 33fd7b9, c084117

## Phase 1-5 + Fix A-E Alignment

| Item | Impact |
|------|--------|
| **Fix A** (atomic transfer) | Enhanced — same-display preserves width (resetColumnWidth=false), cross-display recalculates |
| **Fix B** (SkyLight guard) | Unaffected — different subsystem |
| **Fix C** (wake restore) | Unaffected — sleep/wake, not transfer |
| **Fix D** (viewport scoping) | Enhanced — correct activeColumnIndex + clamp = better viewport |
| **Fix E** (WindowLifecycleCoordinator) | Unaffected |
| **Phase 1-5** | Engine stays pure — no monitor lookup in engine (caller passes flag) |
| **SSOT #1-6** | Not touched — this is viewport/layout, not window identity or workspace assignment |
| **F7 pattern** | Applied — explicit `resetColumnWidth` parameter consolidates scattered behavior |

## Architecture Smells

| Smell | Status |
|-------|--------|
| `moveColumnToWorkspace` inconsistency (3 callers) | **FIXED** — consolidated at engine level with explicit parameter |
| Viewport over-scroll (Bug B symptom) | **FIXED** — clamp safety net (committed) |
| `commitWorkspaceTransition` 13 callers | Not addressed — separate effort, less dangerous with clamp safety net |
| Animation start 4 mechanisms | Not addressed — separate effort |
| `requestImmediateRelayout` 44 sites | Not addressed — separate effort |
| `focusWindow` 30 sites | Not addressed — separate effort |
| `startScrollAnimation` 16 sites | Not addressed — separate effort |
| Viewport/animation coupling | Partially addressed — clamp + correct activeColumnIndex reduce coupling impact |

## Target activeColumnIndex (atColumnIndex Insertion)

When overload 2 inserts at a specific index (`targetRoot.insertChild(column, at: targetIndex)`), the target's `activeColumnIndex` could become stale if `targetIndex <= targetState.activeColumnIndex`. However, this is safe to skip because:
- `atomicTransferWindow` (only caller of overload 2 with `atColumnIndex`) explicitly sets `targetState.selectedNodeId` after the move
- The next layout pass resolves `activeColumnIndex` from `selectedNodeId` via `resolveSelection`
- If the target workspace is visible, there may be a single-frame glitch — acceptable given the selection is immediately corrected

## Known Trade-offs

`initializeNewColumnWidth` resets ALL width state (8 properties):
- `width` → default proportion for target workspace
- `presetWidthIdx` → resolved from target workspace settings
- `cachedWidth` → `0` (recalculated on next layout pass)
- `isFullWidth` → `false`
- `savedWidth` → `nil`
- `hasManualSingleWindowWidthOverride` → `false` (single-window aspect ratio override lost)
- `widthAnimation` → `nil`
- `targetWidth` → `nil`

A full-width column moved cross-display loses its full-width state. A column with manual single-window width override loses that override. This is acceptable:
- New monitor has different dimensions — proportion(1.0) means different pixel width
- The column gets the default proportion for the target workspace
- Same-display transfers (resetColumnWidth=false) preserve ALL width state
- Note: `copyColumnWidthState` (NiriLayoutEngine+ColumnOps.swift:31-40) exists but copies from source — different intent than reset-for-target

## Edge Cases

| Case | Handling |
|------|---------|
| Same-display transfer | `resetColumnWidth: false` — preserves width (Fix A intent) |
| Cross-display transfer | `resetColumnWidth: true` — recalculates for target display |
| Last column removed from source | `activeColumnIndex = 0` (same as cleanupEmptyColumn) |
| Column removed before active | `activeColumnIndex -= 1` (shift left) |
| Active column is last and exceeds count | `activeColumnIndex = newCount - 1` (clamp to last) |
| Full-width column cross-display | Reset to default proportion (documented trade-off) |
| New caller added without monitor check | Safe default `true` recalculates (no silent bug) |

## Test Plan

1. **Unit: activeColumnIndex adjusted after column removal** — remove column at index 1 of 3, verify activeColumnIndex shifts
2. **Unit: activeColumnIndex clamps when last column removed** — remove last column, verify index = newCount - 1
3. **Unit: activeColumnIndex stays when column after active removed** — remove column at index 2, active at 0, verify unchanged
4. **Unit: activeColumnIndex zero when all columns removed** — remove only column, verify index = 0
5. **Unit: resetColumnWidth=true recalculates width** — move column cross-workspace, verify cachedWidth reset to 0 and width proportion matches target
6. **Unit: resetColumnWidth=false preserves width** — move column same-workspace, verify cachedWidth unchanged
7. **Unit: isFullWidth reset on cross-display** — full-width column moved with resetColumnWidth=true, verify isFullWidth=false
8. **Integration: cross-display transfer no gap** — atomicTransferWindow WS8→WS1, verify source viewport has no gap
9. **Integration: same-display transfer preserves width** — atomicTransferWindow within same monitor, verify column width preserved
10. **Runtime: visual verification** — screenshot before/after cross-display transfer, no wallpaper visible
11. **Update: `atomicTransferPreservesColumnWidth`** — split into 2 tests: same-display preserves width, cross-display recalculates width (test uses 2-monitor setup where ws1/ws2 are on different monitors)
12. **Unit: multi-window column cross-display** — column with 2+ windows transferred cross-display, verify width recalculated and window size ratios within column preserved
13. **Unit: empty workspace after transfer** — move only column away, verify `activeColumnIndex=0` and no crash on next layout pass with 0 columns
14. **Unit: same-monitor different maxVisibleColumns** — source WS has maxVisibleColumns=3, target has maxVisibleColumns=2, same monitor — verify `resetColumnWidth=true` (settings differ)
15. **Regression: existing viewport tests** — 38/38 pass
16. **Regression: RefreshRoutingTests** — 94/95 pass (1 pre-existing)

## Related

- Viewport clamping spec: `2026-06-12-viewport-clamping-design.md`
- Fix A (atomic transfer): memorygraph `09bf5977`
- F7 (frame coalescing): `2026-06-11-f7-frame-coalescing-design.md`
- Architecture audit: memorygraph `9e2d0a33`
- Session memorygraph: `b7415c02`
