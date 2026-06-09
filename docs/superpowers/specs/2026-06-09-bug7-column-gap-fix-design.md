# Bug #7: Column Gap After moveToWorkspace — Fix Design

## Problem

When a window is moved to another workspace (Caps+Number), the remaining columns in the source workspace don't expand to fill the gap. The removed column's proportional width is lost, leaving visible empty space.

## Root Cause

Niri column widths use `ProportionalSize.proportion(p)`, resolved as `(availableSpace - gaps) * p - gaps`. Proportions are **absolute fractions of workspace**, not relative to other columns. When a column is removed:

1. Remaining columns keep their old `.size` (e.g., `0.33` for a 3-column layout)
2. `cachedWidth` may or may not be reset to 0 depending on the removal path
3. Even if `cachedWidth` is reset, `resolveAndCacheWidth` recomputes from the unchanged `.size`
4. Result: remaining columns occupy only 66% of workspace, leaving a 33% gap

### History

Build 61 (commit `05bca4d`) added `normalizeRemainingColumnProportions` to all 3 column removal paths. Build 61 revert (commit `f749ba6`) removed it from `removeWindow` and `cleanupEmptyColumn` because structural moves (Caps+Arrow between columns within same workspace) incorrectly triggered normalization. The revert was correct for structural paths but also removed normalization from the workspace transfer path.

The function `normalizeColumnSizes` (ColumnOps.swift:233) exists but is orphaned — zero callers (confirmed by Graphify: degree 4, no incoming "calls" edges).

## Design

### Approach: Handler-Level Normalization

Add normalization in `WorkspaceNavigationHandler.transferWindowFromSourceEngine` after the source engine's removal completes. This is the correct architectural layer because:

- The handler orchestrates workspace transfer semantics (atomic vs fallback, source/target state, focus)
- All 4 workspace transfer commands flow through this function (confirmed by Graphify)
- Engine-level removal (`removeWindow`, `cleanupEmptyColumn`) is shared with structural moves — adding normalization there re-introduces the build 61 regression
- `cleanupEmptyColumn` has 6 callers including structural operations; `transferWindowFromSourceEngine` has 4 callers, all workspace transfer

### Changes

#### 1. Fix `normalizeColumnSizes` (NiriLayoutEngine+ColumnOps.swift)

Current function skips single-column case (`guard cols.count > 1`), leaving a lone column at its old proportion (e.g., 0.33). Also doesn't reset `cachedWidth`, so normalized proportions aren't picked up by the layout pass.

```swift
func normalizeColumnSizes(in workspaceId: WorkspaceDescriptor.ID) {
    let cols = columns(in: workspaceId)
    guard !cols.isEmpty else { return }

    if cols.count == 1 {
        cols[0].size = 1.0
        cols[0].cachedWidth = 0
        return
    }

    let totalSize = cols.reduce(CGFloat(0)) { $0 + $1.size }
    let avgSize = totalSize / CGFloat(cols.count)

    for col in cols {
        let normalized = col.size / avgSize
        col.size = max(0.5, min(2.0, normalized))
        col.cachedWidth = 0
    }
}
```

#### 2. Call from handler (WorkspaceNavigationHandler.swift)

In `transferWindowFromSourceEngine`, after the source engine removal completes (both Niri→Niri and Niri→Dwindle paths), normalize the source workspace:

```swift
// After all engine removal paths, normalize source workspace column widths
if let sourceWsId, let engine = controller.niriEngine {
    engine.normalizeColumnSizes(in: sourceWsId)
}
```

Insert this after the Dwindle `else if` block (line ~634) and before the `succeeded` computation.

### Paths Covered

| Transfer Type | Engine Path | Normalization |
|---|---|---|
| Niri→Niri (single-window column) | `atomicTransferWindow` | ✓ handler calls normalize after |
| Niri→Niri (multi-window/tabbed) | `moveWindowToWorkspace` → `cleanupEmptyColumn` | ✓ handler calls normalize after |
| Niri→Dwindle | `removeWindow` | ✓ handler calls normalize after |
| Dwindle→* | `dwindleEngine.removeWindow` | N/A (Dwindle manages its own layout) |

### Not Affected (Structural Moves)

These call `cleanupEmptyColumn` or `removeWindow` directly, NOT through `transferWindowFromSourceEngine`:
- `expelWindow`, `consumeOrExpelWindow`, `insertWindowInNewColumn`, `createColumnAndMove`, `consumeWindowIntoColumn` — all engine-level column operations within the same workspace.

## Testing

1. **Existing test**: Verify `normalizeColumnSizes` tests from build 61 still exist or recreate
2. **New test**: 3 columns in workspace, transfer middle column's window to another workspace, verify remaining 2 columns each get `size = 0.5 * 2 = 1.0` (normalized)
3. **Single column test**: Transfer all but one window, verify remaining column gets `size = 1.0`
4. **Regression test**: Structural move (Caps+Arrow between columns in same workspace) does NOT trigger normalization

## Risk Assessment

- **Regression risk**: Low. Only `transferWindowFromSourceEngine` is modified, which is workspace-transfer-specific
- **Upstream compatibility**: Upstream has the same gap (no normalization in `transferWindowFromSourceEngine`). Our fix is additive
- **Build 61 lesson**: Normalization at engine level caused regression. Handler level avoids this class of bug entirely
