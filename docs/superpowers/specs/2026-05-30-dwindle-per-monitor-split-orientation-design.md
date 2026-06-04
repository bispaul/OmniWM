# Dwindle Per-Monitor Split Orientation Fix

## Problem

`DwindleLayoutEngine.splitLeaf()` determines split orientation (horizontal vs vertical) using the global `settings.splitWidthMultiplier` instead of per-monitor `effectiveSettings(for: monitorId)`. This means `monitorDwindleOverrides` in `settings.toml` have no effect on split direction when windows are added.

Additionally, existing DwindleNode splits never re-orient when settings change (hot-reload or sleep/wake), because the `.horizontal`/`.vertical` orientation is set once at creation and never revisited.

### Reproduction

1. Configure `monitorDwindleOverrides` with `splitWidthMultiplier = 10.0` for a portrait monitor
2. Add windows to a Dwindle workspace on that monitor
3. Windows split side-by-side (horizontal) instead of top-to-bottom (vertical)
4. Changing the setting and saving doesn't fix existing splits

### Root Cause

- `addWindow()` → `splitLeaf()` → `planSplit()` → `aspectOrientation()` all use `self.settings` (global)
- `effectiveSettings(for: monitorId)` exists and correctly merges per-monitor overrides, but is never called in the split creation path
- The `applyResolvedSettings()` call in `buildRelayoutPlan()` overwrites `engine.settings` with the correct per-monitor values, but only before `calculateLayout` — if windows are added in a different context (e.g., sleep/wake restore order), the wrong monitor's settings may be active

## Design

### Part 1: Thread monitorId through split creation

Add `monitorId: Monitor.ID` parameter to:

- `addWindow(token:to:activeWindowFrame:)` → `addWindow(token:to:monitorId:activeWindowFrame:)`
- `splitLeaf(_:newWindow:workspaceId:activeWindowFrame:preselectedDirection:)` → add `monitorId`
- `planSplit(targetRect:activeWindowFrame:)` → add `monitorId`
- `aspectOrientation(for:)` → add `monitorId`

Each method calls `effectiveSettings(for: monitorId)` instead of using `self.settings` for split-direction-relevant properties (`splitWidthMultiplier`, `smartSplit`, `defaultSplitRatio`).

### Part 2: Re-orient existing splits on settings change

Add new method to `DwindleLayoutEngine`:

```swift
func reorientSplits(for workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) {
    guard let root = roots[workspaceId] else { return }
    let settings = effectiveSettings(for: monitorId)
    reorientRecursive(node: root, settings: settings)
}

private func reorientRecursive(node: DwindleNode, settings: DwindleSettings) {
    guard case .split(_, let ratio) = node.kind else { return }
    if let frame = node.cachedFrame {
        let newOrientation = aspectOrientationFromSettings(for: frame, settings: settings)
        node.kind = .split(orientation: newOrientation, ratio: ratio)
    }
    for child in node.children {
        reorientRecursive(node: child, settings: settings)
    }
}
```

### Part 3: Call reorientSplits on settings change

In `WMController.updateMonitorDwindleSettings()`, after updating engine settings, call `reorientSplits` for each workspace assigned to each monitor.

### Callers to update

- `syncWindows` (DwindleLayoutEngine.swift) — pass `monitorId` to `addWindow`
- `summonWindowRight` (DwindleLayoutEngine.swift) — pass `monitorId` to `addWindow`
- `buildRelayoutPlan` (DwindleLayoutHandler.swift) — pass monitor info through `syncWindows`

### Files modified

1. `Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift` — thread monitorId, add reorientSplits
2. `Sources/OmniWM/Core/Controller/DwindleLayoutHandler.swift` — pass monitorId through calls
3. `Sources/OmniWM/Core/Controller/WMController.swift` — call reorientSplits on settings update

### Verification

1. Build: `swift build -c debug` (must compile clean)
2. Manual test: Set `splitWidthMultiplier = 10.0` for portrait monitor, add windows — should split top/bottom
3. Hot-reload test: Change `splitWidthMultiplier`, save TOML — existing splits should re-orient
4. Sleep/wake test: Close lid, reopen — splits should restore with correct orientation
