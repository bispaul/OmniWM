# Dwindle Per-Monitor Split Orientation Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Dwindle split orientation respect per-monitor `splitWidthMultiplier` overrides, and re-orient existing splits when settings change.

**Architecture:** Thread `monitorId` through `addWindow` → `splitLeaf` → `planSplit` → `aspectOrientation` so each method reads `effectiveSettings(for: monitorId)` instead of the global `settings`. Add `reorientSplits(for:monitorId:)` to walk existing DwindleNode trees and re-evaluate split orientations when monitor settings change.

**Tech Stack:** Swift 6.2, Apple Testing framework (`@Test @MainActor`), SPM

---

## File Map

- **Modify:** `Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift` — thread `monitorId` through 4 methods, add `reorientSplits`
- **Modify:** `Sources/OmniWM/Core/Controller/WMController.swift` — call `reorientSplits` in `updateMonitorDwindleSettings()`
- **Test:** `Tests/OmniWMTests/DwindleLayoutEngineTests.swift` — add 2 tests

---

### Task 1: Add monitorId parameter to aspectOrientation

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift:240-246`

- [ ] **Step 1: Change `aspectOrientation` signature and body**

Replace the method at line 240:

```swift
private func aspectOrientation(for rect: CGRect?, monitorId: Monitor.ID) -> DwindleOrientation {
    guard let rect else { return .horizontal }
    let effectiveMultiplier = effectiveSettings(for: monitorId).splitWidthMultiplier
    if rect.height * effectiveMultiplier > rect.width {
        return .vertical
    }
    return .horizontal
}
```

- [ ] **Step 2: Build to check — will fail because callers don't pass monitorId yet**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | grep "error:"`
Expected: Compiler error at `planSplit` calling `aspectOrientation` without `monitorId`

---

### Task 2: Add monitorId parameter to planSplit

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift:202-238`

- [ ] **Step 1: Change `planSplit` signature and body**

Replace the method at line 202:

```swift
private func planSplit(
    targetRect: CGRect?,
    activeWindowFrame: CGRect?,
    monitorId: Monitor.ID
) -> (orientation: DwindleOrientation, newFirst: Bool) {
    let monitorSettings = effectiveSettings(for: monitorId)
    guard monitorSettings.smartSplit,
          let targetRect,
          let activeFrame = activeWindowFrame
    else {
        return (aspectOrientation(for: targetRect, monitorId: monitorId), false)
    }

    let targetCenter = targetRect.center
    let activeCenter = activeFrame.center

    let deltaX = activeCenter.x - targetCenter.x
    let deltaY = activeCenter.y - targetCenter.y

    let slope: CGFloat
    if abs(deltaX) < 0.001 {
        slope = .infinity
    } else {
        slope = deltaY / deltaX
    }

    let aspect: CGFloat
    if abs(targetRect.width) < 0.001 {
        aspect = .infinity
    } else {
        aspect = targetRect.height / targetRect.width
    }

    if abs(slope) < aspect {
        return (.horizontal, deltaX < 0)
    } else {
        return (.vertical, deltaY < 0)
    }
}
```

- [ ] **Step 2: Build to check — will fail because caller `splitLeaf` doesn't pass monitorId yet**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | grep "error:"`
Expected: Compiler error at `splitLeaf` calling `planSplit` without `monitorId`

---

### Task 3: Add monitorId parameter to splitLeaf

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift:159-200`

- [ ] **Step 1: Change `splitLeaf` signature and body**

Replace the method at line 159:

```swift
private func splitLeaf(
    _ leaf: DwindleNode,
    newWindow: WindowToken,
    workspaceId: WorkspaceDescriptor.ID,
    monitorId: Monitor.ID,
    activeWindowFrame: CGRect?,
    preselectedDirection: Direction? = nil
) -> DwindleNode {
    guard case let .leaf(existingHandle, fullscreen) = leaf.kind else {
        let newLeaf = DwindleNode(kind: .leaf(handle: newWindow, fullscreen: false))
        leaf.appendChild(newLeaf)
        return newLeaf
    }

    let targetRect = leaf.cachedFrame
    let monitorSettings = effectiveSettings(for: monitorId)
    let (orientation, newFirst): (DwindleOrientation, Bool)
    if let dir = preselectedDirection {
        orientation = dir.dwindleOrientation
        newFirst = dir == .left || dir == .up
    } else {
        (orientation, newFirst) = planSplit(
            targetRect: targetRect,
            activeWindowFrame: activeWindowFrame,
            monitorId: monitorId
        )
    }

    let existingLeaf = DwindleNode(kind: .leaf(handle: existingHandle, fullscreen: fullscreen))
    let newLeaf = DwindleNode(kind: .leaf(handle: newWindow, fullscreen: false))

    leaf.kind = .split(orientation: orientation, ratio: monitorSettings.defaultSplitRatio)

    if newFirst {
        leaf.replaceChildren(first: newLeaf, second: existingLeaf)
    } else {
        leaf.replaceChildren(first: existingLeaf, second: newLeaf)
    }

    if let existingHandle {
        tokenToNode[existingHandle] = existingLeaf
    }

    return newLeaf
}
```

- [ ] **Step 2: Build to check — will fail because caller `addWindow` doesn't pass monitorId yet**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | grep "error:"`
Expected: Compiler error at `addWindow` calling `splitLeaf` without `monitorId`

