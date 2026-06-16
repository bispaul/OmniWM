# Bug #35: Remove Redundant ESV from Viewport Pipeline

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate 4px viewport offset drift on workspace switch by removing the redundant second `ensureContainerVisible` call from `applyViewportPipeline`.

**Architecture:** The viewport pipeline currently runs `anchorPreservation → overspread → ESV → clamp`. The second ESV bakes in anchor preservation's compensatory delta as permanent drift. Removing it leaves `anchorPreservation → overspread → clamp` — all idempotent operations. Every `applyPolicies=true` trigger already has its own ESV upstream.

**Tech Stack:** Swift 6.3, Apple Testing framework, `@Suite @MainActor`

**Spec:** `docs/superpowers/specs/2026-06-16-bug35-remove-redundant-esv-design.md`

---

### Task 1: Write failing test — viewport offset stable across workspace switch with relayout

**Files:**
- Modify: `Tests/OmniWMTests/ViewportPipelineTests.swift`

This test exercises the exact bug: navigate right → workspace switch round-trip → relayout → check offset unchanged. It currently passes because the test framework lacks real focus callbacks, but we need it as a regression guard.

- [ ] **Step 1: Write the test**

Add at the end of the `ViewportPipelineTests` suite (before the closing `}`):

```swift
@Test func viewportOffsetStableAfterWorkspaceSwitchRelayout() async {
    let controller = makeLayoutPlanTestController(
        monitors: [makeLayoutPlanTestMonitor(width: 2560, height: 1440)],
        workspaceConfigurations: [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]
    )
    controller.enableNiriLayout()
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let monitor = controller.workspaceManager.monitors.first,
          let ws1Id = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
          let engine = controller.niriEngine
    else {
        Issue.record("Missing Niri context")
        return
    }

    _ = addLayoutPlanTestWindow(on: controller, workspaceId: ws1Id, windowId: 9901)
    _ = addLayoutPlanTestWindow(on: controller, workspaceId: ws1Id, windowId: 9902)
    _ = addLayoutPlanTestWindow(on: controller, workspaceId: ws1Id, windowId: 9903)

    controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    #expect(engine.columns(in: ws1Id).count == 3)

    controller.niriLayoutHandler.focusNeighbor(direction: .right)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    let navState = controller.workspaceManager.niriViewportState(for: ws1Id)
    let navOffset = navState.viewOffsetPixels.target()
    let navActiveCol = navState.activeColumnIndex
    #expect(navActiveCol > 0, "Navigation should advance activeColumnIndex")

    // Simulate settled spring → static (what happens after DisplayLink ticks)
    var settledState = controller.workspaceManager.niriViewportState(for: ws1Id)
    settledState.viewOffsetPixels = .static(navOffset)
    controller.workspaceManager.updateNiriViewportState(settledState, for: ws1Id)

    // Workspace switch round-trip
    controller.workspaceNavigationHandler.switchWorkspace(index: 1)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.workspaceNavigationHandler.switchWorkspace(index: 0)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    // Extra relayout to trigger resolveSelection ESV
    controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    let postState = controller.workspaceManager.niriViewportState(for: ws1Id)
    let postOffset = postState.viewOffsetPixels.target()

    #expect(
        postState.activeColumnIndex == navActiveCol,
        "activeColumnIndex must survive workspace switch (nav=\(navActiveCol) post=\(postState.activeColumnIndex))"
    )
    #expect(
        abs(postOffset - navOffset) < 2,
        "Viewport offset must not drift after workspace switch (nav=\(navOffset) post=\(postOffset) diff=\(abs(postOffset - navOffset)))"
    )
}
```

- [ ] **Step 2: Run test to verify current behavior**

Run: `swift test --filter "viewportOffsetStableAfterWorkspaceSwitchRelayout"`

Expected: PASS (test framework lacks the anchor-preservation interaction that causes drift on real hardware, so this is a regression guard)

- [ ] **Step 3: Commit**

```bash
git add Tests/OmniWMTests/ViewportPipelineTests.swift
git commit -m "test(#35): add regression test for viewport offset stability across workspace switch"
```

---

### Task 2: Write failing test — left-of-active column removal keeps active column visible

