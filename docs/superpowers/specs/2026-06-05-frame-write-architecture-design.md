# Frame Write Architecture Overhaul

**Date:** 2026-06-05
**Branch:** `fix/scope-relayout-to-workspace` (off `upstream/main`)
**Status:** Design approved, pending implementation

## Problem

Hiro's frame write path has three architectural issues causing visible glitches on multi-monitor setups:

1. **Off-viewport columns positioned fully off-screen** — macOS detects this and fights back with `verificationMismatch`, causing a 20+/sec retry loop (observed on Chrome windows 441/460 on 32" display)
2. **Every relayout writes frames to ALL windows** — resizing one column triggers AX writes to every window in the workspace, including unchanged ones
3. **No gap-filling when columns don't fill viewport** — viewport shows empty space after navigation/fullscreen toggle when total column width < viewport width

## Research Basis

- **Paneru** (macOS, Rust/Bevy): 5px sliver at screen edge for off-viewport windows prevents macOS forced relocation
- **MangoWM** (Linux/Wayland, C): `overspread` boolean — edge columns auto-fill when total width < viewport, implemented as viewport display concern not width mutation
- **MangoWM/Rift/Paneru**: All three agree resizing one column should never modify neighbors — only reposition them

## Design

### Fix 1: Tiered Column Visibility

Three visibility tiers based on distance from visible set:

| Tier | Definition | Frame write behavior |
|------|-----------|---------------------|
| **Visible** | Column intersects viewport | Full frame write (current behavior) |
| **Adjacent** | First hidden column on each side of visible set | Write frame with 5px sliver at screen edge |
| **Far** | 2+ columns away from visible set | Skip frame write entirely |

**Adjacent positioning:**
- Left adjacent: `x = viewportMinX - columnWidth + sliverWidth`
- Right adjacent: `x = viewportMaxX - sliverWidth`
- `sliverWidth = 5.0` (constant, independent of backing scale)

**Scroll transitions:**
- Far → Adjacent: frame written with sliver position on next animation tick (pre-positioned for smooth scroll-in)
- Adjacent → Visible: normal frame positioning takes over
- No flash because column is already near the viewport edge

**Files to modify:**
- `Sources/OmniWM/Core/Layout/Niri/NiriLayout.swift` — `containerVisibilityState()`: add `.adjacent` visibility tier; `hiddenColumnRect()`: use sliverWidth for adjacent columns
- `Sources/OmniWM/Core/Controller/LayoutRefreshController.swift` — filter far columns out of frame write set in layout plan execution
- `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift` — `applyFramesOnDemand()`: exclude far columns from on-demand layout plan

### Fix 2: Dirty-Tracking Frame Writes

Before writing a frame via AX, compare the new frame against the last successfully applied frame. Skip the write if identical within pixel epsilon.

**Logic (in `AXManager.applyFramesParallel`):**
```
for each (windowId, newFrame) in frameWrites:
    if !isRetry && !isForced:
        if let lastFrame = lastAppliedFrame[windowId]:
            if abs(newFrame.x - lastFrame.x) < 0.5
               && abs(newFrame.y - lastFrame.y) < 0.5
               && abs(newFrame.width - lastFrame.width) < 0.5
               && abs(newFrame.height - lastFrame.height) < 0.5:
                skip this write
    proceed with AX write
```

**Edge cases:**
- Force-writes (`isRetry=true` or forced relayout) bypass the check
- First write for a window (no `lastAppliedFrame` entry) always proceeds
- `lastAppliedFrame` is already maintained by `AXManager` for verification — no new state needed

**Files to modify:**
- `Sources/OmniWM/Core/Ax/AXManager.swift` — add frame comparison gate in `applyFramesParallel()` or the per-window apply path

### Fix 3: Viewport Overspread

After layout calculation, if all columns fit in the viewport with space to spare, adjust viewport offset to center the column group. No column widths change — pure viewport display concern.

**Logic (new method `applyOverspread` on ViewportState):**
```
totalWidth = sum(column.cachedWidth for all columns) + gap * (columnCount - 1)
if totalWidth < viewportWidth:
    excessSpace = viewportWidth - totalWidth
    targetOffset = compute offset that centers column group
    animate viewOffsetPixels to targetOffset
```

**When overspread activates:**
- Only when ALL columns in the workspace fit within viewport width
- Does NOT activate if any column is scrolled off-viewport (normal scrolling case)
- Called after `ensureContainerVisible()` in operations that change column count or width

**When overspread is called:**
- After `focusNeighbor` (navigation may reveal that all columns now fit)
- After `toggleColumnFullWidth` / `toggleFullscreen` (width change)
- After window close/minimize (column removed)
- After `balanceSizes` / `setColumnWidth` / `cycleSize` (width change)

**Files to modify:**
- `Sources/OmniWM/Core/Layout/Niri/ViewportState+ColumnTransitions.swift` — new `applyOverspread()` method
- `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift` — call `applyOverspread()` after relevant operations

## Implementation Order

1. **Fix 2 (dirty-tracking)** — smallest change, immediate impact, reduces noise for testing Fix 1
2. **Fix 1 (tiered visibility)** — eliminates verificationMismatch at the source
3. **Fix 3 (overspread)** — fills viewport gaps once the write path is clean

Rationale: Fix 2 first because it's a 5-line change that immediately reduces log noise and frame write load, making it easier to observe and test Fix 1's behavior.

## Verification

### Automated Tests
- Fix 1: Test that far columns produce no frame writes; adjacent columns get sliver-positioned frames
- Fix 2: Test that unchanged frames are skipped; force-writes bypass the check
- Fix 3: Test that overspread activates when totalWidth < viewportWidth and deactivates when it doesn't

### Runtime Verification
1. Build debug: `swift build -c debug`
2. Grant Accessibility (CDHash changes per build)
3. Check logs: `/usr/bin/log show --predicate 'subsystem == "com.omniwm"' --last 30s --style compact --debug`
4. Test scenarios:
   - Chrome on 32" should have zero verificationMismatch after Fix 1
   - Caps+E (balance) should only write frames to columns whose size/position actually changed after Fix 2
   - 2 columns on a wide monitor should center with no gap after Fix 3

## Success Criteria

- Zero `verificationMismatch` for Chrome windows during normal operation
- Frame write count per relayout reduced from N (all columns) to ~2-3 (visible columns)
- No viewport gaps when total column width < viewport width
- All 1387 existing tests pass
- No visual regressions on 3-monitor setup (MacBook + 32" 4K + 27" FHD portrait)
