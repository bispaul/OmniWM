# Column Transfer Pipeline Consolidation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the viewport gap after cross-display column transfer by adding `activeColumnIndex` adjustment and conditional width recalculation to `moveColumnToWorkspace`.

**Architecture:** Extract shared `adjustActiveColumnIndex` helper from `cleanupEmptyColumn`. Add `resetColumnWidth: Bool = true` parameter to both `moveColumnToWorkspace` overloads. Update 3 callers with monitor+settings check. Split existing test.

**Tech Stack:** Swift 6.3, Apple Testing (`@Suite`, `@Test`, `#expect`), `@MainActor`, Niri layout engine

**Spec:** `docs/superpowers/specs/2026-06-12-column-transfer-pipeline-design.md`

---

## File Structure

| File | Changes |
|------|---------|
| `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift` | Extract `adjustActiveColumnIndex` helper, refactor `cleanupEmptyColumn` to use it |
| `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift` | Add `resetColumnWidth` param to both overloads, call helper + `initializeNewColumnWidth` |
| `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift` | Update 3 callers with monitor+settings check |
| `Tests/OmniWMTests/AtomicWindowTransferTests.swift` | Split `atomicTransferPreservesColumnWidth` into same/cross-display |
| `Tests/OmniWMTests/MoveColumnToWorkspaceTests.swift` | New: `activeColumnIndex` adjustment tests + edge cases |

---

