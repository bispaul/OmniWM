# Frame Write Architecture Overhaul — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate verificationMismatch retry loops, reduce frame write blast radius, and fill viewport gaps — making Hiro's frame write path match MangoWM/Rift/Paneru best practices.

**Architecture:** Three layered fixes: (1) cooldown timer breaks the verificationMismatch→relayout→retry loop, (2) tiered column visibility with 5px sliver for adjacent columns and no writes for far columns, (3) viewport overspread centers columns when they all fit. Each fix builds on the previous.

**Tech Stack:** Swift, macOS Accessibility API (AXUIElement), Spring animations, CADisplayLink

---

### Task 1: Cooldown Timer for verificationMismatch (Fix 2)

The existing dirty-tracking in `enqueueFrameApplications` already skips writes when `cachedFrame ≈ newFrame`, BUT it bypasses this check when `recentFrameWriteFailures[windowId]` is set. After a verificationMismatch, the next relayout retries the same frame because the failure flag makes it think "this needs retrying." The fix: clear the failure flag after a cooldown instead of keeping it indefinitely.

**Files:**
- Modify: `Sources/OmniWM/Core/Ax/AXManager.swift`
- Test: `Tests/OmniWMTests/AXManagerTests.swift`

- [ ] **Step 1: Write the failing test — cooldown suppresses retry**

Add to `Tests/OmniWMTests/AXManagerTests.swift`:

```swift
@Test @MainActor func verificationMismatchCooldownSuppressesRetryOfSameFrame() {
    let manager = AXManager()
    let pid: pid_t = getpid()
    let windowId = 9901
    let frame = CGRect(x: 100, y: 100, width: 500, height: 400)

    var applyCount = 0
    manager.frameApplyOverrideForTests = { requests in
        applyCount += requests.count
        return requests.map { req in
            AXFrameApplyResult(
                requestId: req.requestId,
                pid: req.pid,
                windowId: req.windowId,
                targetFrame: req.frame,
                currentFrameHint: req.currentFrameHint,
                writeResult: AXFrameWriteResult(
                    targetFrame: req.frame,
                    observedFrame: CGRect(x: 100, y: 100, width: 600, height: 400),
                    writeOrder: .sizeFirst,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: .verificationMismatch
                )
            )
        }
    }

    manager.applyFramesParallel([(pid, windowId, frame)])
    #expect(applyCount == 1)

    // Second attempt with same frame — should be suppressed by cooldown
    applyCount = 0
    manager.applyFramesParallel([(pid, windowId, frame)])
    #expect(applyCount == 0)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter "verificationMismatchCooldownSuppressesRetryOfSameFrame" 2>&1 | tail -10`

Expected: FAIL — `applyCount` is 1 instead of 0 because the `hasRecentFailure` flag bypasses dirty-tracking.

- [ ] **Step 3: Implement cooldown — clear recentFrameWriteFailures after timeout**

In `Sources/OmniWM/Core/Ax/AXManager.swift`, add a cooldown dictionary and modify `enqueueFrameApplications`:

```swift
// Add property near line 57 (after recentFrameWriteFailures):
private var frameWriteFailureCooldownExpiry: [Int: TimeInterval] = [:]
private let verificationMismatchCooldownDuration: TimeInterval = 0.5
```

In `enqueueFrameApplications`, around line 431 where `hasRecentFailure` is checked, add cooldown logic:

```swift
let hasRecentFailure: Bool
if let failureReason = recentFrameWriteFailures[windowId] {
    if failureReason == .verificationMismatch,
       let expiry = frameWriteFailureCooldownExpiry[windowId],
       CACurrentMediaTime() < expiry
    {
        // Within cooldown — treat as if no failure (allow dirty-tracking to skip)
        hasRecentFailure = false
    } else if failureReason == .verificationMismatch,
              let expiry = frameWriteFailureCooldownExpiry[windowId],
              CACurrentMediaTime() >= expiry
    {
        // Cooldown expired — clear the stale failure
        recentFrameWriteFailures.removeValue(forKey: windowId)
        frameWriteFailureCooldownExpiry.removeValue(forKey: windowId)
        hasRecentFailure = false
    } else {
        hasRecentFailure = true
    }
} else {
    hasRecentFailure = false
}
```

