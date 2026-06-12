# Viewport Clamping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent the viewport from showing empty space past column bounds after column removal (fixes Bug #7/27 gap).

**Architecture:** Add `clampViewportOffset()` to `ViewportState` (reusing `totalSpan()` and the same coordinate bounds as `scrollByPixels`), call it as the final step inside the `if !didOverspread` block in `applyViewportPipeline`. Remove temporary diagnostic logs, keep permanent ones.

**Tech Stack:** Swift 6.3, Apple Testing framework, `@MainActor`, Niri layout engine

**Spec:** `docs/superpowers/specs/2026-06-12-viewport-clamping-design.md`

---

### Task 1: Write Failing Unit Tests for clampViewportOffset

**Files:**
- Modify: `Tests/OmniWMTests/ViewportGeometryTests.swift`

- [ ] **Step 1: Add test helper and 6 failing tests**

Add these tests to `ViewportGeometryTests.swift` at the end of the `@Suite struct ViewportGeometryTests` block:

```swift
// MARK: - Viewport Clamping Tests

@Test func clampViewportOffsetClampsOverscrolledOffset() {
    // 3 columns at 1277px on 2560px viewport, offset past right bound
    var state = ViewportState()
    state.activeColumnIndex = 0
    state.viewOffsetPixels = .static(0) // shows col[0] at x=0, right edge at x=2560 > content end at 3835
    let columns = makeViewportGestureContainers(widths: [1277, 1277, 1277])
    let result = state.clampViewportOffset(
        containers: columns,
        gap: 2,
        viewportSpan: 2560,
        sizeKeyPath: \.cachedWidth
    )
    #expect(result == true, "Should clamp when viewport extends past content")
    let offset = state.stationary()
    // minOffset = 2560 - (1277*3 + 2*2) = 2560 - 3835 = -1275
    // maxOffset = 0
    // current = 0 → clamped to 0 (already at max)
    // Actually offset=0 is valid (at maxOffset). Let's test with overscroll:
    // Reset with overscroll past content
    state.viewOffsetPixels = .static(100) // past maxOffset=0
    let result2 = state.clampViewportOffset(
        containers: columns,
        gap: 2,
        viewportSpan: 2560,
        sizeKeyPath: \.cachedWidth
    )
    #expect(result2 == true)
    #expect(state.stationary() == 0, "Should clamp to maxOffset=0")
}

@Test func clampViewportOffsetClampsUnderscrolledOffset() {
    var state = ViewportState()
    state.activeColumnIndex = 0
    // minOffset = 2560 - 3835 = -1275
    state.viewOffsetPixels = .static(-1500) // past minOffset
    let columns = makeViewportGestureContainers(widths: [1277, 1277, 1277])
    let result = state.clampViewportOffset(
        containers: columns,
        gap: 2,
        viewportSpan: 2560,
        sizeKeyPath: \.cachedWidth
    )
    #expect(result == true)
    let expected: CGFloat = 2560 - (1277 * 3 + 2 * 2) // -1275
    #expect(abs(state.stationary() - expected) < 1, "Should clamp to minOffset")
}

@Test func clampViewportOffsetSkipsWhenColumnsFit() {
    var state = ViewportState()
    state.activeColumnIndex = 0
    state.viewOffsetPixels = .static(0)
    // 2 columns at 1277 → totalW = 1277+2+1277 = 2556 < 2560
    let columns = makeViewportGestureContainers(widths: [1277, 1277])
    let result = state.clampViewportOffset(
        containers: columns,
        gap: 2,
        viewportSpan: 2560,
        sizeKeyPath: \.cachedWidth
    )
    #expect(result == false, "Should skip when columns fit (minOffset >= maxOffset)")
}

@Test func clampViewportOffsetSkipsDuringAnimation() {
    var state = ViewportState()
    state.activeColumnIndex = 0
    state.viewOffsetPixels = .spring(
        SpringAnimation(value: 100, target: 0, velocity: 0, config: .default)
    )
    let columns = makeViewportGestureContainers(widths: [1277, 1277, 1277])
    let result = state.clampViewportOffset(
        containers: columns,
        gap: 2,
        viewportSpan: 2560,
        sizeKeyPath: \.cachedWidth
    )
    #expect(result == false, "Should skip during spring animation")
}

@Test func clampViewportOffsetSkipsEmptyWorkspace() {
    var state = ViewportState()
    state.viewOffsetPixels = .static(100)
    let result = state.clampViewportOffset(
        containers: [],
        gap: 2,
        viewportSpan: 2560,
        sizeKeyPath: \.cachedWidth
    )
    #expect(result == false, "Should skip for empty workspace")
}

@Test func clampViewportOffsetExactFitBoundary() {
    var state = ViewportState()
    state.activeColumnIndex = 0
    state.viewOffsetPixels = .static(0)
    // totalW exactly equals viewportSpan → minOffset=0=maxOffset → skip
    let columns = makeViewportGestureContainers(widths: [1278, 1278])
    let result = state.clampViewportOffset(
        containers: columns,
        gap: 2,
        viewportSpan: 2558, // 1278+2+1278 = 2558
        sizeKeyPath: \.cachedWidth
    )
    #expect(result == false, "Should skip when totalW == viewportSpan exactly")
}

@Test func clampViewportOffsetFloatPrecisionSafety() {
    var state = ViewportState()
    state.activeColumnIndex = 0
    state.viewOffsetPixels = .static(0)
    // totalW just barely exceeds viewportSpan by a tiny float amount
    let columns = makeViewportGestureContainers(widths: [1278.0005, 1278.0005])
    // totalW = 1278.0005 + 2 + 1278.0005 = 2558.001 > 2558
    // minOffset = 2558 - 2558.001 = -0.001, maxOffset = 0
    // Should not crash from ClosedRange
    let result = state.clampViewportOffset(
        containers: columns,
        gap: 2,
        viewportSpan: 2558,
        sizeKeyPath: \.cachedWidth
    )
    // Within pixel epsilon (0.5 on 2x scale), so should skip
    #expect(result == false, "Sub-pixel difference should be within epsilon")
}

@Test func clampViewportOffsetRespectsPixelEpsilon() {
    var state = ViewportState()
    state.activeColumnIndex = 0
    // Offset 0.3px past maxOffset=0 on 2x scale → epsilon=0.5 → skip
    state.viewOffsetPixels = .static(0.3)
    let columns = makeViewportGestureContainers(widths: [1277, 1277, 1277])
    let result = state.clampViewportOffset(
        containers: columns,
        gap: 2,
        viewportSpan: 2560,
        sizeKeyPath: \.cachedWidth,
        scale: 2.0
    )
    #expect(result == false, "0.3px within 0.5px epsilon → no clamp")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ViewportGeometryTests 2>&1 | tail -20`

