# OmniWM/Hiro Audit Results: Logging & Test Infrastructure

Date: 2026-05-31
Scope: All source files under `Sources/OmniWM/` and `Tests/OmniWMTests/`
Logger: `WMLog` enum in `Sources/OmniWM/Core/Support/Loggers.swift` (categories: ax, layout, focus, input, config, ipc, workspace)

---

## Summary

| Metric | Value |
|---|---|
| Total existing log statements | 27 |
| Files with logs | 11 |
| Files missing logs (should have them) | 7 |
| Missing log statements (in files WITH logs) | 13 |
| Missing log statements (in files WITHOUT logs) | 16 |
| **Total logging actions** | **29 log additions across 18 files** |
| Total tests | 1,385 |
| AX-dependent tests | 25 |
| Tests at risk (unmocked AX calls) | **0** |
| Unused `ForTests` properties (dead code) | 4 |

---

## Priority 1: Add Logging to Files With Zero Log Statements

These 7 files have no `WMLog` calls. Each needs `import os` added (except SettingsFilePersistence which already has it) and the listed log statements inserted.

### 1.1 AppAXContext.swift (AX context lifecycle)

**File**: `Sources/OmniWM/Core/Ax/AppAXContext.swift`
**Needs**: `import os` added to imports

| Method | Line | Log to add |
|---|---|---|
| `getOrCreate(_:)` | ~157 (after `contexts[pid] = context`) | `WMLog.ax.info("AX context created: pid=\(pid)")` |
| `destroy()` | ~699 (top of method) | `WMLog.ax.info("AX context destroyed: pid=\(pid)")` |

**Exact change for getOrCreate** -- add after the line that stores the context in the dictionary:
```swift
WMLog.ax.info("AX context created: pid=\(nsApp.processIdentifier)")
```

**Exact change for destroy** -- add as first line of `func destroy()`:
```swift
WMLog.ax.info("AX context destroyed: pid=\(pid)")
```

### 1.2 SettingsFilePersistence.swift (config reload lifecycle)

**File**: `Sources/OmniWM/Core/Config/SettingsFilePersistence.swift`
**Needs**: Already has `import os`

| Method | Line | Log to add |
|---|---|---|
| `handlePossibleSettingsFileChange()` | ~224 (before `onExternalChange`) | `WMLog.config.info("Settings file change detected")` |
| `reloadIfChanged()` | ~173 (on success path) | `WMLog.config.info("Settings reloaded from disk")` |
| `load()` | ~87 (catch block ~100) | `WMLog.config.error("Settings load failed: \(error)")` |

### 1.3 SettingsStore.swift (config application)

**File**: `Sources/OmniWM/Core/Config/SettingsStore.swift`
**Needs**: `import os` added to imports

| Method | Line | Log to add |
|---|---|---|
| `applyExport(_:monitors:)` | 591 (top of method) | `WMLog.config.info("Applying settings export with \(monitors.count) monitors")` |

### 1.4 DwindleLayoutEngine.swift (layout decisions)

**File**: `Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift`
**Needs**: `import os` added to imports

| Method | Line | Log to add |
|---|---|---|
| `addWindow(token:to:...)` | 124 (top of method) | `WMLog.layout.debug("Dwindle: added window token=\(token) to workspace=\(workspaceId)")` |
| `splitLeaf(...)` | ~174 (after orientation computed) | `WMLog.layout.debug("Dwindle: split orientation=\(orientation)")` |
| `removeWindow(token:from:)` | 249 (top of method) | `WMLog.layout.info("Dwindle: removed window token=\(token) from workspace=\(workspaceId)")` |

### 1.5 NiriLayoutEngine.swift (layout decisions)