In `handleFrameApplyResults`, when setting `recentFrameWriteFailures` (around line 684), also set the cooldown expiry:

```swift
if let failureReason = resolvedResult.writeResult.failureReason {
    WMLog.ax.error("Frame write failed windowId=\(resolvedWindowId, privacy: .public) reason=\(String(describing: failureReason), privacy: .public)")
    recentFrameWriteFailures[resolvedWindowId] = failureReason
    if failureReason == .verificationMismatch {
        frameWriteFailureCooldownExpiry[resolvedWindowId] = CACurrentMediaTime() + verificationMismatchCooldownDuration
    }
}
```

Clean up cooldown entries when window is removed (in `removeWindowState` or wherever `recentFrameWriteFailures` is cleared):

```swift
frameWriteFailureCooldownExpiry.removeValue(forKey: windowId)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter "verificationMismatchCooldownSuppressesRetryOfSameFrame" 2>&1 | tail -10`

Expected: PASS

- [ ] **Step 5: Write test — force-write bypasses cooldown**

```swift
@Test @MainActor func forceApplyBypassesCooldown() {
    let manager = AXManager()
    let pid: pid_t = getpid()
    let windowId = 9902
    let frame = CGRect(x: 100, y: 100, width: 500, height: 400)

    var applyCount = 0
    manager.frameApplyOverrideForTests = { requests in
        applyCount += requests.count
        return requests.map { req in
            AXFrameApplyResult(
                requestId: req.requestId,
                pid: req.pid,
                windowId: req.windowId,
                targetFrame: req.frame,
                currentFrameHint: req.currentFrameHint,
                writeResult: AXFrameWriteResult(
                    targetFrame: req.frame,
                    observedFrame: CGRect(x: 100, y: 100, width: 600, height: 400),
                    writeOrder: .sizeFirst,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: .verificationMismatch
                )
            )
        }
    }

    manager.applyFramesParallel([(pid, windowId, frame)])
    #expect(applyCount == 1)

    // Force-apply should bypass cooldown
    applyCount = 0
    manager.forceApplyNextFrame(for: windowId)
    manager.applyFramesParallel([(pid, windowId, frame)])
    #expect(applyCount == 1)
}
```

- [ ] **Step 6: Run both tests**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter "verificationMismatchCooldown|forceApplyBypassesCooldown" 2>&1 | tail -10`

Expected: PASS

- [ ] **Step 7: Run full test suite**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test 2>&1 | tail -3`

Expected: 1389+ tests pass (1387 existing + 2 new)

- [ ] **Step 8: Build debug and restart**

```bash
cd ~/Documents/Personal/github/OmniWM && swift build -c debug
pkill -x OmniWM; sleep 1; nohup .build/debug/OmniWM > /dev/null 2>&1 &
sleep 3; /usr/bin/log show --predicate 'subsystem == "com.omniwm"' --last 10s --style compact --debug 2>&1 | grep -i "verif\|mismatch" | tail -10
```

Expected: verificationMismatch count significantly reduced — Chrome windows should fail once then be suppressed for 500ms.

- [ ] **Step 9: Commit**

```bash
git add Sources/OmniWM/Core/Ax/AXManager.swift Tests/OmniWMTests/AXManagerTests.swift
git commit -m "fix: add 500ms cooldown after verificationMismatch to break retry loop

After a verificationMismatch, suppress re-attempts of the same frame for 500ms.
The existing dirty-tracking already skips identical frames, but the
recentFrameWriteFailures flag was bypassing it. The cooldown lets the
dirty-tracking do its job while still allowing force-writes and different
frames through.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Tiered Column Visibility — Adjacent with 5px Sliver (Fix 1)

Add a third visibility tier: adjacent columns (first hidden column on each side) get positioned with 5px visible at the screen edge instead of fully off-screen. Far columns (2+ away) get no frame writes at all.

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayout.swift`
- Modify: `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift`
- Test: `Tests/OmniWMTests/NiriLayoutEngineTests.swift`

- [ ] **Step 1: Write failing test — adjacent column gets sliver position**

