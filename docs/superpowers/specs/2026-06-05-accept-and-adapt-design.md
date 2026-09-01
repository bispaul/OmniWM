# Accept-and-Adapt Frame Write Architecture

**Date:** 2026-06-05
**Branch:** `fix/scope-relayout-to-workspace`
**Replaces:** Cooldown/suppression band-aids from earlier in this session

## Problem

When Hiro writes a frame and the app renders at a different size (verificationMismatch), Hiro retries the same rejected frame in a loop. Band-aids (cooldowns, frame-change suppression) treat symptoms but don't fix the root cause: Hiro should accept what the app actually rendered.

## Design

### Core Principle

When a frame write gets verificationMismatch, **accept the observedFrame** as the window's actual size, update the column width to match, and relayout other columns around it. No retries on verificationMismatch. One write, one accept, one relayout, done.

### Flow

```
Frame write → verify → mismatch detected
  → accept observedFrame as lastAppliedFrame
  → clear failure state
  → notify callback: "window X accepted at size Y"
  → callback updates column cachedWidth
  → scoped relayout repositions other columns
  → next frame write targets accepted size → confirmed ✓
```

### Changes

**AXManager.swift — accept observedFrame on mismatch:**
- `shouldRetryFrameWrite()`: return `false` for `.verificationMismatch`
- `handleFrameApplyResults()`: when confirmedFrame is nil and failureReason is verificationMismatch:
  - If observedFrame exists: set `lastAppliedFrames[windowId] = observedFrame`, clear failure state, call `onFrameAcceptedAtDifferentSize?(windowId, observedFrame)`
  - If observedFrame is nil: just stop (no retry, no accept)
- Add callback: `var onFrameAcceptedAtDifferentSize: ((Int, CGRect) -> Void)?`

**AXManager.swift — revert band-aids:**
- Remove `frameWriteFailureCooldownExpiry`, `verificationMismatchCooldownDuration`
- Remove cooldown check in `enqueueFrameApplications`
- Remove cooldown-aware `hasRecentFailure` logic (restore original `let hasRecentFailure = recentFrameWriteFailures[windowId] != nil`)
- Remove `isInFrameWriteCooldown()` method

**AXEventHandler.swift — revert band-aid:**
- Remove `isInFrameWriteCooldown` check in `handleFrameChanged`

**WMController.swift or LayoutRefreshController.swift — wire callback:**
- On `onFrameAcceptedAtDifferentSize`: look up window token, find workspace and column, update `column.cachedWidth` to observed width, trigger scoped relayout

### What Stays (from earlier session work)

- Scoped relayout (affectedWorkspaceIds) — independent improvement
- Tiered visibility (sliver) — helps off-viewport columns
- Overspread (with toggle exclusions) — helps viewport gaps
- focusNeighbor preserveViewportAnchor — fixes viewport gap
- Logging + privacy annotations

### Edge Cases

- **observedFrame nil:** Don't accept, don't retry. Stop.
- **observedFrame larger than target:** Accept. Column expands, others shrink.
- **observedFrame smaller than target:** Accept. Column shrinks, others get space.
- **Position-only mismatch:** Accept full frame. Next relayout computes correct positions from accepted widths.
- **Multiple mismatches in same relayout:** Each accepted independently, single relayout repositions all.

### Tests

1. verificationMismatch → observedFrame stored as lastAppliedFrame
2. Second write of same target → skipped by existing dirty-tracking (no cooldown needed)
3. shouldRetryFrameWrite returns false for verificationMismatch
4. onFrameAcceptedAtDifferentSize callback fires with correct windowId and frame
5. Column cachedWidth updated when callback fires

### Success Criteria

- Zero verificationMismatch retry loops (one write, one accept, done)
- Chrome/Ghostty render at their preferred size without fighting Hiro
- Other columns automatically adapt to the accepted size
- All existing tests pass
- Net code reduction (remove ~40 lines of cooldown, add ~25 lines of accept)