**File**: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine.swift`
**Needs**: `import os` added to imports

| Method | Line | Log to add |
|---|---|---|
| `initializeNewColumnWidth(_:in:)` | 193 (top of method) | `WMLog.layout.debug("Niri: column initialized in workspace=\(workspaceId)")` |

### 1.6 WorkspaceNavigationHandler.swift (workspace navigation)

**File**: `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift`
**Needs**: `import os` added to imports

| Method | Line | Log to add |
|---|---|---|
| `switchWorkspace(rawWorkspaceID:)` | 248 (top of method) | `WMLog.workspace.info("Workspace switch: target=\(rawWorkspaceID)")` |
| `switchToMonitor(_:fromMonitor:)` | 176 (top of method) | `WMLog.workspace.info("Cross-monitor transition: from=\(currentMonitorId) to=\(targetMonitorId)")` |
| `switchWorkspaceRelative(isNext:wrapAround:)` | 281 (top of method) | `WMLog.workspace.debug("Workspace switch relative: isNext=\(isNext) wrapAround=\(wrapAround)")` |

### 1.7 KeyboardFocusLifecycleCoordinator.swift (focus lease lifecycle)

**File**: `Sources/OmniWM/Core/Controller/KeyboardFocusLifecycleCoordinator.swift`
**Needs**: `import os` added to imports
**Note**: File contains class `FocusBridgeCoordinator` (not `KeyboardFocusLifecycleCoordinator`)

| Method | Line | Log to add |
|---|---|---|
| `beginManagedRequest(...)` | 49 (top of method) | `WMLog.focus.debug("Focus lease begin: token=\(token)")` |
| `confirmManagedRequest(...)` | 113 (top of method) | `WMLog.focus.debug("Focus lease confirmed: token=\(token)")` |
| `discardPendingFocus(_:)` | 159 (top of method) | `WMLog.focus.debug("Focus lease discarded: token=\(token)")` |

---

## Priority 2: Add Missing Log Statements to Files That Already Have Logging

These 7 files already use `WMLog` but are missing logs at key code paths.

### 2.1 AXManager.swift

**File**: `Sources/OmniWM/Core/Ax/AXManager.swift`
**Existing logs**: 5

| Location | Line | Log to add |
|---|---|---|
| `enqueueFrameApplications` loop, when frame dispatched to AppAXContext | ~418 (inside `for (pid, windowId, frame) in frames` loop, at the dispatch point) | `WMLog.ax.debug("Frame write dispatched: windowId=\(windowId) frame=\(frame)")` |
| `confirmFrameWrite(for:frame:)` | 231 (top of method) | `WMLog.ax.debug("Frame write confirmed: windowId=\(windowId) frame=\(frame)")` |
| `rekeyWindowState(pid:oldWindowId:newWindow:)` | 185 (after guard, top of method body) | `WMLog.ax.info("Window state rekeyed: old=\(oldWindowId) new=\(newWindowId) pid=\(pid)")` |

**Note**: The audit suggested `addWindowState` but no such method exists. The counterpart to `removeWindowState` is `rekeyWindowState` (rekeys an existing state) and the initial state is created implicitly during `enqueueFrameApplications`. The `rekeyWindowState` log is the correct addition.

### 2.2 LayoutRefreshController.swift

**File**: `Sources/OmniWM/Core/Controller/LayoutRefreshController.swift`
**Existing logs**: 2

| Location | Line | Log to add |
|---|---|---|
| `getOrCreateDisplayLink(for:)` | 221 (when creating new link) | `WMLog.layout.debug("Display link created: displayId=\(displayId)")` |
| `cleanupForMonitorDisconnect(displayId:migrateAnimations:)` | 238 (top of method) | `WMLog.layout.debug("Display link invalidated: displayId=\(displayId)")` |
| `requestFullRescan(reason:)` | 721 (top of method) | `WMLog.layout.debug("Full rescan requested: reason=\(reason)")` |

### 2.3 WMController.swift

**File**: `Sources/OmniWM/Core/Controller/WMController.swift`
**Existing logs**: 3

| Location | Line | Log to add |
|---|---|---|
| `focusWindow(_ token:)` | 2905 (top of method) | `WMLog.focus.info("Focus window: token=\(token)")` |
| `setFocusFollowsMouse(_:)` | 635 (top of method) | `WMLog.config.info("Focus follows mouse: enabled=\(enabled)")` |

### 2.4 MouseEventHandler.swift

**File**: `Sources/OmniWM/Core/Controller/MouseEventHandler.swift`
**Existing logs**: 2

| Location | Line | Log to add |
|---|---|---|
| Mouse tap re-enabled after timeout | 231 (`CGEvent.tapEnable(tap: tap, enable: true)`) | `WMLog.input.debug("Mouse event tap re-enabled after timeout")` |
| Gesture tap re-enabled after timeout | 266 (`CGEvent.tapEnable(tap: tap, enable: true)`) | `WMLog.input.debug("Gesture tap re-enabled after timeout")` |

### 2.5 FocusBorderController.swift

**File**: `Sources/OmniWM/Core/Border/FocusBorderController.swift`
**Existing logs**: 2

| Location | Line | Log to add |
|---|---|---|
| `hide()` | 110 (top of method) | `WMLog.focus.debug("Focus border hidden")` |

### 2.6 Hotkeys.swift

**File**: `Sources/OmniWM/Core/Input/Hotkeys.swift`
**Existing logs**: 2

| Location | Line | Log to add |
|---|---|---|
| `dispatch(id:)` | 480 (at dispatch point) | `WMLog.input.debug("Hotkey command dispatched: id=\(id)")` |
| `dispatchSequenceCommandLater(_:)` | 691 (top of method) | `WMLog.input.debug("Sequence command dispatched: \(command)")` |

### 2.7 WorkspaceManager.swift

**File**: `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift`
**Existing logs**: 2

| Location | Line | Log to add |
|---|---|---|
| `removeWindowsForApp(pid:)` | 2644 (top of method, log count) | `WMLog.workspace.info("Removing all windows for app: pid=\(pid)")` |

### 2.8 IPCCommandRouter.swift

**File**: `Sources/OmniWM/IPC/IPCCommandRouter.swift`
**Existing logs**: 1

| Location | Line | Log to add |
|---|---|---|
| `handle(_:)` return point | 15 (before each `return` or at function exit) | `WMLog.ipc.debug("IPC command result: \(result)")` |

**Implementation note**: The `handle` method is a large switch statement with many return points. The cleanest approach is to capture the result and log once:
```swift
func handle(_ request: IPCCommandRequest) -> ExternalCommandResult {
    WMLog.ipc.debug("IPC command received: \(String(describing: request))")
    let result: ExternalCommandResult
    switch request {
    // ... existing cases assigning to result ...
    }
    WMLog.ipc.debug("IPC command result: \(result)")
    return result
}
```
Alternatively, add the log only to the primary `handle(_ request: IPCCommandRequest)` method at line 15, wrapping its body.

---

## Priority 3: Test Infrastructure -- AX Mocking Status

### Result: All 25 AX-dependent tests are properly mocked. Zero tests at risk.

Every test that calls `applyFramesParallel` uses one of these mock mechanisms:
- `frameApplyOverrideForTests` -- intercepts all AX frame writes at the AXManager level
- `withAXFrameProviderIsolationForTests` + `setFrameResultProviderForTests` -- intercepts at the AXWindow level
- `installSynchronousFrameApplySuccessOverride` -- convenience wrapper that records frames to `lastAppliedFrame`
- `liveFrameProviderForTests` -- provides mock frame reads
- `fastFrameProviderForTests` -- provides fast-path frame reads

**No action required for test mocking.**

---

## Priority 4: Dead Test Infrastructure (Unused `ForTests` Properties)

These 4 properties exist in production source but are never referenced in any test file. They are dead code that can be safely removed.

| File | Property | Notes |
|---|---|---|
| `Sources/OmniWM/Core/Border/FocusBorderController.swift` | `suppressNextFrameHintForTests` | Not referenced in any test |
| `Sources/OmniWM/Core/Layout/Niri/TabbedColumnOverlay.swift` | `orderingHookForTests` | Not referenced in any test |
| `Sources/OmniWM/Core/Controller/AXEventHandler.swift` | `managedReplacementTimeSourceForTests` | Not referenced in any test |
| `Sources/OmniWM/QuakeTerminal/QuakeTerminalController.swift` | `isTransitioningForTests` | Not referenced in any test |

**Action**: Remove each property declaration and any internal references to it within the same file. These are safe deletions -- no test depends on them.

---

## Implementation Order

1. **Priority 1** (7 files, 16 log additions) -- Add logging to files with zero coverage. These are the biggest observability gaps. Start with `AppAXContext.swift` (AX lifecycle), `WorkspaceNavigationHandler.swift` (workspace nav), and `KeyboardFocusLifecycleCoordinator.swift` (focus lease) as they cover the most-debugged subsystems.

2. **Priority 2** (8 files, 13 log additions) -- Fill gaps in files that already have partial logging. Start with `AXManager.swift` (frame write confirmation), `LayoutRefreshController.swift` (display link lifecycle), and `WMController.swift` (focus/config).

3. **Priority 3** -- No action. Test mocking is solid.

4. **Priority 4** (4 files, 4 deletions) -- Remove dead `ForTests` properties. Low priority, pure cleanup.

---

## Files Changed Summary

| Action | File Count | Changes |
|---|---|---|
| Add `import os` | 6 files | AppAXContext, SettingsStore, DwindleLayoutEngine, NiriLayoutEngine, WorkspaceNavigationHandler, KeyboardFocusLifecycleCoordinator |
| Add log statements | 15 files | 29 new `WMLog.*` calls total |
| Remove dead code | 4 files | 4 unused `ForTests` property deletions |
| Fix test mocking | 0 files | None needed |