Add to `Tests/OmniWMTests/NiriLayoutEngineTests.swift`:

```swift
@Test func adjacentColumnGetsSliver5pxPositionInsteadOfFullyOffScreen() {
    let engine = NiriLayoutEngine()
    let workspaceId = UUID()

    let w1 = engine.addWindow(handle: makeTestHandle(), to: workspaceId, afterSelection: nil)
    let w2 = engine.addWindow(handle: makeTestHandle(), to: workspaceId, afterSelection: w1)
    let w3 = engine.addWindow(handle: makeTestHandle(), to: workspaceId, afterSelection: w2)

    let col1 = engine.column(of: w1)!
    let col2 = engine.column(of: w2)!
    let col3 = engine.column(of: w3)!
    col1.width = .fixed(500)
    col1.cachedWidth = 500
    col2.width = .fixed(500)
    col2.cachedWidth = 500
    col3.width = .fixed(500)
    col3.cachedWidth = 500

    let monitor = Monitor(
        id: Monitor.ID(displayId: 1),
        displayId: 1,
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        safeFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        name: "Test"
    )

    var state = ViewportState()
    state.activeColumnIndex = 0
    state.viewOffsetPixels = .static(0)

    let result = engine.calculateCombinedLayoutUsingPools(
        in: workspaceId,
        monitor: monitor,
        gaps: LayoutGaps(horizontal: 8, vertical: 8, outer: .zero),
        state: state,
        workingArea: WorkingAreaContext(
            workingFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            viewFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            scale: 2.0
        ),
        animationTime: nil
    )

    // col3 is far off-screen — should NOT have a frame in the result
    #expect(result.hiddenHandles[w3.token] != nil)

    // col2 is adjacent (first hidden on right) — should have sliver position
    if let col2Frame = result.frames[w2.token] {
        // Adjacent right: x should be viewportMaxX - sliverWidth = 1000 - 5 = 995
        #expect(col2Frame.minX >= 990)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter "adjacentColumnGetsSliver" 2>&1 | tail -10`

Expected: FAIL — currently adjacent columns get the same treatment as far columns (1px edge reveal, not 5px sliver).

- [ ] **Step 3: Add `.adjacent` case to ContainerVisibilityState**

In `Sources/OmniWM/Core/Layout/Niri/NiriLayout.swift`, find the `ContainerVisibilityState` enum (around line 309) and add:

```swift
private enum ContainerVisibilityState {
    case visible
    case adjacent(AxisHideEdge)  // NEW: first hidden column on each side
    case hidden(AxisHideEdge)    // renamed semantically to "far"
}
```

- [ ] **Step 4: Modify `containerVisibilityState()` to detect adjacent columns**

The current method only knows about one column at a time. We need to change the layout loop in `calculateLayoutInto` to track which hidden columns are adjacent.

After the initial visibility classification loop (lines ~218-241), add a second pass:

```swift
// After computing all visibility states, promote first hidden on each side to adjacent
var firstHiddenLeft: Int? = nil
var firstHiddenRight: Int? = nil
let visibleRange = visibilityStates.enumerated().filter { $0.element == .visible }.map(\.offset)
if let firstVisible = visibleRange.first, firstVisible > 0 {
    firstHiddenLeft = firstVisible - 1
}
if let lastVisible = visibleRange.last, lastVisible < containers.count - 1 {
    firstHiddenRight = lastVisible + 1
}
if let leftIdx = firstHiddenLeft, case .hidden(let edge) = visibilityStates[leftIdx] {
    visibilityStates[leftIdx] = .adjacent(edge)
}
if let rightIdx = firstHiddenRight, case .hidden(let edge) = visibilityStates[rightIdx] {
    visibilityStates[rightIdx] = .adjacent(edge)
}
```

- [ ] **Step 5: Modify `hiddenColumnRect()` to use 5px sliver for adjacent**

Add a `sliverWidth` parameter or create a separate method. For adjacent columns:

```swift
private let adjacentSliverWidth: CGFloat = 5.0

// In the layout loop, for .adjacent case:
case let .adjacent(hiddenEdge):
    for window in containerWindowNodes[idx] {
        // Adjacent columns are NOT added to hiddenHandles — they get frame writes with sliver position
    }
    let sliverRect = sliverColumnRect(
        edge: hiddenEdge,
        width: containerSpans[idx],
        height: containerHeight,
        screenY: screenY,
        edgeFrame: edgeFrame
    )
    renderedContainerRect = sliverRect
```

New method:
```swift
private func sliverColumnRect(
    edge: AxisHideEdge,
    width: CGFloat,
    height: CGFloat,
    screenY: CGFloat,
    edgeFrame: CGRect
) -> CGRect {
    let x: CGFloat
    switch edge {
    case .minimum:
        x = edgeFrame.minX - width + adjacentSliverWidth
    case .maximum:
        x = edgeFrame.maxX - adjacentSliverWidth
    }
    return CGRect(origin: CGPoint(x: x, y: screenY), size: CGSize(width: width, height: height))
}
```

- [ ] **Step 6: Handle `.adjacent` in the layout diff path**

In `NiriLayoutHandler.layoutDiff()` (lines ~809-855), adjacent columns should get `frameChanges` entries (not `visibilityChanges.hide`). They are NOT in `hiddenHandles`, so they'll naturally get frame writes. No change needed here — just ensure adjacent windows are NOT added to `hiddenHandles` in step 5.

- [ ] **Step 7: Run the test**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter "adjacentColumnGetsSliver" 2>&1 | tail -10`

Expected: PASS

- [ ] **Step 8: Write test — far column gets no frame write**

```swift
@Test func farColumnProducesNoFrameInLayoutResult() {
    // Same setup as above but with 5 columns — columns 3+ should be far
    let engine = NiriLayoutEngine()
    let workspaceId = UUID()

    var windows: [NiriWindow] = []
    for _ in 0..<5 {
        let w = engine.addWindow(handle: makeTestHandle(), to: workspaceId, afterSelection: windows.last)
        windows.append(w)
        let col = engine.column(of: w)!
        col.width = .fixed(500)
        col.cachedWidth = 500
    }

    let monitor = Monitor(
        id: Monitor.ID(displayId: 1),
        displayId: 1,
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        safeFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        name: "Test"
    )

    var state = ViewportState()
    state.activeColumnIndex = 0
    state.viewOffsetPixels = .static(0)

    let result = engine.calculateCombinedLayoutUsingPools(
        in: workspaceId,
        monitor: monitor,
        gaps: LayoutGaps(horizontal: 8, vertical: 8, outer: .zero),
        state: state,
        workingArea: WorkingAreaContext(
            workingFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            viewFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            scale: 2.0
        ),
        animationTime: nil
    )

    // Columns 0,1 visible, column 2 adjacent, columns 3,4 far
    // Far columns should be in hiddenHandles
    #expect(result.hiddenHandles[windows[3].token] != nil)
    #expect(result.hiddenHandles[windows[4].token] != nil)
    // Adjacent column should NOT be in hiddenHandles (gets sliver frame write)
    #expect(result.hiddenHandles[windows[2].token] == nil)
}
```

- [ ] **Step 9: Run both visibility tests**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter "adjacentColumnGetsSliver|farColumnProducesNoFrame" 2>&1 | tail -10`

Expected: PASS

- [ ] **Step 10: Run full test suite**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test 2>&1 | tail -3`

Expected: All tests pass

- [ ] **Step 11: Build debug and runtime test**

```bash
cd ~/Documents/Personal/github/OmniWM && swift build -c debug
pkill -x OmniWM; sleep 1; nohup .build/debug/OmniWM > /dev/null 2>&1 &
sleep 5; /usr/bin/log show --predicate 'subsystem == "com.omniwm"' --last 10s --style compact --debug 2>&1 | grep -i "verif\|mismatch" | wc -l
```

Expected: Zero or near-zero verificationMismatch entries (Chrome windows now get sliver position, macOS doesn't fight).

- [ ] **Step 12: Commit**

```bash
git add Sources/OmniWM/Core/Layout/Niri/NiriLayout.swift Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift Tests/OmniWMTests/NiriLayoutEngineTests.swift
git commit -m "feat: tiered column visibility — 5px sliver for adjacent, skip far columns