---

### Task 4: Add monitorId parameter to addWindow and update callers

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift:122-157` (addWindow)
- Modify: `Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift:333-385` (syncWindows)
- Modify: `Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift:923-967` (summonWindowRight)

- [ ] **Step 1: Change `addWindow` signature**

Replace the method at line 122:

```swift
@discardableResult
func addWindow(
    token: WindowToken,
    to workspaceId: WorkspaceDescriptor.ID,
    monitorId: Monitor.ID,
    activeWindowFrame: CGRect?
) -> DwindleNode {
    let root = ensureRoot(for: workspaceId)

    if case let .leaf(existingHandle, _) = root.kind, existingHandle == nil {
        root.kind = .leaf(handle: token, fullscreen: false)
        tokenToNode[token] = root
        selectedNodeId[workspaceId] = root.id
        return root
    }

    let targetNode: DwindleNode
    if let selected = selectedNode(in: workspaceId), selected.isLeaf {
        targetNode = selected
    } else {
        targetNode = root.descendToFirstLeaf()
    }

    let preselectedDir = preselection[workspaceId]
    let newLeaf = splitLeaf(
        targetNode,
        newWindow: token,
        workspaceId: workspaceId,
        monitorId: monitorId,
        activeWindowFrame: activeWindowFrame,
        preselectedDirection: preselectedDir
    )
    preselection.removeValue(forKey: workspaceId)

    tokenToNode[token] = newLeaf
    selectedNodeId[workspaceId] = newLeaf.id
    return newLeaf
}
```

- [ ] **Step 2: Add `monitorId` parameter to `syncWindows` and pass it through**

Replace the method at line 333:

```swift
func syncWindows(
    _ tokens: [WindowToken],
    in workspaceId: WorkspaceDescriptor.ID,
    monitorId: Monitor.ID,
    focusedToken: WindowToken?,
    bootstrapScreen: CGRect? = nil
) -> Set<WindowToken> {
    let existingWindows = Set(roots[workspaceId]?.collectAllWindows() ?? [])
    let newWindows = Set(tokens)

    let toRemove = existingWindows.subtracting(newWindows)
    var queuedAdditions: Set<WindowToken> = []
    var toAdd: [WindowToken] = []
    toAdd.reserveCapacity(tokens.count)
    for token in tokens where !existingWindows.contains(token) {
        guard queuedAdditions.insert(token).inserted else { continue }
        toAdd.append(token)
    }

    for token in toRemove {
        removeWindow(token: token, from: workspaceId)
    }

    let shouldBootstrapIncrementally = bootstrapScreen != nil
        && !tokens.isEmpty
        && currentFrames(in: workspaceId).isEmpty
    if shouldBootstrapIncrementally,
       let bootstrapScreen,
       windowCount(in: workspaceId) > 0
    {
        _ = calculateLayout(for: workspaceId, screen: bootstrapScreen)
    }

    var activeFrame: CGRect?
    if let focusedToken, let node = tokenToNode[focusedToken] {
        activeFrame = node.cachedFrame
    }
    if activeFrame == nil {
        activeFrame = selectedNode(in: workspaceId)?.cachedFrame
            ?? roots[workspaceId]?.descendToFirstLeaf().cachedFrame
    }

    for token in toAdd {
        addWindow(token: token, to: workspaceId, monitorId: monitorId, activeWindowFrame: activeFrame)
        if shouldBootstrapIncrementally, let bootstrapScreen {
            let frames = calculateLayout(for: workspaceId, screen: bootstrapScreen)
            activeFrame = frames[token]
        } else if let newNode = tokenToNode[token] {
            activeFrame = newNode.cachedFrame
        }
    }

    return toRemove
}
```

- [ ] **Step 3: Add `monitorId` parameter to `summonWindowRight` and pass it through**

Replace the `addWindow` call inside `summonWindowRight` at line 953:

```swift
let reinsertedLeaf = addWindow(
    token: token,
    to: workspaceId,
    monitorId: monitorId,
    activeWindowFrame: updatedAnchorNode.cachedFrame
)
```

And update the method signature at line 923:

```swift
@discardableResult
func summonWindowRight(
    _ token: WindowToken,
    beside anchorToken: WindowToken,
    in workspaceId: WorkspaceDescriptor.ID,
    monitorId: Monitor.ID
) -> Bool {
```

- [ ] **Step 4: Update test support `syncWindows` overload if it exists**

Check `Tests/OmniWMTests/TokenCompatibilityTestSupport.swift` for a `syncWindows` wrapper and add the `monitorId` parameter.

- [ ] **Step 5: Build to find remaining callers that need updating**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | grep "error:"`
Expected: Errors in `DwindleLayoutHandler.swift` and possibly test files where `syncWindows`/`addWindow`/`summonWindowRight` are called without `monitorId`.

---

### Task 5: Update DwindleLayoutHandler callers

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/DwindleLayoutHandler.swift`

- [ ] **Step 1: Update `buildRelayoutPlan` call to `syncWindows`**

At line 312, add `monitorId: snapshot.monitor.monitorId`:

```swift
_ = engine.syncWindows(
    windowTokens,
    in: snapshot.workspaceId,
    monitorId: snapshot.monitor.monitorId,
    focusedToken: snapshot.preferredFocusToken,
    bootstrapScreen: snapshot.monitor.workingFrame
)
```

- [ ] **Step 2: Find and update all other `syncWindows` and `summonWindowRight` calls in DwindleLayoutHandler**

Search for `engine.syncWindows` and `engine.summonWindowRight` in the file and add the `monitorId` parameter using `snapshot.monitor.monitorId` or equivalent.

- [ ] **Step 3: Build to verify all callers are updated**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | grep "error:"`
Expected: Clean build (or only test file errors remaining)

---

### Task 6: Add reorientSplits method

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift`

- [ ] **Step 1: Add `reorientSplits` and `reorientRecursive` methods**

Add after the `aspectOrientation` method (around line 246):

```swift
func reorientSplits(for workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) {
    guard let root = roots[workspaceId] else { return }
    reorientRecursive(node: root, monitorId: monitorId)
}

private func reorientRecursive(node: DwindleNode, monitorId: Monitor.ID) {
    guard case let .split(_, ratio) = node.kind else { return }
    if let frame = node.cachedFrame {
        let newOrientation = aspectOrientation(for: frame, monitorId: monitorId)
        node.kind = .split(orientation: newOrientation, ratio: ratio)
    }
    for child in node.children {
        reorientRecursive(node: child, monitorId: monitorId)
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | grep "error:"`
Expected: Clean build

---

### Task 7: Call reorientSplits from WMController on settings change

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/WMController.swift:544-551`

- [ ] **Step 1: Update `updateMonitorDwindleSettings` to call reorientSplits**

Replace the method at line 544:

```swift
func updateMonitorDwindleSettings() {
    guard let engine = dwindleEngine else { return }
    for monitor in workspaceManager.monitors {
        let resolved = settings.resolvedDwindleSettings(for: monitor)
        engine.updateMonitorSettings(resolved, for: monitor.id)
        for workspace in workspaceManager.workspaces(on: monitor.id) {
            engine.reorientSplits(for: workspace.id, monitorId: monitor.id)
        }
    }
    layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
}
```

- [ ] **Step 2: Build to verify**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | grep "error:"`
Expected: Clean build

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift \
       Sources/OmniWM/Core/Controller/DwindleLayoutHandler.swift \
       Sources/OmniWM/Core/Controller/WMController.swift
git commit -m "fix: thread monitorId through Dwindle split creation and add reorientSplits

Split orientation now uses per-monitor effectiveSettings instead of
global settings.splitWidthMultiplier. Existing splits re-orient when
monitor Dwindle settings change (hot-reload, sleep/wake).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Fix test compilation and add new tests

**Files:**
- Modify: `Tests/OmniWMTests/DwindleLayoutEngineTests.swift`
- Modify: `Tests/OmniWMTests/TokenCompatibilityTestSupport.swift` (if needed)

- [ ] **Step 1: Fix existing test calls that now need monitorId**

Find all calls to `addWindow`, `syncWindows`, and `summonWindowRight` in test files. Add a default monitor ID. Use the existing `makeLayoutPlanTestMonitor` pattern from the test file.

- [ ] **Step 2: Add test for per-monitor split orientation**

```swift
@Test @MainActor func splitUsesPerMonitorWidthMultiplierForOrientation() async throws {
    let portrait = makeLayoutPlanTestMonitor(
        name: "Portrait",
        frame: CGRect(x: 0, y: 0, width: 1080, height: 1920)
    )
    let controller = makeLayoutPlanTestController(monitors: [portrait])
    guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: portrait.id)?.id
    else {
        Issue.record("Missing active workspace")
        return
    }

    configureWorkspaceAsDwindle(on: controller, workspaceId: workspaceId)
    controller.enableDwindleLayout()
    await waitForLayoutPlanRefreshWork(on: controller)

    // Set high splitWidthMultiplier for portrait monitor → forces vertical (top/bottom) splits
    controller.settings.updateDwindleSettings(
        MonitorDwindleSettings(
            monitorName: portrait.name,
            monitorDisplayId: portrait.displayId,
            splitWidthMultiplier: 10.0
        )
    )

    let token1 = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 901)
    let token2 = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 902)

    let plans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
        activeWorkspaces: [workspaceId]
    )
    guard let plan = plans.first else {
        Issue.record("Expected a Dwindle layout plan")
        return
    }

    let frame1 = frameChange(plan.diff.frameChanges, token: token1)
    let frame2 = frameChange(plan.diff.frameChanges, token: token2)
    guard let f1 = frame1, let f2 = frame2 else {
        Issue.record("Expected frames for both windows")
        return
    }

    // Vertical orientation: windows stacked top/bottom (same width, different Y)
    #expect(abs(f1.width - f2.width) < 1.0, "Windows should have same width in vertical split")
    #expect(f1.origin.y != f2.origin.y, "Windows should be at different Y positions in vertical split")
}
```

- [ ] **Step 3: Add test for reorientSplits on settings change**

```swift
@Test @MainActor func reorientSplitsChangesExistingTreeOrientationOnSettingsUpdate() async throws {
    let portrait = makeLayoutPlanTestMonitor(
        name: "Portrait",
        frame: CGRect(x: 0, y: 0, width: 1080, height: 1920)
    )
    let controller = makeLayoutPlanTestController(monitors: [portrait])
    guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: portrait.id)?.id
    else {
        Issue.record("Missing active workspace")
        return
    }

    configureWorkspaceAsDwindle(on: controller, workspaceId: workspaceId)
    controller.enableDwindleLayout()
    await waitForLayoutPlanRefreshWork(on: controller)

    // Add windows with default splitWidthMultiplier (1.0) — will split horizontally on wide rect
    let _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 901)
    let _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 902)

    let plans1 = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
        activeWorkspaces: [workspaceId]
    )

    // Now change to high splitWidthMultiplier → triggers reorientSplits
    controller.settings.updateDwindleSettings(
        MonitorDwindleSettings(
            monitorName: portrait.name,
            monitorDisplayId: portrait.displayId,
            splitWidthMultiplier: 10.0
        )
    )
    controller.updateMonitorDwindleSettings()

    let plans2 = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
        activeWorkspaces: [workspaceId]
    )

    guard let plan1 = plans1.first, let plan2 = plans2.first else {
        Issue.record("Expected layout plans")
        return
    }

    // After reorientation, frames should differ (orientation changed)
    let frames1 = plan1.diff.frameChanges.map(\.frame)
    let frames2 = plan2.diff.frameChanges.map(\.frame)
    #expect(frames1 != frames2, "Frames should change after reorientSplits")
}
```

- [ ] **Step 4: Run tests**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter DwindleLayoutEngineTests 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Tests/
git commit -m "test: add tests for per-monitor Dwindle split orientation

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```
