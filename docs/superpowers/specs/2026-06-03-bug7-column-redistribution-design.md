# Bug #7 Fix: Redistribute Column Widths After Window Removal

## Problem

When a window is removed (quit, minimized, or hidden) and its column becomes empty, the remaining columns keep their original proportional widths, leaving empty screen space. Single remaining column should expand to 100%.

## Root Cause

Three column removal paths exist, none normalize remaining column proportions:
1. `removeColumnByIdx` — used by `removeWindows` (batch, primary close path)
2. `removeWindow` — used by `syncWindows` and cross-layout moves
3. `cleanupEmptyColumn` — used by move/consume operations (ColumnOps)

All three remove the column from the tree but leave remaining columns at their original proportional widths.

## Fix

Extract a shared `normalizeRemainingColumnProportions` helper and call it from all three column removal paths.

### Algorithm

```swift
private func normalizeRemainingColumnProportions(in workspaceId: WorkspaceDescriptor.ID) {
    let cols = columns(in: workspaceId)
    guard !cols.isEmpty else { return }

    if cols.count == 1 {
        cols[0].width = .proportion(1.0)
        cols[0].cachedWidth = 0
        return
    }

    var totalProportion: CGFloat = 0
    for col in cols {
        if case let .proportion(p) = col.width {
            totalProportion += p
        }
    }

    guard totalProportion > 0 else { return }

    for col in cols {
        if case let .proportion(p) = col.width {
            col.width = .proportion(p / totalProportion)
            col.cachedWidth = 0
        }
        // .fixed columns are left unchanged
    }
}
```

**Key details:**
- Only normalizes `.proportion` columns — `.fixed` columns are skipped entirely
- Single column always gets `.proportion(1.0)`
- Pattern-matches `ProportionalSize` enum (no `.proportion` accessor exists — must use `if case let`)
- Resets `cachedWidth = 0` so layout pass recalculates pixel widths
- Called AFTER `column.remove()` in each path, using fresh `columns(in:)` (not stale `cols` local)

### Call Sites

**1. `removeColumnByIdx` (line 382)** — after `column.remove()` (line 434), before viewport state update:
```swift
column.remove()
normalizeRemainingColumnProportions(in: workspaceId)
```

**2. `removeWindow` (line 145)** — after the `column.children.isEmpty` block that removes the column (line 163), replace the `cachedWidth = 0` loop:
```swift
if column.children.isEmpty {
    column.remove()
    normalizeRemainingColumnProportions(in: workspaceId)
    // Remove the existing cachedWidth = 0 loop (lines 165-168) — normalization handles it
}
```

**3. `cleanupEmptyColumn` (ColumnOps, line 209)** — after the empty column is removed:
```swift
column.remove()
normalizeRemainingColumnProportions(in: workspaceId)
```

### Files to Modify

| File | Change |
|------|--------|
| `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Windows.swift` | Add `normalizeRemainingColumnProportions`, call from `removeColumnByIdx` and `removeWindow` |
| `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift` | Call `normalizeRemainingColumnProportions` from `cleanupEmptyColumn` |

### What This Does NOT Change

- Column widths during normal operation
- `balanceSizes` (Caps+E) — still available for EQUAL redistribution
- `initializeNewColumnWidth` — new columns still use `defaultColumnWidth`
- Viewport scrolling behavior
- `.fixed` width columns are never modified
- `isFullWidth` flag behavior (rendering override stays intact)

### AGENTS.md Compliance

All changes are in the Niri layout engine — pure state machine, no AX calls, no frame writes. Just proportion math on `NiriContainer.width` values.

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Remove last column from workspace | 0 remaining, `guard !cols.isEmpty` returns early |
| Remove 1 of 2 columns | Single remaining gets 1.0 (100%) |
| Remove 1 of 3 equal columns [0.33, 0.33, 0.33] | 2 remaining get [0.5, 0.5] |
| Remove 1 of 3 unequal [0.4, 0.3, 0.3] | 2 remaining get [0.571, 0.429] |
| Column has `.fixed(400)` width | Fixed column skipped, only proportional columns normalized |
| Batch removal of multiple columns | Sequential normalization telescopes correctly |
| Column has `isFullWidth=true` | Proportion is normalized, isFullWidth rendering override unchanged |

### Tests

1. **Proportional redistribution** — 3 proportional columns [0.4, 0.3, 0.3], remove middle, verify [0.571, 0.429]
2. **Single column gets 100%** — 2 columns, remove one, verify remaining at 1.0
3. **Fixed columns skipped** — 2 proportional + 1 fixed, remove a proportional, verify fixed unchanged and other proportional expanded
4. **Empty workspace** — 1 column, remove it, no crash

## Verification

1. `swift build` compiles
2. Tests pass
3. Open 3 windows → close one → remaining 2 fill screen proportionally
4. Open 2 windows → close one → remaining fills 100%
