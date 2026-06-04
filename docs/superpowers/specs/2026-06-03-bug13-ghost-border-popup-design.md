# Bug #13 Fix: Clear Border When Non-Managed Window No Longer Exists

## Problem

When a transient popup (e.g., Notion Calendar notification) gets focus, Hiro draws a focus border. When the popup dismisses, no CGS destroy event reaches Hiro (popup window not subscribed to CGS events), so the border persists as a ghost outline. The popup's `lastAXConfirmedTarget` stays set in `FocusBorderController` indefinitely.

## Root Cause

1. Non-managed popup gets focus → `focusChanged(to: target)` sets `lastAXConfirmedTarget` and renders border
2. Popup dismisses → macOS doesn't send CGS `spaceWindowDestroyed` (popup not subscribed via `subscribeToWindows`)
3. `clearFocusedTargetForDestroyedWindow()` never fires → `lastAXConfirmedTarget` stays pointing at dead window
4. `renderEligibility()` returns `.update` for all non-managed targets without checking if the window still exists

## Fix

Two changes in `FocusBorderController`:

### 1. Validate non-managed window existence in `renderEligibility`

Before the final `return .update` (line 310), add a check for non-managed targets:

```swift
if !target.isManaged {
    guard let wid = UInt32(exactly: target.windowId) else {
        WMLog.focus.debug("renderEligibility: clear reason=invalidWindowId windowId=\(target.windowId, privacy: .public)")
        return .clear
    }
    let windowExists = windowExistsProviderForTests?(wid)
        ?? (SkyLight.shared.queryWindowInfo(wid) != nil)
    if !windowExists {
        WMLog.focus.debug("renderEligibility: clear reason=nonManagedWindowGone windowId=\(target.windowId, privacy: .public)")
        return .clear
    }
}
```

This catches dead windows on any render cycle. Uses `UInt32(exactly:)` to avoid trapping on invalid IDs.

### 2. Deferred refresh for prompt cleanup

Add a stored Task property and cancel/replace on each `focusChanged` call (matches `DisplayConfigurationObserver.debounceTask` pattern):

```swift
private var nonManagedRefreshTask: Task<Void, Never>?
```

In `focusChanged()`, after the existing code, add cancellation and deferred refresh:

```swift
nonManagedRefreshTask?.cancel()
if let target, !target.isManaged {
    let token = target.token
    nonManagedRefreshTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !Task.isCancelled, let self, self.lastAXConfirmedTarget?.token == token else { return }
        _ = self.refresh()
    }
} else {
    nonManagedRefreshTask = nil
}
```

This ensures that even if no other event triggers a render after the popup dismisses, the dead window is detected within 500ms. The token check prevents refreshing if focus has already moved elsewhere. Storing the Task and cancelling on subsequent calls avoids redundant `queryWindowInfo` calls when rapidly switching between non-managed windows.

### 3. Test hook

Add `windowExistsProviderForTests` closure, matching the `*ForTests` pattern from `AXEventHandler.windowExistsInWindowServerForTests`:

```swift
var windowExistsProviderForTests: ((UInt32) -> Bool)?
```

### Files to Modify

| File | Change |
|------|--------|
| `Sources/OmniWM/Core/Border/FocusBorderController.swift` | Add test hook property, modify `renderEligibility`, modify `focusChanged` |

### What This Does NOT Change

- Managed window border lifecycle (unchanged — managed windows have proper destroy events)
- CGS subscription model (no new subscriptions for popups)
- `enterNonManagedFocus` path (unchanged)
- `BorderManager` (unchanged)

### Performance

- `SkyLight.queryWindowInfo` costs ~5-20 microseconds (Mach IPC to window server)
- Only called when `target.isManaged == false` — rare, short-lived
- `renderEligibility` does NOT run on DisplayLink frames — only on focus changes, layout refreshes, config changes
- The deferred refresh adds one `queryWindowInfo` call per non-managed focus event (500ms after focus)

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Popup dismissed, focus moves to managed window | `focusChanged(to: managedTarget)` replaces target immediately — no ghost |
| Popup dismissed, no focus event fires | Deferred refresh at 500ms detects dead window → `.clear` |
| Popup still exists when deferred refresh fires | `queryWindowInfo` returns non-nil → no change |
| Multiple rapid non-managed focus changes | Each deferred refresh checks its own token — stale ones no-op |
| Negative or overflowed windowId | `UInt32(exactly:)` returns nil → `.clear` |

### Tests

Create `Tests/OmniWMTests/FocusBorderControllerTests.swift`. Tests need a `WMController` instance (since `renderEligibility` calls `controller.isOwnedWindow` and `controller.workspaceManager.entry(for:)` before reaching the non-managed check). Use `WMController(settings: SettingsStore(defaults: ...))` as in `ServiceLifecycleManagerTests`.

1. **Non-managed target with dead window clears border** — Create controller, set `windowExistsProviderForTests` to return `false`, call `focusChanged` with non-managed target, call `refresh()`, assert `currentTarget == nil`
2. **Non-managed target with live window renders border** — Set `windowExistsProviderForTests` to return `true`, call `focusChanged` with non-managed target, assert `currentTarget != nil`

## Verification

1. `swift build` compiles
2. Tests pass
3. Restart Hiro, trigger a Notion Calendar notification:
   - Border appears when popup gets focus
   - Border disappears within 500ms after popup dismisses
   - Logs show `"renderEligibility: clear reason=nonManagedWindowGone"`
