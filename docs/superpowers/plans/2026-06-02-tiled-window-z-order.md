# Tiled Window Z-Order Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure tiled windows have deterministic Z-order after every layout refresh — focused window on top, others left-to-right back-to-front.

**Architecture:** Add a Z-ordering step in `LayoutDiffExecutor.execute()` after frame writes complete. Use the existing `WindowFocusOperations.orderWindow` closure (already injectable for tests). No changes to layout engines or AXManager.

**Tech Stack:** Swift 6.2, Apple Testing framework, SkyLight private API (`orderWindow`)

**Spec:** `docs/superpowers/specs/2026-06-02-tiled-window-z-order-design.md`

---

### Task 1: Expose `orderWindow` on WMController for internal use

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/WMController.swift:207` (add internal accessor)

- [ ] **Step 1: Add internal method to WMController**

Add after line 228 (`self.windowFocusOperations = windowFocusOperations`), inside the WMController class body, near the other internal methods:

```swift
func orderWindowAbove(_ windowId: UInt32) {
    windowFocusOperations.orderWindow(windowId)
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/WMController.swift
git commit -m "refactor: expose orderWindowAbove on WMController for internal use

Thin wrapper around WindowFocusOperations.orderWindow, needed by
LayoutDiffExecutor for tiled window Z-ordering (bug #4).

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Write failing test — two tiled windows, focused on top

**Files:**
- Create: `Tests/OmniWMTests/LayoutDiffExecutorZOrderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import OmniWM

@Suite @MainActor struct LayoutDiffExecutorZOrderTests {
    @Test func focusedWindowIsOrderedLastWithTwoTiledWindows() {
        var orderedWindowIds: [UInt32] = []
        let controller = makeLayoutPlanTestController(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in },
                orderWindow: { windowId in
                    orderedWindowIds.append(windowId)
                }
            )
        )

        let wsId = controller.workspaceManager.visibleWorkspaceIds().first!
        let monitor = controller.workspaceManager.monitors().first!

        let w1 = makeLayoutPlanTestWindow(windowId: 100)
        let w2 = makeLayoutPlanTestWindow(windowId: 200)
        let token1 = controller.workspaceManager.addWindow(w1, to: wsId, mode: .tiling)!
        let token2 = controller.workspaceManager.addWindow(w2, to: wsId, mode: .tiling)!

        let diff = WorkspaceLayoutDiff(
            frameChanges: [
                LayoutFrameChange(token: token1, frame: CGRect(x: 0, y: 0, width: 960, height: 1080), forceApply: false),
                LayoutFrameChange(token: token2, frame: CGRect(x: 960, y: 0, width: 960, height: 1080), forceApply: false),
            ],
            focusedFrame: LayoutFocusedFrame(token: token2, frame: CGRect(x: 960, y: 0, width: 960, height: 1080))
        )

        let plan = WorkspaceLayoutPlan(
            workspaceId: wsId,
            monitor: LayoutMonitorSnapshot(monitorId: monitor.id, frame: monitor.frame, visibleFrame: monitor.visibleFrame),
            sessionPatch: .init(workspaceId: wsId, viewportState: controller.workspaceManager.niriViewportState(for: wsId), rememberedFocusToken: nil),
            diff: diff
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        // Focused window (w2, id=200) must be ordered last (= topmost)
        #expect(orderedWindowIds.last == 200)
        // Non-focused (w1, id=100) ordered before focused
        #expect(orderedWindowIds.first == 100)
        #expect(orderedWindowIds.count == 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter LayoutDiffExecutorZOrderTests 2>&1 | tail -10`
Expected: FAIL — `orderedWindowIds` is empty because no Z-ordering calls exist yet.

- [ ] **Step 3: Commit the failing test**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Tests/OmniWMTests/LayoutDiffExecutorZOrderTests.swift
git commit -m "test: add failing test for tiled window Z-order (bug #4)

Verifies focused window is ordered last (topmost) after layout diff
execution. Currently fails — no orderWindow calls for tiled windows.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Implement Z-ordering in LayoutDiffExecutor

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/LayoutRefreshController.swift:3566-3597`

- [ ] **Step 1: Add Z-ordering after frame writes**

In `LayoutDiffExecutor.execute()`, after the `applyFramesParallel(frameUpdates)` block (line 3567) and before the `resizeProbeFrameUpdates` block (line 3570), add:

```swift
        // Z-order tiled windows: left-to-right (back-to-front), focused last (topmost)
        if frameUpdates.count > 1 {
            let focusedToken = diff.focusedFrame?.token
            var tiledOrderEntries: [(windowId: Int, x: CGFloat, isFocused: Bool)] = []

            for change in diff.frameChanges {
                guard !hiddenTokens.contains(change.token),
                      let entry = resolvedEntries[change.token],
                      entry.mode == .tiling
                else { continue }
                let isFocused = change.token == focusedToken
                tiledOrderEntries.append((entry.windowId, change.frame.origin.x, isFocused))
            }

            if tiledOrderEntries.count > 1 {
                tiledOrderEntries.sort { lhs, rhs in
                    if lhs.isFocused != rhs.isFocused { return !lhs.isFocused }
                    return lhs.x < rhs.x
                }

                WMLog.layout.debug("Z-order: ordering \(tiledOrderEntries.count) tiled windows, focused=\(String(describing: focusedToken))")

                for entry in tiledOrderEntries {
                    controller.orderWindowAbove(UInt32(entry.windowId))
                }
            }
        }
```

The sort puts non-focused windows first (sorted by x ascending = left-to-right), then the focused window last. Each `orderWindowAbove` call places the window above all others, so the last call (focused) ends up on top.

- [ ] **Step 2: Run the failing test to verify it passes**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter LayoutDiffExecutorZOrderTests 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 3: Run full test suite to check for regressions**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test 2>&1 | tail -20`
Expected: All tests pass (1385+)

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/LayoutRefreshController.swift
git commit -m "fix: add Z-ordering for tiled windows after layout refresh (bug #4)

After applyFramesParallel writes tiled window frames, order them via
SkyLight.orderWindow: non-focused windows left-to-right (back-to-front),
focused window last (topmost). Prevents non-deterministic stacking
where the last AX frame write would win the top position.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 4: Add test — three tiled windows ordered by x-coordinate

**Files:**
- Modify: `Tests/OmniWMTests/LayoutDiffExecutorZOrderTests.swift`

- [ ] **Step 1: Add three-window test**

Add to the existing `LayoutDiffExecutorZOrderTests` suite:

```swift
    @Test func threeWindowsOrderedByXWithFocusedLast() {
        var orderedWindowIds: [UInt32] = []
        let controller = makeLayoutPlanTestController(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in },
                orderWindow: { windowId in
                    orderedWindowIds.append(windowId)
                }
            )
        )

        let wsId = controller.workspaceManager.visibleWorkspaceIds().first!
        let monitor = controller.workspaceManager.monitors().first!

        let w1 = makeLayoutPlanTestWindow(windowId: 100)
        let w2 = makeLayoutPlanTestWindow(windowId: 200)
        let w3 = makeLayoutPlanTestWindow(windowId: 300)
        let token1 = controller.workspaceManager.addWindow(w1, to: wsId, mode: .tiling)!
        let token2 = controller.workspaceManager.addWindow(w2, to: wsId, mode: .tiling)!
        let token3 = controller.workspaceManager.addWindow(w3, to: wsId, mode: .tiling)!

        // w2 is focused but in the middle (x=640)
        let diff = WorkspaceLayoutDiff(
            frameChanges: [
                LayoutFrameChange(token: token1, frame: CGRect(x: 0, y: 0, width: 640, height: 1080), forceApply: false),
                LayoutFrameChange(token: token2, frame: CGRect(x: 640, y: 0, width: 640, height: 1080), forceApply: false),
                LayoutFrameChange(token: token3, frame: CGRect(x: 1280, y: 0, width: 640, height: 1080), forceApply: false),
            ],
            focusedFrame: LayoutFocusedFrame(token: token2, frame: CGRect(x: 640, y: 0, width: 640, height: 1080))
        )

        let plan = WorkspaceLayoutPlan(
            workspaceId: wsId,
            monitor: LayoutMonitorSnapshot(monitorId: monitor.id, frame: monitor.frame, visibleFrame: monitor.visibleFrame),
            sessionPatch: .init(workspaceId: wsId, viewportState: controller.workspaceManager.niriViewportState(for: wsId), rememberedFocusToken: nil),
            diff: diff
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        // Non-focused ordered by x: w1 (x=0) then w3 (x=1280), focused w2 last
        #expect(orderedWindowIds == [100, 300, 200])
    }
```

- [ ] **Step 2: Run test**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter threeWindowsOrderedByXWithFocusedLast 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Tests/OmniWMTests/LayoutDiffExecutorZOrderTests.swift
git commit -m "test: add three-window Z-order test — x-coordinate ordering

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 5: Add test — single window, no ordering calls

**Files:**
- Modify: `Tests/OmniWMTests/LayoutDiffExecutorZOrderTests.swift`

- [ ] **Step 1: Add single-window test**

```swift
    @Test func singleTiledWindowSkipsZOrdering() {
        var orderedWindowIds: [UInt32] = []
        let controller = makeLayoutPlanTestController(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in },
                orderWindow: { windowId in
                    orderedWindowIds.append(windowId)
                }
            )
        )

        let wsId = controller.workspaceManager.visibleWorkspaceIds().first!
        let monitor = controller.workspaceManager.monitors().first!

        let w1 = makeLayoutPlanTestWindow(windowId: 100)
        let token1 = controller.workspaceManager.addWindow(w1, to: wsId, mode: .tiling)!

        let diff = WorkspaceLayoutDiff(
            frameChanges: [
                LayoutFrameChange(token: token1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), forceApply: false),
            ],
            focusedFrame: LayoutFocusedFrame(token: token1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        )

        let plan = WorkspaceLayoutPlan(
            workspaceId: wsId,
            monitor: LayoutMonitorSnapshot(monitorId: monitor.id, frame: monitor.frame, visibleFrame: monitor.visibleFrame),
            sessionPatch: .init(workspaceId: wsId, viewportState: controller.workspaceManager.niriViewportState(for: wsId), rememberedFocusToken: nil),
            diff: diff
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        // Single window — no Z-ordering needed
        #expect(orderedWindowIds.isEmpty)
    }
```

- [ ] **Step 2: Run test**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter singleTiledWindowSkipsZOrdering 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Tests/OmniWMTests/LayoutDiffExecutorZOrderTests.swift
git commit -m "test: single tiled window skips Z-ordering

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 6: Add test — mixed tiled + floating, only tiled get ordered

**Files:**
- Modify: `Tests/OmniWMTests/LayoutDiffExecutorZOrderTests.swift`

- [ ] **Step 1: Add mixed-mode test**

```swift
    @Test func mixedTiledAndFloatingOnlyOrdersTiled() {
        var orderedWindowIds: [UInt32] = []
        let controller = makeLayoutPlanTestController(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in },
                orderWindow: { windowId in
                    orderedWindowIds.append(windowId)
                }
            )
        )

        let wsId = controller.workspaceManager.visibleWorkspaceIds().first!
        let monitor = controller.workspaceManager.monitors().first!

        let w1 = makeLayoutPlanTestWindow(windowId: 100)
        let w2 = makeLayoutPlanTestWindow(windowId: 200)
        let w3 = makeLayoutPlanTestWindow(windowId: 300)
        let token1 = controller.workspaceManager.addWindow(w1, to: wsId, mode: .tiling)!
        let token2 = controller.workspaceManager.addWindow(w2, to: wsId, mode: .floating)!
        let token3 = controller.workspaceManager.addWindow(w3, to: wsId, mode: .tiling)!

        let diff = WorkspaceLayoutDiff(
            frameChanges: [
                LayoutFrameChange(token: token1, frame: CGRect(x: 0, y: 0, width: 960, height: 1080), forceApply: false),
                LayoutFrameChange(token: token2, frame: CGRect(x: 200, y: 200, width: 400, height: 400), forceApply: false),
                LayoutFrameChange(token: token3, frame: CGRect(x: 960, y: 0, width: 960, height: 1080), forceApply: false),
            ],
            focusedFrame: LayoutFocusedFrame(token: token3, frame: CGRect(x: 960, y: 0, width: 960, height: 1080))
        )

        let plan = WorkspaceLayoutPlan(
            workspaceId: wsId,
            monitor: LayoutMonitorSnapshot(monitorId: monitor.id, frame: monitor.frame, visibleFrame: monitor.visibleFrame),
            sessionPatch: .init(workspaceId: wsId, viewportState: controller.workspaceManager.niriViewportState(for: wsId), rememberedFocusToken: nil),
            diff: diff
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        // Only tiled windows (100, 300) should be ordered; floating (200) excluded
        #expect(!orderedWindowIds.contains(200))
        #expect(orderedWindowIds.last == 300) // focused tiled window last
    }
```

- [ ] **Step 2: Run test**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter mixedTiledAndFloatingOnlyOrdersTiled 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Tests/OmniWMTests/LayoutDiffExecutorZOrderTests.swift
git commit -m "test: mixed tiled/floating — only tiled windows get Z-ordered

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 7: Manual verification with debug build

**Files:** None (verification only)

- [ ] **Step 1: Build debug binary**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 2: Swap to new debug build**

```bash
pkill -x OmniWM
~/Documents/Personal/github/OmniWM/.build/debug/OmniWM &disown
sleep 3
```

- [ ] **Step 3: Verify Z-order logs appear after workspace switch**

Press Hyper+1 then Hyper+2 (or switch workspaces), then check:

```bash
command log show --predicate 'subsystem == "com.omniwm"' --last 1m --style compact --debug | grep "Z-order"
```

Expected: `Z-order: ordering N tiled windows, focused=...`

- [ ] **Step 4: Verify Z-order with CGWindowList**

```bash
python3 << 'PYEOF'
import Quartz
windows = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID
)
targets = {'Ghostty', 'WhatsApp', 'Code', 'Google Chrome', 'Treasure Work'}
for i, w in enumerate(windows):
    owner = w.get('kCGWindowOwnerName', '')
    if owner in targets:
        b = w.get('kCGWindowBounds', {})
        print(f"{i:3d} {owner:20s} {w.get('kCGWindowNumber', 0):6d} x={b.get('X',0):7.0f}")
PYEOF
```

Expected: Focused window has lowest Z-index number (= topmost in the list)