**Files:**
- Modify: `Tests/OmniWMTests/ViewportPipelineTests.swift`

This test covers the edge case where removing a column to the LEFT of the active column creates double compensation (mechanical offset + anchor preservation). After the fix, only clamp + next-pass ESV correct it.

- [ ] **Step 1: Write the test**

Add to `ViewportPipelineTests`:

```swift
@Test func activeColumnVisibleAfterLeftColumnRemoval() async {
    let controller = makeLayoutPlanTestController(
        monitors: [makeLayoutPlanTestMonitor(width: 2560, height: 1440)]
    )
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

    let token1 = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9801)
    _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9802)
    _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9803)

    controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    // Navigate to column 1 (middle)
    controller.niriLayoutHandler.focusNeighbor(direction: .right)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    let preRemoval = controller.workspaceManager.niriViewportState(for: workspaceId)
    #expect(preRemoval.activeColumnIndex == 1, "Should be on column 1 before removal")

    // Remove column 0 (LEFT of active) — triggers double compensation edge case
    engine.removeWindow(token: token1)
    var state = controller.workspaceManager.niriViewportState(for: workspaceId)
    state.requiresViewportRecalc = true
    controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)

    controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    let postRemoval = controller.workspaceManager.niriViewportState(for: workspaceId)
    let columns = engine.columns(in: workspaceId)
    let gap = CGFloat(controller.workspaceManager.gaps)
    let activeCol = postRemoval.activeColumnIndex
    #expect(activeCol < columns.count, "activeColumnIndex must be valid")

    // Verify active column is within viewport bounds
    let viewStart = postRemoval.containerPosition(
        at: activeCol, containers: columns, gap: gap, sizeKeyPath: \.cachedWidth
    ) + postRemoval.stationary()
    let viewEnd = viewStart + monitor.frame.width
    let colStart = postRemoval.containerPosition(
        at: activeCol, containers: columns, gap: gap, sizeKeyPath: \.cachedWidth
    )
    let colEnd = colStart + columns[activeCol].cachedWidth

    #expect(
        colStart >= viewStart - gap && colEnd <= viewEnd + gap,
        "Active column must be visible after left-column removal (colStart=\(colStart) colEnd=\(colEnd) viewStart=\(viewStart) viewEnd=\(viewEnd))"
    )
}
```

- [ ] **Step 2: Run test**

Run: `swift test --filter "activeColumnVisibleAfterLeftColumnRemoval"`

Expected: PASS (clamp + mechanical offset keep column in bounds)

- [ ] **Step 3: Commit**

```bash
git add Tests/OmniWMTests/ViewportPipelineTests.swift
git commit -m "test(#35): add left-of-active column removal viewport visibility test"
```

---

### Task 3: Write test — pipeline convergence (idempotence)

**Files:**
- Modify: `Tests/OmniWMTests/ViewportPipelineTests.swift`

This test verifies that running multiple relayouts produces a stable offset — the pipeline converges.

- [ ] **Step 1: Write the test**

Add to `ViewportPipelineTests`:

```swift
@Test func viewportPipelineConvergesAfterMultipleRelayouts() async {
    let controller = makeLayoutPlanTestController(
        monitors: [makeLayoutPlanTestMonitor(width: 2560, height: 1440)]
    )
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

    _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9601)
    _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9602)
    _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9603)

    controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    controller.niriLayoutHandler.focusNeighbor(direction: .right)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    // Settle spring to static
    var state = controller.workspaceManager.niriViewportState(for: workspaceId)
    state.viewOffsetPixels = .static(state.viewOffsetPixels.target())
    controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)

    // Run 5 relayouts — offset must converge
    var offsets: [Double] = []
    for _ in 0 ..< 5 {
        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        let s = controller.workspaceManager.niriViewportState(for: workspaceId)
        offsets.append(s.viewOffsetPixels.target())
    }

    for i in 1 ..< offsets.count {
        #expect(
            abs(offsets[i] - offsets[i - 1]) < 1,
            "Viewport must converge: pass \(i) offset=\(offsets[i]) vs pass \(i-1) offset=\(offsets[i-1])"
        )
    }
}
```

- [ ] **Step 2: Run test**