Adjacent columns (first hidden on each side) get positioned with 5px
visible at the screen edge instead of fully off-screen. macOS no longer
fights frame writes with verificationMismatch because the window is
technically still on-screen.

Far columns (2+ away from visible set) skip frame writes entirely,
reducing AX call count per animation tick.

Inspired by Paneru's sliver workaround.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Viewport Overspread (Fix 3)

When all columns fit in the viewport with space left, center the column group by adjusting the viewport offset. No column widths change.

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/ViewportState+ColumnTransitions.swift`
- Modify: `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift`
- Test: `Tests/OmniWMTests/ViewportGeometryTests.swift`

- [ ] **Step 1: Write failing test — overspread centers columns**

Add to `Tests/OmniWMTests/ViewportGeometryTests.swift`:

```swift
@Test func overspreadCentersColumnsWhenTotalWidthLessThanViewport() {
    var state = ViewportState()
    state.activeColumnIndex = 0
    state.viewOffsetPixels = .static(0)

    let containers = makeTestContainers(widths: [300, 300])
    let gap: CGFloat = 8
    let viewportWidth: CGFloat = 1000

    // totalWidth = 300 + 8 + 300 = 608, viewport = 1000, excess = 392
    state.applyOverspread(
        containers: containers,
        gap: gap,
        viewportSpan: viewportWidth,
        sizeKeyPath: \.cachedWidth,
        animate: false
    )

    // Expected offset centers the group: -(excess / 2) = -196
    // But offset is relative to activeColumnIndex position, so:
    // group starts at x=0, centered start = 196
    // viewOffset should position viewport so columns appear centered
    let offset = state.viewOffsetPixels.value()
    let expectedOffset = -(viewportWidth - (300 + gap + 300)) / 2
    #expect(abs(offset - expectedOffset) < 1.0)
}

@Test func overspreadDoesNothingWhenColumnsExceedViewport() {
    var state = ViewportState()
    state.activeColumnIndex = 0
    state.viewOffsetPixels = .static(0)

    let containers = makeTestContainers(widths: [500, 500, 500])
    let gap: CGFloat = 8
    let viewportWidth: CGFloat = 1000

    // totalWidth = 500 + 8 + 500 + 8 + 500 = 1516 > 1000
    state.applyOverspread(
        containers: containers,
        gap: gap,
        viewportSpan: viewportWidth,
        sizeKeyPath: \.cachedWidth,
        animate: false
    )

    // Should not change offset
    #expect(state.viewOffsetPixels.value() == 0)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter "overspread" 2>&1 | tail -10`

Expected: FAIL — `applyOverspread` method doesn't exist yet.

- [ ] **Step 3: Implement `applyOverspread` on ViewportState**

In `Sources/OmniWM/Core/Layout/Niri/ViewportState+ColumnTransitions.swift`, add:

```swift
mutating func applyOverspread(
    containers: [NiriContainer],
    gap: CGFloat,
    viewportSpan: CGFloat,
    sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
    motion: MotionSnapshot = .enabled,
    animate: Bool = true,
    scale: CGFloat = 2.0
) {
    guard !containers.isEmpty else { return }

    let totalWidth = containers.enumerated().reduce(CGFloat(0)) { sum, pair in
        let width = pair.element[keyPath: sizeKeyPath]
        return sum + width + (pair.offset < containers.count - 1 ? gap : 0)
    }

    guard totalWidth < viewportSpan else { return }

    let excessSpace = viewportSpan - totalWidth
    let targetOffset = -(excessSpace / 2)

    let pixelEpsilon: CGFloat = 1.0 / max(scale, 1.0)
    let currentOffset = stationary()
    if abs(targetOffset - currentOffset) <= pixelEpsilon { return }

    if animate {
        animateToOffset(targetOffset, motion: motion, scale: scale)
    } else {
        viewOffsetPixels = .static(targetOffset)
    }
}
```

- [ ] **Step 4: Run overspread tests**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter "overspread" 2>&1 | tail -10`

Expected: PASS

- [ ] **Step 5: Wire overspread into layout operations**

In `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift`, add a helper method:

```swift
private func applyOverspreadIfNeeded(wsId: WorkspaceDescriptor.ID, state: inout ViewportState, engine: NiriLayoutEngine) {
    guard let controller else { return }
    guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return }
    let workingFrame = controller.insetWorkingFrame(for: monitor)
    let gap = CGFloat(controller.workspaceManager.gaps)
    let columns = engine.columns(in: wsId)
    let orientation = engine.monitor(for: monitor.id)?.orientation ?? .horizontal

    switch orientation {
    case .horizontal:
        state.applyOverspread(
            containers: columns,
            gap: gap,
            viewportSpan: workingFrame.width,
            sizeKeyPath: \.cachedWidth,
            motion: controller.motionPolicy.snapshot()
        )
    case .vertical:
        state.applyOverspread(
            containers: columns,
            gap: gap,
            viewportSpan: workingFrame.height,
            sizeKeyPath: \.cachedHeight,
            motion: controller.motionPolicy.snapshot()
        )
    }
}
```

Call `applyOverspreadIfNeeded` inside the `withNiriWorkspaceContext` closure of these methods, after the existing layout operation and before `startScrollAnimationIfNeeded`:

- `toggleColumnFullWidth()`
- `toggleFullscreen()`
- `cycleSize()`
- `cycleWindowWidth()`
- `setColumnWidth()`
- `setWindowWidth()`
- `balanceSizes()`
- `expandColumnToAvailableWidth()`
- `resetWindowHeight()`

Pattern for each:
```swift
// After the engine operation and requestImmediateRelayout:
applyOverspreadIfNeeded(wsId: wsId, state: &state, engine: engine)
startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
```

Also add to `focusNeighbor()` after the `activateNode` call, before `applySessionPatch`:
```swift
if let engine = controller.niriEngine {
    applyOverspreadIfNeeded(wsId: wsId, state: &state, engine: engine)
}
```

- [ ] **Step 6: Run full test suite**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test 2>&1 | tail -3`