### Task 1: Extract `adjustActiveColumnIndex` Helper + Tests

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift:209-232`
- Create: `Tests/OmniWMTests/MoveColumnToWorkspaceTests.swift`

- [ ] **Step 1: Write 4 failing tests for adjustActiveColumnIndex**

Create `Tests/OmniWMTests/MoveColumnToWorkspaceTests.swift`:

```swift
import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct MoveColumnToWorkspaceTests {
    // MARK: - adjustActiveColumnIndex tests

    @Test func adjustActiveColumnIndexShiftsWhenRemovedBeforeActive() {
        var state = ViewportState()
        state.activeColumnIndex = 2
        NiriLayoutEngine.adjustActiveColumnIndex(&state, afterRemovalAt: 1, newColumnCount: 3)
        #expect(state.activeColumnIndex == 1, "Should shift left when column removed before active")
    }

    @Test func adjustActiveColumnIndexUnchangedWhenRemovedAfterActive() {
        var state = ViewportState()
        state.activeColumnIndex = 0
        NiriLayoutEngine.adjustActiveColumnIndex(&state, afterRemovalAt: 2, newColumnCount: 3)
        #expect(state.activeColumnIndex == 0, "Should stay when column removed after active")
    }

    @Test func adjustActiveColumnIndexClampsWhenActiveExceedsCount() {
        var state = ViewportState()
        state.activeColumnIndex = 3
        NiriLayoutEngine.adjustActiveColumnIndex(&state, afterRemovalAt: 3, newColumnCount: 3)
        #expect(state.activeColumnIndex == 2, "Should clamp to newCount - 1")
    }

    @Test func adjustActiveColumnIndexZeroWhenAllColumnsRemoved() {
        var state = ViewportState()
        state.activeColumnIndex = 2
        NiriLayoutEngine.adjustActiveColumnIndex(&state, afterRemovalAt: 0, newColumnCount: 0)
        #expect(state.activeColumnIndex == 0, "Should be 0 when no columns remain")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MoveColumnToWorkspaceTests 2>&1 | tail -10`

Expected: FAIL — `adjustActiveColumnIndex` is not defined

- [ ] **Step 3: Implement the helper and refactor cleanupEmptyColumn**

In `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift`, add the static helper method inside the `extension NiriLayoutEngine` block, BEFORE `cleanupEmptyColumn`:

```swift
static func adjustActiveColumnIndex(
    _ state: inout ViewportState,
    afterRemovalAt removedIndex: Int?,
    newColumnCount: Int
) {
    guard let removedIndex else { return }
    if newColumnCount == 0 {
        state.activeColumnIndex = 0
    } else if removedIndex < state.activeColumnIndex {
        state.activeColumnIndex -= 1
    } else if state.activeColumnIndex >= newColumnCount {
        state.activeColumnIndex = newColumnCount - 1
    }
}
```

Then refactor `cleanupEmptyColumn` to use it. Replace the `if let removedIndex { ... }` block (lines 222-230) with:

```swift
Self.adjustActiveColumnIndex(&state, afterRemovalAt: removedIndex, newColumnCount: columns(in: workspaceId).count)
```

So `cleanupEmptyColumn` becomes:

```swift
func cleanupEmptyColumn(
    _ column: NiriContainer,
    in workspaceId: WorkspaceDescriptor.ID,
    state: inout ViewportState
) {
    guard column.children.isEmpty else { return }

    let removedIndex = columnIndex(of: column, in: workspaceId)

    column.remove()

    Self.adjustActiveColumnIndex(&state, afterRemovalAt: removedIndex, newColumnCount: columns(in: workspaceId).count)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter 'MoveColumnToWorkspaceTests|AtomicWindowTransferTests' 2>&1 | tail -10`

Expected: 4 new tests PASS, existing atomic transfer tests still PASS (cleanupEmptyColumn refactor is behavioral no-op)

- [ ] **Step 5: Format and lint**

Run: `make format-check && make lint`

- [ ] **Step 6: Commit**

```bash
git add Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift Tests/OmniWMTests/MoveColumnToWorkspaceTests.swift
git commit -m "refactor: extract adjustActiveColumnIndex helper from cleanupEmptyColumn

DRY refactor — shared static helper called from cleanupEmptyColumn
(existing) and moveColumnToWorkspace (next commit). Logic identical:
shift left when removed before active, clamp when exceeds count,
zero when all removed. 4 unit tests.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add `resetColumnWidth` to Both `moveColumnToWorkspace` Overloads

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift:58-154`
- Modify: `Tests/OmniWMTests/MoveColumnToWorkspaceTests.swift`

- [ ] **Step 1: Write 3 failing tests**

Add to `MoveColumnToWorkspaceTests.swift`:

```swift
// MARK: - moveColumnToWorkspace engine tests

@Test func moveColumnToWorkspaceAdjustsSourceActiveColumnIndex() async {
    let (controller, _, _, ws1, ws2) = makeTwoMonitorLayoutPlanTestController()
    controller.enableNiriLayout()
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let engine = controller.niriEngine else {
        Issue.record("No Niri engine")
        return
    }

    // Add 3 windows to ws1 (3 columns)
    let t1 = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 7001)
    let t2 = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 7002)
    _ = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 7003)
    _ = controller.workspaceManager.setManagedFocus(t1, in: ws1, onMonitor: controller.workspaceManager.monitors.first!.id)

    var sourceState = controller.workspaceManager.niriViewportState(for: ws1)
    var targetState = controller.workspaceManager.niriViewportState(for: ws2)
    sourceState.activeColumnIndex = 2

    // Find column containing t2 (middle column)
    guard let node2 = engine.findNode(for: t2),
          let column2 = engine.findColumn(containing: node2, in: ws1)
    else {
        Issue.record("Column not found")
        return
    }

    _ = engine.moveColumnToWorkspace(
        column2, from: ws1, to: ws2,
        sourceState: &sourceState, targetState: &targetState,
        resetColumnWidth: false
    )

    // Column at index 1 removed, active was 2 → should shift to 1
    #expect(sourceState.activeColumnIndex == 1, "activeColumnIndex should shift after removal before active")
}

@Test func moveColumnToWorkspaceResetsWidthWhenRequested() async {
    let (controller, _, _, ws1, ws2) = makeTwoMonitorLayoutPlanTestController()
    controller.enableNiriLayout()
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let engine = controller.niriEngine else {
        Issue.record("No Niri engine")
        return
    }

    let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 7010)
    engine.syncWindows([token], in: ws1, selectedNodeId: nil)

    guard let node = engine.findNode(for: token),
          let column = engine.findColumn(containing: node, in: ws1)
    else {
        Issue.record("Column not found")
        return
    }

    column.cachedWidth = 500 // simulate a specific width
    let widthBefore = column.cachedWidth

    var sourceState = controller.workspaceManager.niriViewportState(for: ws1)
    var targetState = controller.workspaceManager.niriViewportState(for: ws2)

    _ = engine.moveColumnToWorkspace(
        column, from: ws1, to: ws2,
        sourceState: &sourceState, targetState: &targetState,
        resetColumnWidth: true
    )

    // Width should be reset (cachedWidth = 0, proportion recalculated)
    #expect(column.cachedWidth == 0, "cachedWidth should be reset to 0 when resetColumnWidth=true")
    #expect(column.isFullWidth == false, "isFullWidth should be reset")
    #expect(widthBefore != 0, "Width before should have been non-zero")
}

@Test func moveColumnToWorkspacePreservesWidthWhenNotRequested() async {
    let (controller, _, _, ws1, ws2) = makeTwoMonitorLayoutPlanTestController()
    controller.enableNiriLayout()
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let engine = controller.niriEngine else {
        Issue.record("No Niri engine")
        return
    }

    let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 7020)
    engine.syncWindows([token], in: ws1, selectedNodeId: nil)

    guard let node = engine.findNode(for: token),
          let column = engine.findColumn(containing: node, in: ws1)
    else {
        Issue.record("Column not found")
        return
    }

    column.cachedWidth = 500
    column.isFullWidth = true

    var sourceState = controller.workspaceManager.niriViewportState(for: ws1)
    var targetState = controller.workspaceManager.niriViewportState(for: ws2)

    _ = engine.moveColumnToWorkspace(
        column, from: ws1, to: ws2,
        sourceState: &sourceState, targetState: &targetState,
        resetColumnWidth: false
    )

    #expect(column.cachedWidth == 500, "cachedWidth should be preserved when resetColumnWidth=false")
    #expect(column.isFullWidth == true, "isFullWidth should be preserved")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MoveColumnToWorkspaceTests 2>&1 | tail -10`

Expected: FAIL — `resetColumnWidth` parameter doesn't exist yet

- [ ] **Step 3: Add `resetColumnWidth` to both overloads**

In `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift`:

**Overload 1 (line 58)** — change signature and add logic after `column.detach()`:

```swift
func moveColumnToWorkspace(
    _ column: NiriContainer,
    from sourceWorkspaceId: WorkspaceDescriptor.ID,
    to targetWorkspaceId: WorkspaceDescriptor.ID,
    sourceState: inout ViewportState,
    targetState: inout ViewportState,
    resetColumnWidth: Bool = true
) -> WorkspaceMoveResult? {
```

After `column.detach()` and `targetRoot.appendChild(column)`, before `sourceState.selectedNodeId = fallbackSelection`, add:

```swift
        // Adjust source activeColumnIndex after column removal
        let removedIndex = colIdx  // captured from the fallback selection guard above
        Self.adjustActiveColumnIndex(&sourceState, afterRemovalAt: removedIndex, newColumnCount: columns(in: sourceWorkspaceId).count)

        // Recalculate column width for target display when requested
        if resetColumnWidth {
            initializeNewColumnWidth(column, in: targetWorkspaceId)
        }
```

Note: `colIdx` is already computed in the existing `if let colIdx = columnIndex(of: column, in: sourceWorkspaceId)` block. Capture it as a `let` before `detach()`. The variable needs to be moved outside the `if let` block. Refactor the fallback selection to capture `colIdx` as an optional:

Replace the existing fallback selection block:
```swift
let allCols = columns(in: sourceWorkspaceId)
var fallbackSelection: NodeId?
if let colIdx = columnIndex(of: column, in: sourceWorkspaceId) {
    if colIdx > 0 {
        fallbackSelection = allCols[colIdx - 1].firstChild()?.id
    } else if allCols.count > 1 {
        fallbackSelection = allCols[1].firstChild()?.id
    }
}

column.detach()

targetRoot.appendChild(column)

sourceState.selectedNodeId = fallbackSelection
```

With:
```swift
let allCols = columns(in: sourceWorkspaceId)
let removedIndex = columnIndex(of: column, in: sourceWorkspaceId)
var fallbackSelection: NodeId?
if let colIdx = removedIndex {
    if colIdx > 0 {
        fallbackSelection = allCols[colIdx - 1].firstChild()?.id
    } else if allCols.count > 1 {
        fallbackSelection = allCols[1].firstChild()?.id
    }
}

column.detach()

targetRoot.appendChild(column)

Self.adjustActiveColumnIndex(&sourceState, afterRemovalAt: removedIndex, newColumnCount: columns(in: sourceWorkspaceId).count)

if resetColumnWidth {
    initializeNewColumnWidth(column, in: targetWorkspaceId)
}

sourceState.selectedNodeId = fallbackSelection
```

**Overload 2 (line 104)** — identical changes, but keep the `atColumnIndex` parameter:

```swift
func moveColumnToWorkspace(
    _ column: NiriContainer,
    from sourceWorkspaceId: WorkspaceDescriptor.ID,
    to targetWorkspaceId: WorkspaceDescriptor.ID,
    sourceState: inout ViewportState,
    targetState: inout ViewportState,
    atColumnIndex: Int?,
    resetColumnWidth: Bool = true
) -> WorkspaceMoveResult? {
```

Same refactor: capture `removedIndex` before `detach()`, add `adjustActiveColumnIndex` + `initializeNewColumnWidth` after detach/append.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter 'MoveColumnToWorkspaceTests|AtomicWindowTransferTests' 2>&1 | tail -10`

Expected: 7 new tests PASS. `atomicTransferPreservesColumnWidth` will FAIL (it uses 2-monitor setup where `resetColumnWidth` defaults to `true`). That's expected — Task 3 fixes it.

- [ ] **Step 5: Format and lint**

Run: `make format-check && make lint`

- [ ] **Step 6: Commit**

```bash
git add Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift Tests/OmniWMTests/MoveColumnToWorkspaceTests.swift
git commit -m "feat: add resetColumnWidth + activeColumnIndex to moveColumnToWorkspace

Both overloads now:
1. Always adjust sourceState.activeColumnIndex via shared helper
2. Conditionally call initializeNewColumnWidth when resetColumnWidth=true

Default resetColumnWidth=true (safe — recalculates unless caller opts out).
F7 pattern: explicit policy parameter at engine level.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Update Callers + Fix Existing Test

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift:486,752,821`
- Modify: `Tests/OmniWMTests/AtomicWindowTransferTests.swift:135`

- [ ] **Step 1: Update `atomicTransferWindow` caller (line 486)**

In `WorkspaceNavigationHandler.swift`, find the `engine.moveColumnToWorkspace` call inside `atomicTransferWindow` (around line 486). Add the cross-display check:

Before the `engine.moveColumnToWorkspace` call, add:
```swift
let sourceMonitorId = controller.workspaceManager.monitorId(for: sourceWorkspaceId)
let targetMonitorId = controller.workspaceManager.monitorId(for: targetWorkspaceId)
let needsWidthReset = sourceMonitorId != targetMonitorId
```

Then change the call to pass `resetColumnWidth: needsWidthReset`:
```swift
guard let result = engine.moveColumnToWorkspace(
    column,
    from: sourceWorkspaceId,
    to: targetWorkspaceId,
    sourceState: &sourceState,
    targetState: &targetState,
    atColumnIndex: columnIndex,
    resetColumnWidth: needsWidthReset
) else {
    return false
}
```

- [ ] **Step 2: Update `moveColumnToAdjacentWorkspace` caller (line 752)**

Find the `engine.moveColumnToWorkspace` call inside `moveColumnToAdjacentWorkspace`. Pass `resetColumnWidth: false` (always same monitor):

```swift
guard let result = engine.moveColumnToWorkspace(
    column,
    from: wsId,
    to: targetWorkspace.id,
    sourceState: &sourceState,
    targetState: &targetState,
    resetColumnWidth: false
) else {
    return
}
```

- [ ] **Step 3: Update `moveColumnToWorkspace` hotkey caller (line 821)**

Find the `engine.moveColumnToWorkspace` call inside `moveColumnToWorkspace(rawWorkspaceID:)`. Add cross-display check:

Before the call, add:
```swift
let sourceMonitorId = controller.workspaceManager.monitorId(for: wsId)
let targetMonitorId = controller.workspaceManager.monitorId(for: targetWsId)
let needsWidthReset = sourceMonitorId != targetMonitorId
```

Then pass `resetColumnWidth: needsWidthReset`:
```swift
guard let result = engine.moveColumnToWorkspace(
    column,
    from: wsId,
    to: targetWsId,
    sourceState: &sourceState,
    targetState: &targetState,
    resetColumnWidth: needsWidthReset
) else {
    return
}
```

- [ ] **Step 4: Split existing test**

In `Tests/OmniWMTests/AtomicWindowTransferTests.swift`, replace `atomicTransferPreservesColumnWidth` (line 135) with two tests:

```swift
@Test func atomicTransferPreservesColumnWidthSameDisplay() async {
    // Same-monitor transfer: width preserved (Fix A intent)
    let controller = makeLayoutPlanTestController()
    controller.enableNiriLayout()
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let monitor = controller.workspaceManager.monitors.first,
          let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
          let engine = controller.niriEngine
    else {
        Issue.record("Missing context")
        return
    }

    let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)!

    let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 3001)
    _ = controller.workspaceManager.setManagedFocus(token, in: ws1, onMonitor: monitor.id)
    engine.syncWindows([token], in: ws1, selectedNodeId: nil)

    let plans = try? await controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [ws1])
    if let plans { controller.layoutRefreshController.executeLayoutPlans(plans) }
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    guard let windowNode = engine.findNode(for: token),
          let column = engine.findColumn(containing: windowNode, in: ws1)
    else {
        Issue.record("Window not in engine")
        return
    }
    let widthBefore = column.cachedWidth

    let result = controller.workspaceNavigationHandler.atomicTransferWindow(token, from: ws1, to: ws2)
    #expect(result)

    guard let movedNode = engine.findNode(for: token),
          let movedColumn = engine.findColumn(containing: movedNode, in: ws2)
    else {
        Issue.record("Window not found after transfer")
        return
    }
    #expect(movedColumn.cachedWidth == widthBefore, "Same-display transfer should preserve column width")
}

