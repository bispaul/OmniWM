# Tiled Window Z-Order After Layout Refresh

**Date:** 2026-06-02
**Bug:** #4 — Z-order not preserved after workspace transition
**Branch:** `fix/tiled-window-z-order` (from `dev/combined-fixes`)
**Status:** Design approved

## Problem

When OmniWM re-tiles windows (workspace switch, layout refresh, window admit), the stacking order is non-deterministic. The last AX frame write wins the top position. For example, Ghostty (focused) can end up behind Chrome or WhatsApp after a workspace switch.

**Root cause:** `LayoutDiffExecutor.execute()` calls `applyFramesParallel()` to write window frames but never calls `SkyLight.shared.orderWindow()` for tiled windows. Frame writes are grouped by PID in a dictionary (non-deterministic iteration order), so whichever app's frame write completes last ends up on top.

**Evidence:** CGWindowList Z-order query shows Chrome (unfocused, WID 510) at the same x/y as Ghostty (focused, WID 35) but at a lower Z-index — meaning Chrome could visually cover Ghostty after a re-tile.

**Verified pre-existing:** `git diff main..dev/combined-fixes` confirms no behavioral changes to frame writing or window ordering in PRs #400-402. All changes in AXManager, LayoutRefreshController, and FocusBorderController are logging-only or performance optimizations (O(1) lookups, cached observedFrame). The bug exists in upstream `main`.

## Design

### Approach

Add Z-ordering after tiled frame writes in `LayoutDiffExecutor.execute()` (LayoutRefreshController.swift, after line 3567). This is the single code path that applies tiled layout frames.

### Z-Order Rule

- Focused window always on top
- Non-focused tiled windows ordered left-to-right (by x-coordinate) = back-to-front
- Floating windows unaffected (already have their own `orderWindow` path in `WindowActionHandler`)

### Implementation

After `applyFramesParallel(frameUpdates)` in `LayoutDiffExecutor.execute()`:

1. Collect tiled window entries from `diff.changes` that were part of `frameUpdates`
2. Sort by x-coordinate ascending (leftmost = lowest in stack)
3. For each, call the `orderWindow` closure: `orderWindow(UInt32(windowId), relativeTo: 0, order: .above)`
4. Call `orderWindow` on the focused window last (topmost)

### Testability

Follow the existing `*ForTests` closure injection pattern. `WindowActionHandler` already owns `orderWindow` as a stored closure (line 56). Expose this through `WMController` so `LayoutDiffExecutor` can access it. In tests, inject a spy closure that records `(windowId)` call order.

### Files Changed

| File | Change |
|------|--------|
| `Sources/OmniWM/Core/Controller/LayoutRefreshController.swift` | Add Z-ordering in `LayoutDiffExecutor.execute()` after `applyFramesParallel` |
| `Sources/OmniWM/Core/Controller/WindowActionHandler.swift` | Expose `orderWindow` closure for use by executor (or add a `orderTiledWindows` method) |
| `Sources/OmniWM/Core/Support/Loggers.swift` | No changes needed — `WMLog.layout` already exists |
| `Tests/OmniWMTests/LayoutDiffExecutorZOrderTests.swift` | New test file |

### Test Cases

1. **Two tiled windows** — focused window ordered last (topmost)
2. **Three tiled windows** — non-focused ordered by x-coordinate ascending, focused last
3. **Single tiled window** — no `orderWindow` calls (nothing to reorder)
4. **Mixed tiled + floating** — only tiled windows from `frameUpdates` get ordered; floating windows untouched

### Logging

Add `WMLog.layout.debug("Z-order: ordering \(count) tiled windows, focused=\(focusedWindowId)")` before the ordering loop.

## Scope

### In Scope
- Z-ordering after tiled frame writes in `LayoutDiffExecutor`
- Closure injection for testability
- 4 test cases
- Debug logging

### Not In Scope
- Floating window Z-order (already handled)
- Dwindle-specific changes (shares `LayoutDiffExecutor`, gets fix for free)
- Changes to `AXManager` or layout engines (pure state machines, per AGENTS.md)
- Performance optimization (one `orderWindow` syscall per visible tiled window — negligible)

## Risk

**Low.** The change is additive — ordering calls happen after existing frame writes. If `orderWindow` fails for a window, behavior degrades to current state (non-deterministic Z-order). No regressions possible in layout, focus, or frame writing.

## Related

- Bug #4 in `project_omniwm_evaluation.md`
- `WindowActionHandler.swift:56-78` — existing `orderWindow` closure pattern
- `WMController.swift:38` — existing `orderWindow` usage
- AGENTS.md — layout engines must remain pure state machines