Expected: All tests pass

- [ ] **Step 7: Build debug and runtime test**

```bash
cd ~/Documents/Personal/github/OmniWM && swift build -c debug
pkill -x OmniWM; sleep 1; nohup .build/debug/OmniWM > /dev/null 2>&1 &
```

Test: Open 2 narrow columns on 32" (total width < 2560px). Verify no gap on either side — columns centered.

- [ ] **Step 8: Commit**

```bash
git add Sources/OmniWM/Core/Layout/Niri/ViewportState+ColumnTransitions.swift Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift Tests/OmniWMTests/ViewportGeometryTests.swift
git commit -m "feat: viewport overspread — center columns when total width < viewport

When all columns fit in the viewport with space to spare, adjust the
viewport offset to center the column group. No column widths change —
this is a pure viewport display concern.

Inspired by MangoWM's overspread mechanism.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Final Verification

- [ ] **Step 1: Run full test suite**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test 2>&1 | tail -3`

Expected: All tests pass (1387 original + ~6 new)

- [ ] **Step 2: Build and restart**

```bash
cd ~/Documents/Personal/github/OmniWM && swift build -c debug
pkill -x OmniWM; sleep 1; nohup .build/debug/OmniWM > /dev/null 2>&1 &
```

- [ ] **Step 3: Runtime verification checklist**

```bash
# After granting Accessibility, wait 10s then check:
sleep 10
/usr/bin/log show --predicate 'subsystem == "com.omniwm"' --last 10s --style compact --debug 2>&1 | grep "verificationMismatch" | wc -l
```

Manual tests:
1. Chrome on 32" — zero or near-zero verificationMismatch in logs
2. Caps+H/L — smooth navigation, no viewport gap
3. Caps+F — fullscreen toggle doesn't trigger cross-monitor frame storm
4. Caps+E — balance sizes only writes to changed columns
5. 2 columns on wide monitor — centered, no gap on either side
6. Scroll through 5+ columns — smooth transitions, no flash when distant columns come into view

- [ ] **Step 4: Commit version bump**

```bash
# Update Info.plist CFBundleVersion to 68
git add Info.plist
git commit -m "chore: bump build to 68"
```