@Test func atomicTransferResetsColumnWidthCrossDisplay() async {
    // Cross-monitor transfer: width recalculated for target display
    let (controller, primaryMonitor, secondaryMonitor, ws1, ws2) =
        makeTwoMonitorLayoutPlanTestController()
    controller.enableNiriLayout()
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let engine = controller.niriEngine else {
        Issue.record("No Niri engine")
        return
    }

    let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 3002)
    _ = controller.workspaceManager.setManagedFocus(token, in: ws1, onMonitor: primaryMonitor.id)
    engine.syncWindows([token], in: ws1, selectedNodeId: nil)

    let plans = try? await controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [ws1])
    if let plans { controller.layoutRefreshController.executeLayoutPlans(plans) }
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    guard let windowNode = engine.findNode(for: token),
          let column = engine.findColumn(containing: windowNode, in: ws1)
    else {
        Issue.record("Window not in engine")
        return
    }
    let widthBefore = column.cachedWidth
    #expect(widthBefore > 0, "Should have a computed width before transfer")

    let result = controller.workspaceNavigationHandler.atomicTransferWindow(token, from: ws1, to: ws2)
    #expect(result)

    guard let movedNode = engine.findNode(for: token),
          let movedColumn = engine.findColumn(containing: movedNode, in: ws2)
    else {
        Issue.record("Window not found after transfer")
        return
    }
    // Cross-display: width should be reset (cachedWidth=0 means recalculate on next layout pass)
    #expect(movedColumn.cachedWidth == 0, "Cross-display transfer should reset column width")
    #expect(movedColumn.isFullWidth == false, "Cross-display transfer should reset isFullWidth")
}
```

- [ ] **Step 5: Run all tests**

Run: `swift test --filter 'AtomicWindowTransferTests|MoveColumnToWorkspaceTests|ViewportPipelineTests|ViewportGeometryTests' 2>&1 | tail -10`

Expected: ALL tests PASS (new split tests + engine tests + viewport tests)

- [ ] **Step 6: Format and lint**

Run: `make format-check && make lint`

- [ ] **Step 7: Commit**

```bash
git add Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift Tests/OmniWMTests/AtomicWindowTransferTests.swift
git commit -m "fix(Bug #7/27): update callers with cross-display width reset

