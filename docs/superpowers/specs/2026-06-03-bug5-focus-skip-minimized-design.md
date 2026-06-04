# Bug #5 Fix: Skip Minimized Windows During Focus Navigation

## Problem

`focusNeighbor` (Caps+H/L) targets minimized windows. When the next column contains a minimized window, macOS unminimizes it (dock animation), disrupting workflow.

## Root Cause

1. When miniaturized, the AX callback only clears keyboard focus — no state is recorded
2. `NiriNavigation.focusTarget` traverses the node tree without checking minimized state
3. `activateNode` triggers AX focus which macOS interprets as unminimize request
4. `isManagedWindowDisplayable` doesn't detect minimized windows (only checks hiddenAppPIDs, layoutReason, isHiddenInCorner)

## Fix

Two changes:

### 1. Track miniaturized state in `handleWindowMiniaturized`

Add a `miniaturizedWindowIds: Set<Int>` to track which windows are miniaturized. Set it in `handleWindowMiniaturized`, clear it when a window is re-focused or destroyed.

In `AXEventHandler.swift`:
```swift
private var miniaturizedWindowIds: Set<Int> = []

func handleWindowMiniaturized(pid: pid_t, windowId: Int) {
    miniaturizedWindowIds.insert(windowId)
    controller?.clearKeyboardFocusTarget(
        matching: WindowToken(pid: pid, windowId: windowId),
        pid: pid
    )
}
```

Clear the flag when the window is activated or destroyed. OmniWM does NOT subscribe to `kAXWindowDeminiaturizedNotification`, so clearing must happen in `handleAppActivation` (catches all unminimize paths: dock click, Cmd+Tab, app icon click):
```swift
// In handleAppActivation, after resolving axRef (around line 1247):
miniaturizedWindowIds.remove(axRef.windowId)

// In handleWindowDestroyed (around line 790):
miniaturizedWindowIds.remove(Int(windowId))

// In cleanupFocusStateForTerminatedApp (AXEventHandler.swift ~line 3250):
// App termination bypasses handleRemoved — clean up here instead
let terminatedWindowIds = Set(entries.map { $0.token.windowId })
miniaturizedWindowIds.subtract(terminatedWindowIds)
```

Expose via a method:
```swift
func isWindowMiniaturized(_ windowId: Int) -> Bool {
    miniaturizedWindowIds.contains(windowId)
}
```

### 2. Skip miniaturized windows in `focusNeighbor`

In `NiriLayoutHandler.focusNeighbor`, wrap the `focusTarget` call in a loop that skips miniaturized nodes:

```swift
var candidateNode = currentNode
var attempts = 0
let maxAttempts = controller.workspaceManager.tiledEntries(in: wsId).count
while attempts < maxAttempts,
      let newNode = engine.focusTarget(
          direction: direction,
          currentSelection: candidateNode,
          in: wsId,
          motion: controller.motionPolicy.snapshot(),
          state: &state,
          workingFrame: workingFrame,
          gaps: gap
      )
{
    attempts += 1
    if let windowNode = newNode as? NiriWindow,
       controller.axEventHandler.isWindowMiniaturized(windowNode.token.windowId)
    {
        WMLog.focus.debug("focusNeighbor: skipping minimized windowId=\(windowNode.token.windowId, privacy: .public)")
        candidateNode = newNode
        continue
    }
    WMLog.focus.debug("focusNeighbor: direction=\(String(describing: direction), privacy: .public) targetNode=\(String(describing: newNode.id), privacy: .public)")
    activateNode(newNode, in: wsId, state: &state, options: .init(activateWindow: false, ensureVisible: false))
    break
}
```

**Key details:**
- `maxAttempts` caps iterations at column count + 1 to prevent infinite loops (handles `infiniteLoop` wrapping setting)
- Uses `isWindowMiniaturized` instead of `isManagedWindowDisplayable` — directly checks the tracked miniaturized state
- **Viewport state is mathematically correct during skips.** `ensureSelectionVisible` uses `offset(delta:)` which is additive. The deltas telescope: delta(current→skip1) + delta(skip1→skip2) + delta(skip2→target) = delta(current→target). Intermediate positions cancel out. No save/restore needed.

### Files to Modify

| File | Change |
|------|--------|
| `Sources/OmniWM/Core/Controller/AXEventHandler.swift` | Add `miniaturizedWindowIds` set, modify `handleWindowMiniaturized`, add `isWindowMiniaturized`, clear on activation/destroy |
| `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift` | Modify `focusNeighbor` to loop and skip minimized |

### What This Does NOT Change

- Layout engine (NiriNavigation) stays pure — no modifications
- Minimized windows stay in the layout tree (existing behavior)
- Direct focus via IPC is not affected
- `isManagedWindowDisplayable` is not modified (separate concern)

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| All windows in direction are minimized | Loop exhausts maxAttempts, focus stays on current |
| Only 1 visible window, rest minimized | Focus stays on current |
| Window unminimized between check and activate | `miniaturizedWindowIds` already cleared by activation handler, harmless |
| `infiniteLoop` wrapping enabled, all minimized | maxAttempts cap prevents infinite loop |
| Window minimized then immediately unminimized | Rapid AX callbacks update the set correctly |

### Tests

1. **`isWindowMiniaturized` tracks state correctly** — call `handleWindowMiniaturized`, verify `isWindowMiniaturized` returns true, then clear, verify returns false
2. **Focus skips minimized window** — integration test: set up layout, mark window as minimized, verify `focusNeighbor` skips it

## Verification

1. `swift build` compiles
2. Tests pass
3. Minimize a window (Cmd+M), press Caps+H/L — focus should skip the minimized window
4. Logs show `"focusNeighbor: skipping minimized"`
