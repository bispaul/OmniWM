# Bug #1 Fix: Break AX Frame Write Race Loop

## Problem

When Hiro writes a frame to VSCode/Chrome, the app resizes itself back. Hiro's verification sees `verificationMismatch`. Scheduled relayouts re-enqueue the SAME failing frame, clearing the suppression state. 20+ failures in 3.5s.

## Root Cause

`enqueueFrameApplications` line 484 unconditionally clears `recentFrameWriteFailures` on every enqueue, resetting the suppression. `retryBudgetByWindowId` is reset to 1 on every non-retry enqueue.

## Fix

Add `recentFailedFrames: [Int: CGRect]` to track the target frame that failed. When re-enqueuing the same frame, skip the write but **notify the terminal observer** with a no-op success result. When a DIFFERENT frame is requested, clear failure state and proceed.

### Changes in `AXManager.swift`:

**1. Add property:**
```swift
private var recentFailedFrames: [Int: CGRect] = [:]
```

**2. Store failed frame** — in `handleFrameApplyResults`, after `recentFrameWriteFailures[resolvedWindowId] = failureReason`:
```swift
recentFailedFrames[resolvedWindowId] = resolvedResult.targetFrame
```

**3. Clear on success** — in `handleFrameApplyResults`, after `recentFrameWriteFailures.removeValue` (success path):
```swift
recentFailedFrames.removeValue(forKey: resolvedWindowId)
```

**4. Skip same-frame re-enqueue** — in `enqueueFrameApplications`, INSIDE the `if !shouldForceApply` block, after the pending/cached skip checks, BEFORE `pendingFrameWrites[windowId] = frame`:

```swift
if let failedFrame = recentFailedFrames[windowId],
   failedFrame.approximatelyEqual(to: frame, tolerance: 0.5)
{
    WMLog.ax.debug("enqueueFrameApplications: skippedSameFailedFrame windowId=\(windowId, privacy: .public)")
    if let terminalObserver {
        terminalObserver(
            successfulNoOpFrameApplyResult(
                requestId: makeNextFrameApplicationRequestId(),
                pid: pid,
                windowId: windowId,
                frame: frame,
                currentFrameHint: cachedFrame,
                observedFrame: cachedFrame ?? frame
            )
        )
    }
    continue
}
```

Then on the lines after (the existing code path for new frames):
```swift
pendingFrameWrites[windowId] = frame
recentFrameWriteFailures.removeValue(forKey: windowId)
recentFailedFrames.removeValue(forKey: windowId)
```

**5. Clear in all cleanup paths** — add `recentFailedFrames.removeValue(forKey:)` alongside `recentFrameWriteFailures` in:
- `removeWindowState` 
- `cleanup`
- `suppressFrameWrites`
- `confirmFrameWrite`

**6. Rekey in `rekeyWindowState`** — alongside the existing rekey of `recentFrameWriteFailures`:
```swift
if let failedFrame = recentFailedFrames.removeValue(forKey: oldWindowId) {
    recentFailedFrames[newWindowId] = failedFrame
}
```

### How This Breaks the Loop

1. Frame write fails → `recentFailedFrames[W] = frameX`
2. AX event suppressed by `shouldSuppressFrameChangeRelayout` ✓
3. Scheduled relayout re-enqueues frameX → matches `recentFailedFrames[W]` → **skipped** ✓
4. Observer notified with no-op result → no hanging callers ✓
5. User resizes (new frameY) → different frame → failure cleared → write proceeds ✓

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Same frame re-enqueued | Skipped, observer notified with no-op |
| Different frame requested | Failure cleared, write proceeds |
| Force-apply flag set | `!shouldForceApply` guard — force-applied frames NOT skipped |
| Window destroyed | Both dicts cleaned up in `removeWindowState` |
| Window ID rekeyed | Both dicts rekeyed |
| Terminal observer on skipped write | Called with `successfulNoOpFrameApplyResult` |

### Files to Modify

| File | Change |
|------|--------|
| `Sources/OmniWM/Core/Ax/AXManager.swift` | Add `recentFailedFrames`, modify `enqueueFrameApplications`, `handleFrameApplyResults`, cleanup/rekey paths |

## Verification

1. `swift build` compiles
2. Tests pass
3. Restart Hiro, trigger the race: move windows on Retina with VSCode on 32"
4. Logs: `"skippedSameFailedFrame"` instead of 20+ `verificationMismatch`
5. No "too small to render" flash