3 callers of moveColumnToWorkspace updated:
- atomicTransferWindow: resetColumnWidth when source != target monitor
- moveColumnToAdjacentWorkspace: false (always same monitor)
- moveColumnToWorkspace hotkey: resetColumnWidth when different monitor

Split atomicTransferPreservesColumnWidth test into same-display (preserves)
and cross-display (resets). Fixes the viewport gap after cross-display
window transfer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Runtime Verification

**Files:** None (runtime testing only)

- [ ] **Step 1: Build and deploy**

```bash
swift build -c debug
pkill -x OmniWM; sleep 1
.build/debug/OmniWM &>/dev/null &
sleep 2
pgrep -x OmniWM
```

- [ ] **Step 2: Set up test — ensure TextEdit is on WS8**

```bash
TEXTEDIT_ID=$(omniwmctl query windows --fields id,app | python3 -c "import sys,json; d=json.load(sys.stdin); [print(w['id']) for w in d['result']['payload']['windows'] if 'TextEdit' in w['app']['name']]")
omniwmctl window navigate "$TEXTEDIT_ID"
sleep 0.3
# If TextEdit not on ws8, move it there:
omniwmctl command move-to-workspace 8
sleep 0.5
```

- [ ] **Step 3: Capture pre-transfer state + screenshot**