Expected: FAIL — `clampViewportOffset` is not defined on `ViewportState`

---

### Task 2: Implement clampViewportOffset

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/ViewportState+ColumnTransitions.swift`

- [ ] **Step 1: Add clampViewportOffset method**

Add at the end of the `extension ViewportState` block in `ViewportState+ColumnTransitions.swift`, before the closing `}`:

```swift
@discardableResult
mutating func clampViewportOffset(
    containers: [NiriContainer],
    gap: CGFloat,
    viewportSpan: CGFloat,
    sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
    scale: CGFloat = 2.0
) -> Bool {
    guard !containers.isEmpty else { return false }
    guard !viewOffsetPixels.isAnimating, !viewOffsetPixels.isGesture else { return false }

    let totalW = totalSpan(containers: containers, gap: gap, sizeKeyPath: sizeKeyPath)

    let maxOffset: CGFloat = 0
    let minOffset = viewportSpan - totalW
    guard minOffset < maxOffset else { return false }

    let current = stationary()
    let safeMin = min(minOffset, maxOffset)
    let safeMax = max(minOffset, maxOffset)
    let clamped = current.clamped(to: safeMin...safeMax)
    let pixelEpsilon: CGFloat = 1.0 / max(scale, 1.0)
    guard abs(clamped - current) > pixelEpsilon else { return false }

    viewOffsetPixels = .static(clamped)
    return true
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `swift test --filter ViewportGeometryTests 2>&1 | tail -20`

Expected: All 8 new tests PASS (plus existing tests)

- [ ] **Step 3: Run format and lint**

Run: `cd /Users/biswadip.paul/Documents/Personal/github/OmniWM && make format-check && make lint`

Expected: 0 files need formatting, 0 serious violations

- [ ] **Step 4: Commit**

```bash
git add Sources/OmniWM/Core/Layout/Niri/ViewportState+ColumnTransitions.swift Tests/OmniWMTests/ViewportGeometryTests.swift
git commit -m "feat(viewport): add clampViewportOffset to prevent over-scroll

Reuses totalSpan() helper and scrollByPixels coordinate bounds pattern.
Guards: !isAnimating, !isGesture, !isEmpty. Float-safe range with
min/max. Pixel epsilon tolerance. 8 unit tests.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Integrate Clamp into applyViewportPipeline

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift:56-120`

- [ ] **Step 1: Write failing integration test**

Add to `Tests/OmniWMTests/ViewportPipelineTests.swift`:

```swift
@Test func viewportClampPreventsGapAfterColumnRemoval() async {
    let controller = makeLayoutPlanTestController()
    controller.enableNiriLayout()
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let monitor = controller.workspaceManager.monitors.first,
          let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
          let engine = controller.niriEngine
    else {
        Issue.record("Missing Niri context")
        return
    }

    // Add 3 windows to create 3 columns
    let token1 = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9001)
    let token2 = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9002)
    _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9003)
    _ = controller.workspaceManager.setManagedFocus(token1, in: workspaceId, onMonitor: monitor.id)

    controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    // Remove middle window — simulates transfer
    engine.removeWindow(token: token2)
    var state = controller.workspaceManager.niriViewportState(for: workspaceId)
    state.requiresViewportRecalc = true
    controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)

    controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    let postState = controller.workspaceManager.niriViewportState(for: workspaceId)
    let columns = engine.columns(in: workspaceId)
    let totalW = postState.totalSpan(containers: columns, gap: 2, sizeKeyPath: \.cachedWidth)
    let viewportSpan = monitor.frame.width

    if totalW > viewportSpan {
        // Viewport should not extend past content bounds
        let viewStart = postState.viewPosPixels(columns: columns, gap: 2)
        let viewEnd = viewStart + viewportSpan
        let contentEnd = totalW
        #expect(viewEnd <= contentEnd + 2, "Viewport should not extend past content bounds (gap=\(viewEnd - contentEnd)px)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ViewportPipelineTests 2>&1 | tail -20`

Expected: FAIL — viewport extends past content bounds (the gap)

- [ ] **Step 3: Add clamp call to applyViewportPipeline**

In `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift`, inside the `if !didOverspread` block of `applyViewportPipeline`, add the clamp after `ensureContainerVisible`:

Replace this block (around lines 103-117):
```swift
        if !didOverspread {
            let settings = engine.effectiveSettings(for: pass.monitor.id)
            state.ensureContainerVisible(
                containerIndex: state.activeColumnIndex,
                containers: columns,
                gap: pass.gap,
                viewportSpan: viewportSpan,
                motion: motion,
                sizeKeyPath: sizeKeyPath,
                animate: false,
                centerMode: settings.centerFocusedColumn,
                alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn
            )
        }
```

With:
```swift
        if !didOverspread {
            let settings = engine.effectiveSettings(for: pass.monitor.id)
            state.ensureContainerVisible(
                containerIndex: state.activeColumnIndex,
                containers: columns,
                gap: pass.gap,
                viewportSpan: viewportSpan,
                motion: motion,
                sizeKeyPath: sizeKeyPath,
                animate: false,
                centerMode: settings.centerFocusedColumn,
                alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn
            )
            state.clampViewportOffset(
                containers: columns,
                gap: pass.gap,
                viewportSpan: viewportSpan,
                sizeKeyPath: sizeKeyPath
            )
        }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter 'ViewportPipelineTests|ViewportGeometryTests' 2>&1 | tail -20`

Expected: All tests PASS

- [ ] **Step 5: Run format and lint**

Run: `make format-check && make lint`

Expected: clean

- [ ] **Step 6: Commit**

```bash
git add Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift Tests/OmniWMTests/ViewportPipelineTests.swift
git commit -m "fix(viewport): integrate clamp into applyViewportPipeline

Prevents viewport from showing empty space past column bounds after
column removal. Placed inside if !didOverspread block — only runs when
columns don't fit and applyOverspread couldn't center them.

Fixes Bug #7/27 (column gap after moveToWorkspace cross-display transfer).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Clean Up Diagnostic Logs

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift`
- Modify: `Sources/OmniWM/Core/Layout/Niri/ViewportState+ColumnTransitions.swift`

- [ ] **Step 1: Remove temporary diagnostic logs from applyOverspread**

In `ViewportState+ColumnTransitions.swift`, remove the per-column loop and totalWidth log (the 120Hz performance concern):

Remove these lines (around line 248-252):
```swift
        for (i, c) in containers.enumerated() {
            WMLog.layout.debug("applyOverspread: col[\(i, privacy: .public)] cachedWidth=\(c[keyPath: sizeKeyPath], privacy: .public) isFullWidth=\(c.isFullWidth, privacy: .public)")
        }
        WMLog.layout.debug("applyOverspread: totalWidth=\(totalWidth, privacy: .public) viewportSpan=\(viewportSpan, privacy: .public) gap=\(gap, privacy: .public) fits=\(totalWidth <= viewportSpan + gap, privacy: .public)")
```

- [ ] **Step 2: Remove temporary diagnostic log from applyViewportPipeline**

In `NiriLayoutHandler.swift`, remove the SKIPPED log and applyOverspread result log:

Remove (around line 86-87):
```swift
            WMLog.layout.debug("applyViewportPipeline: SKIPPED applyPolicies=false wsColumns=\(columns.count, privacy: .public)")
```

Remove (around line 100):
```swift
        WMLog.layout.debug("applyViewportPipeline: applyOverspread=\(didOverspread, privacy: .public) columns=\(columns.count, privacy: .public) viewportSpan=\(viewportSpan, privacy: .public)")
```

- [ ] **Step 3: Keep permanent diagnostic logs**

Verify these remain (do NOT remove):
- `computeLayoutPlan` log: `WMLog.layout.debug("computeLayoutPlan: wsId=...")`
- `removalHandling` logs: `WMLog.layout.debug("removalHandling: wsId=...")`
- `removalHandling: RUNNING ensureSelectionVisible` log

- [ ] **Step 4: Build and test**

Run: `swift build -c debug && swift test --filter 'ViewportPipelineTests|ViewportGeometryTests|RefreshRoutingTests' 2>&1 | tail -20`

Expected: Build succeeds, all viewport tests pass, 94/95 RefreshRoutingTests pass (1 pre-existing)

- [ ] **Step 5: Format and lint**

Run: `make format-check && make lint`

- [ ] **Step 6: Commit**

```bash
git add Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift Sources/OmniWM/Core/Layout/Niri/ViewportState+ColumnTransitions.swift
git commit -m "chore: remove temporary diagnostic logs, keep permanent observability

Remove: applyOverspread per-column loop (120Hz perf), pipeline SKIPPED/result logs.
Keep: computeLayoutPlan applyPolicies log, removalHandling correlation logs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Runtime Verification

**Files:** None (runtime testing only)

- [ ] **Step 1: Build and deploy**

```bash
make build-sign  # or: swift build -c debug
pkill -x OmniWM; sleep 1
.build/debug/OmniWM &>/dev/null &
sleep 2
pgrep -x OmniWM  # verify running
```

- [ ] **Step 2: Set up test — move TextEdit to WS8**

```bash
TEXTEDIT_ID=$(omniwmctl query windows --fields id,app | python3 -c "import sys,json; d=json.load(sys.stdin); [print(w['id']) for w in d['result']['payload']['windows'] if 'TextEdit' in w['app']['name']]")
omniwmctl window navigate "$TEXTEDIT_ID"
sleep 0.3
omniwmctl command move-to-workspace 8
sleep 0.5
```

- [ ] **Step 3: Capture pre-transfer state and screenshot**

```bash
omniwmctl query windows --workspace 8 --fields app,frame
screencapture -x /tmp/pre_clamp_transfer.png
```

- [ ] **Step 4: Perform cross-display transfer**

```bash
omniwmctl window navigate "$TEXTEDIT_ID"
sleep 0.3
omniwmctl command move-to-workspace 1
sleep 1.5
```

- [ ] **Step 5: Capture post-transfer state and screenshot**

```bash
omniwmctl query windows --workspace 8 --fields app,frame
screencapture -x /tmp/post_clamp_transfer.png
```

- [ ] **Step 6: Verify no gap — visual + IPC**

Check screenshot: no wallpaper visible on WS8 display.
Check IPC: remaining columns fill viewport (no gap > column width).

```bash
PID=$(pgrep -x OmniWM)
/usr/bin/log show --predicate "processIdentifier == $PID AND subsystem == 'com.omniwm'" --last 5s --info --debug --style compact | grep -E 'computeLayoutPlan|removalHandling|clampViewport'
```

- [ ] **Step 7: Verify gesture scrolling regression**

Trackpad-scroll on a Niri workspace. Verify: no snap, no jump, smooth scrolling preserved.

- [ ] **Step 8: Restore TextEdit**

```bash
omniwmctl window navigate "$TEXTEDIT_ID"
sleep 0.3
omniwmctl command move-to-workspace 8
```

---

### Task 6: Update Graphify and Persistence

**Files:**
- Modify: `CLAUDE.md` (dashboard update)

- [ ] **Step 1: Update Graphify graph**

```bash
graphify update Sources/
graphify explain clampViewportOffset --graph Sources/graphify-out/graph.json
```

Verify: 0 new god node edges, clampViewportOffset is a ViewportState method.

- [ ] **Step 2: Update CLAUDE.md dashboard**

In `CLAUDE.md`, update Bug #7/27 status to FIXED with build number. Update Fix D L2 status. Update scattered pathways table (note viewport clamping safety net).

- [ ] **Step 3: Update persistence systems**

Update Serena `mem:core` with viewport clamp. Store memorygraph entry for the fix. Update dotfiles `project_omniwm_next_session.md` and `project_omniwm_evaluation.md`.

- [ ] **Step 4: Final commit**

```bash
git add CLAUDE.md Sources/graphify-out/
git commit -m "docs: update dashboard — Bug #7/27 FIXED (viewport clamping, build 105)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```
