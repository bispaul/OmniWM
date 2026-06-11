# Quick Wins: F2 (Ghost Border Guard) + F3 (Invariant Checks)

**Date:** 2026-06-11
**Build:** 100
**Branch:** fix/scope-relayout-to-workspace
**Expert validation:** Architect + DA + Coder (all approved, SSOT-compliant)

## F2: Ghost Border `isOwnedWindow` Guard

**File:** `Sources/OmniWM/Core/Controller/AXEventHandler.swift:592`
**Change:** 1 line

Add `isOwnedWindow` check to `handleCGSWindowDestroyed`, matching the pattern already used in `processCreatedWindow` at line 278.

```swift
// After line 592 (WMLog.ax.info("Window destroyed:")):
if controller?.isOwnedWindow(windowNumber: Int(windowId)) == true { return }
```

**Effect:** Eliminates border window create→destroy churn (10 cycles in 30min). The create handler already has this guard; the destroy handler was the only path missing it.

## F3: 3 Invariant Checks

**File:** `Sources/OmniWM/Core/Reconcile/InvariantChecks.swift`
**Change:** ~50 lines added to `validate(snapshot:)`

### Check 1: `duplicate_window_token`
Build a token frequency map from `snapshot.windows`. Flag any token appearing more than once.

```swift
var tokenCounts: [WindowToken: Int] = [:]
for window in snapshot.windows {
    tokenCounts[window.token, default: 0] += 1
}
for (token, count) in tokenCounts where count > 1 {
    violations.append(.init(
        code: "duplicate_window_token",
        message: "Window token \(token) appears \(count) times in the runtime snapshot."
    ))
}
```

### Check 2: `focused_token_destroyed`
If the focused token points to a window with `lifecyclePhase == .destroyed`, flag it. This is more specific than the existing `destroyed_window_focused` check (which catches it in the per-window loop) — it checks from the focus side.

```swift
if let focusedToken = snapshot.focusedToken,
   let focusedWindow = snapshot.windows.first(where: { $0.token == focusedToken }),
   focusedWindow.lifecyclePhase == .destroyed
{
    violations.append(.init(
        code: "focused_token_destroyed",
        message: "Focused token \(focusedToken) points to a destroyed window."
    ))
}
```

### Check 3: `pending_focus_dead`
If `pendingManagedFocus.token` references a token not in the live window set, flag it.

```swift
if let pendingToken = snapshot.focusSession.pendingManagedFocus.token,
   !liveTokens.contains(pendingToken)
{
    violations.append(.init(
        code: "pending_focus_dead",
        message: "Pending managed focus token \(pendingToken) is not in the runtime snapshot."
    ))
}
```

## F4: requestId on Focus Events — DEFERRED

Adding `requestId` to WMEvent focus cases requires updating 8+ exhaustive switch statements across Reconcile/, Controller/, and Tests/. This is a cross-cutting change, not a quick win. Deferred to a dedicated session.

## SSOT Compliance

- F2: No SSOT impact — prevents unnecessary processing of OmniWM's own windows
- F3: STRENGTHENS SSOT — adds runtime detection of invariant violations
- Neither change modifies any Phase 1-5 or Fix A-E code path

## Test Plan

1. F2: Deploy, check logs for 0 `Removing window state for pid=<OmniWM PID>` events
2. F3: Existing `InvariantChecks.validate()` callers will pick up new checks automatically. Verify no false positives in normal operation via log/IPC.

## Files Changed

1. `Sources/OmniWM/Core/Controller/AXEventHandler.swift` — F2: 1-line guard
2. `Sources/OmniWM/Core/Reconcile/InvariantChecks.swift` — F3: 3 invariant checks