Run: `swift test --filter "viewportPipelineConvergesAfterMultipleRelayouts"`

Expected: PASS (with current code, ESV produces same result when called from its own output)

- [ ] **Step 3: Commit**

```bash
git add Tests/OmniWMTests/ViewportPipelineTests.swift
git commit -m "test(#35): add pipeline convergence/idempotence test"
```

---

### Task 4: Remove redundant ESV from applyViewportPipeline

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift:104-133`

This is the actual fix — remove the `ensureContainerVisible` call from the `applyPolicies=true` branch.

- [ ] **Step 1: Remove the redundant ESV block**

In `applyViewportPipeline` (line 56-133), replace the `applyPolicies=true` section. The current code at lines 104-133:

```swift
        let didOverspread = state.applyOverspread(
            containers: columns,
            gap: pass.gap,
            viewportSpan: viewportSpan,
            sizeKeyPath: sizeKeyPath,
            motion: motion,
            animate: false
        )
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

Replace with:

```swift
        let didOverspread = state.applyOverspread(
            containers: columns,
            gap: pass.gap,
            viewportSpan: viewportSpan,
            sizeKeyPath: sizeKeyPath,
            motion: motion,
            animate: false
        )
        if !didOverspread {
            state.clampViewportOffset(
                containers: columns,
                gap: pass.gap,
                viewportSpan: viewportSpan,
                sizeKeyPath: sizeKeyPath
            )
        }
```

- [ ] **Step 2: Build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | tail -3`

Expected: `Build complete!`

- [ ] **Step 3: Run all viewport tests**

Run: `swift test --filter "ViewportPipelineTests|ViewportGeometryTests" 2>&1 | tail -5`

Expected: All tests pass (including the 3 new tests from Tasks 1-3)

- [ ] **Step 4: Run broader test suite**

Run: `swift test --filter "ViewportPipelineTests|ViewportGeometryTests|NiriLayoutEngineTests|AtomicWindowTransferTests" 2>&1 | tail -5`

Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift
git commit -m "fix(#35): remove redundant ESV from applyViewportPipeline

The second ensureContainerVisible call in the applyPolicies=true branch
ran AFTER applyAnchorPreservation shifted the offset. computeFitOffset's
'already visible' branch baked in the anchor delta as permanent drift
(4px per workspace switch round-trip).

Every applyPolicies=true trigger already has its own ESV upstream:
- viewportNeedsRecalc: resolveSelection line 726
- newWindowToken: handleNewWindowArrival line 803
- requiresRecalc: atomicTransfer or resolveSelection

Pipeline: anchorPreservation → overspread → clamp (all idempotent).
"
```

---

### Task 5: Format, lint, and full verification

**Files:**
- No new files

- [ ] **Step 1: Format check**

Run: `cd ~/Documents/Personal/github/OmniWM && make format-check 2>&1 | tail -3`

Expected: 0 files need formatting. If not, run `make format` first.

- [ ] **Step 2: Lint**

Run: `make lint 2>&1 | tail -5`

Expected: 0 serious violations

- [ ] **Step 3: Full test suite for affected areas**

Run: `swift test --filter "ViewportPipelineTests|ViewportGeometryTests|NiriLayoutEngineTests|AtomicWindowTransferTests|RuntimeRevisionTests" 2>&1 | tail -5`

Expected: All tests pass with specific count

- [ ] **Step 4: Update Graphify**

Run: `graphify update Sources/ --graph Sources/graphify-out/graph.json`

Check: no new coupling regressions with `graphify explain applyViewportPipeline --graph Sources/graphify-out/graph.json`

- [ ] **Step 5: Runtime verification (deploy + test)**

```bash
make build-sign
kill $(pgrep -x OmniWM); sleep 1; .build/debug/OmniWM &
sleep 2; .build/debug/omniwmctl ping
```

Then manually test:
1. Navigate right on 3-column workspace
2. Workspace switch round-trip × 3
3. Compare `offset` in `computeLayoutPlan` logs: `abs(pre - post) < 2`
4. Close window to LEFT of active column — verify no column goes off-screen

- [ ] **Step 6: Commit Graphify update**

```bash
git add Sources/graphify-out/
git commit -m "chore: update Graphify after Bug #35 ESV removal"
```
