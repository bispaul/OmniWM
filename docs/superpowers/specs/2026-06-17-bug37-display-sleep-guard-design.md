# Bug #37 Fix: Arm SkyLight Guard on Display Disconnect

## Problem

Display sleep (screen off, Mac awake) disconnects/reconnects displays. CGS
destroy events arrive during a 400ms unprotected window before isReconciling
is set. 26 windows permanently removed from workspace tracking.

## Root Cause

1. `willSleepNotification` only fires for system sleep, not display sleep
2. `isReconciling` is set 400ms after disconnect (100ms debounce + 300ms coalesce)
3. CGS destroy events arrive during this gap with NO guard armed
4. `windowExistsInWindowServer` returns false during display sleep (window already
   removed from server when CGS event fires)

## Fix (4 changes, expert-validated)

### Change 1: Early isReconciling on disconnect
`ServiceLifecycleManager.handleDisplayEvent` — on `.disconnected`, set
`controller.workspaceManager.isReconciling = true` immediately.

### Change 2: Relax SkyLight guard during isReconciling
`AXEventHandler.handleCGSWindowDestroyed` (~line 597) — change:
```swift
if isInProtectedWindow, windowExistsInWindowServer(windowId)
```
to:
```swift
if isInProtectedWindow, (controller?.workspaceManager.isReconciling == true || windowExistsInWindowServer(windowId))
```
During topology reconciliation, suppress ALL destroys for tracked windows
even if window is gone from server. During wake (isAwaitingRestore only),
keep the stricter check.

### Change 3: Relax correlator replay guard
`AXEventHandler.correlatorShouldSuppressDestroyReplay` (~line 2936) — same
relaxation as Change 2. Without this, suppressed direct destroys leak through
the correlator replay path.

### Change 4: Re-arming safety timeout
`ServiceLifecycleManager.handleDisplayEvent` — on `.disconnected`, start/restart
a 5s Task that force-clears `isReconciling`. Re-arm on each disconnect (not just
first). Cancel in `applyMonitorConfigurationChanged` before clearing isReconciling.

## Safety

- Phantom windows from suppressed user-closes (Command+W during topology change)
  are cleaned up by `requestFullRescan` → `removeMissing` in
  `applyMonitorConfigurationChanged`. No permanent data corruption.
- 5s timeout re-arms on each coalesce restart — handles sequential Thunderbolt
  hub reconnections. Falls back to force-clear if applyMonitorConfigurationChanged
  never runs.
- Physical monitor unplug: same protection is CORRECT behavior — suppresses
  spurious CGS events during topology storm.

## Files Changed

1. `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` — early arming + timeout
2. `Sources/OmniWM/Core/Controller/AXEventHandler.swift` — relax both guard sites

## Test Plan

1. Existing SkyLight guard tests must pass
2. Runtime: display sleep → wake, verify 0 workspace window removals in logs
3. Runtime: physical monitor unplug, verify windows relocate correctly

## Evidence

- Memorygraph: `b3d5fb26` (Bug #37 root cause)
- Expert: traced 400ms race condition, validated early arming
- DA: confirmed windowExistsInWindowServer unreliable during display sleep
- Panel: APPROVED with correlator guard fix + re-arming timeout
