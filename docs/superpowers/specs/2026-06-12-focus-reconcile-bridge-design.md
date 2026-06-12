# Focus Reconciliation Through Bridge

**Date:** 2026-06-12
**Build:** 107 (target)
**Bug:** Architecture smell #7 — focusWindow racing paths

## Problem

`reconcileFocusBeforeCommand` (WMController.swift:2857) calls `performWindowFronting` directly, bypassing `focusBridge.focusWindow`. This means the hotkey reconciliation path is not serialized by the bridge's `isFocusOperationPending` gate. A deferred focus from a previous operation can execute while reconciliation is in progress.

DA-confirmed failure scenario: hotkey triggers reconcile → `performWindowFronting` direct. Simultaneously deferred focus fires. Both operate without bridge gating.

## Fix

Replace `performWindowFronting(pid:windowId:axRef:)` with `focusWindow(borderTarget.token)` in `reconcileFocusBeforeCommand`. This routes the reconciliation through the full focus pipeline:
1. `focusBridge.focusWindow` — serialization via `isFocusOperationPending`
2. `performWindowFronting` — AX focus (called by the bridge)
3. `probeFocusedWindowAfterFronting` — AX confirmation

```swift
// Before:
performWindowFronting(
    pid: borderTarget.pid,
    windowId: borderTarget.token.windowId,
    axRef: borderTarget.axRef
)

// After — route through bridge for serialization, but keep performWindowFronting
// (NOT focusWindow, which triggers workspace switching via applyFocusReconcileEvent):
focusBridge.focusWindow(
    borderTarget.token,
    performFocus: {
        performWindowFronting(
            pid: borderTarget.pid,
            windowId: borderTarget.token.windowId,
            axRef: borderTarget.axRef
        )
    },
    onDeferredFocus: { [weak self] deferred in
        guard let self, self.workspaceManager.entry(for: deferred) != nil else { return }
        self.focusWindow(deferred)
    }
)
```

## Why This Is Safe

- Routes through `focusBridge.focusWindow` for `isFocusOperationPending` serialization
- Keeps `performWindowFronting` (no workspace switching — reconciliation only syncs macOS focus)
- Does NOT call `focusWindow(token)` directly — that would trigger `beginManagedFocusRequest` → `applyFocusReconcileEvent` which could switch workspaces (expert reviewer finding)
- The bridge's dedup (`pendingFocusToken == token` within 16ms) prevents redundant focus
- Deferred focus handler uses the full `focusWindow` path (correct for deferred — those ARE workspace-aware operations)

## Test Plan

1. **Unit: reconcileFocusBeforeCommand goes through bridge** — verify `isFocusOperationPending` is set during reconciliation
2. **Regression: existing reconcile tests** — `reconcileFocusBeforeCommand` tests in WMControllerFocusTests still pass
3. **Regression: all focus tests** — no change to focusWindow behavior

## Edge Case

`focusWindow(token)` requires `workspaceManager.entry(for: token)` to exist. `reconcileFocusBeforeCommand` gets the token from `focusBorderController.currentTarget` — this entry SHOULD exist (the border is showing for it). If the entry was removed between border rendering and reconciliation, `focusWindow` returns early (line 3039: `guard let entry`). This is correct — don't focus a removed window.