```bash
omniwmctl query windows --workspace 8 --fields app,frame
screencapture -x /tmp/pipeline_pre.png
```

- [ ] **Step 4: Perform cross-display transfer**

```bash
omniwmctl window navigate "$TEXTEDIT_ID"
sleep 0.3
omniwmctl command move-to-workspace 1
sleep 1.5
```

- [ ] **Step 5: Verify no gap — IPC + screenshot**

```bash
omniwmctl query windows --workspace 8 --fields app,frame
screencapture -x /tmp/pipeline_post.png
```

Check: first visible window starts at x <= 4 (no left gap). Two columns fill viewport.

- [ ] **Step 6: Move TextEdit back and verify no gap on return**

```bash
omniwmctl window navigate "$TEXTEDIT_ID"
sleep 0.3
omniwmctl command move-to-workspace 8
sleep 1.5
omniwmctl query windows --workspace 8 --fields app,frame
screencapture -x /tmp/pipeline_return.png
```

Check: no gap on WS8 after TextEdit returns. Width should be recalculated for 32" display.

- [ ] **Step 7: Verify WS1 (Retina) also has no gap**

```bash
omniwmctl query windows --workspace 1 --fields app,frame
```

Check: no middle gap between visible columns on Retina display.

---

### Task 5: Update Persistence + Graphify

**Files:**
- Modify: `CLAUDE.md` (dashboard update)

- [ ] **Step 1: Update Graphify**

```bash
graphify update Sources/
graphify explain adjustActiveColumnIndex --graph Sources/graphify-out/graph.json
```

Verify: new helper is a static method on NiriLayoutEngine, no new god node edges.

- [ ] **Step 2: Update CLAUDE.md dashboard**

Update Bug #7/27 status to FIXED with build 106. Update Fix pipeline. Note viewport clamp + column transfer pipeline as combined fix.

- [ ] **Step 3: Update persistence systems**

Memorygraph: store session final entry.
Serena: update `mem:core` with column transfer pipeline.
Dotfiles: update `project_omniwm_next_session.md` and `project_omniwm_evaluation.md`.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md Sources/graphify-out/
git commit -m "docs: Bug #7/27 FIXED (column transfer pipeline + viewport clamp, build 106)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```
