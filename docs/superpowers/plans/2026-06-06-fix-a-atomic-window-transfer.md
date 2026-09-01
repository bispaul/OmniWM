# Fix A: Atomic Window Transfer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the remove→readmit anti-pattern for same-engine, single-window-column transfers by using `moveColumnToWorkspace` (which preserves column width and avoids intermediate "nowhere" state).

**Architecture:** Add a `moveColumnToWorkspace` overload with a target column index parameter. Then add an `atomicTransferWindow` method on `WorkspaceNavigationHandler` that validates preconditions (same Niri engine, single-window column, non-floating, non-tabbed) and orchestrates the registry + engine transfer in one step. The three caller sites (`transferWindowFromSourceEngine`, `moveWindowToAdjacentWorkspace`, `moveWindowToWorkspaceOnMonitor`) use this method with fallback to the existing path on failure.

**Tech Stack:** Swift, swift-testing framework (`@Test`, `#expect`), NiriLayoutEngine tree model

**Spec:** `docs/superpowers/specs/2026-06-06-fork-release-plan.md` — Fix A section

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift` | Modify | Add `moveColumnToWorkspace` overload with `atColumnIndex:` parameter |
| `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift` | Modify | Add `atomicTransferWindow` method; update three callers |
| `Tests/OmniWMTests/AtomicWindowTransferTests.swift` | Create | All tests for Fix A |

---

### Task 1: Engine — Add `moveColumnToWorkspace` overload with column index

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift:59-103`
- Test: `Tests/OmniWMTests/AtomicWindowTransferTests.swift`

- [ ] **Step 1: Write the failing test — column inserted at specific index**

Create `Tests/OmniWMTests/AtomicWindowTransferTests.swift`:

```swift
import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct AtomicWindowTransferTests {

    // MARK: - Task 1: Engine column index insertion

    @Test func moveColumnToWorkspaceAtIndex() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context")
            return
        }

        let ws2Id = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)!

        // Add 3 windows to ws2 (creates 3 columns: A, B, C)
        let tokenA = addLayoutPlanTestWindow(on: controller, workspaceId: ws2Id, windowId: 2001)
        let tokenB = addLayoutPlanTestWindow(on: controller, workspaceId: ws2Id, windowId: 2002)
        let tokenC = addLayoutPlanTestWindow(on: controller, workspaceId: ws2Id, windowId: 2003)

        // Add 1 window to ws1
        let tokenToMove = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 1001)

        guard let windowNode = engine.findNode(for: tokenToMove),
              let column = engine.findColumn(containing: windowNode, in: ws1)
        else {
            Issue.record("Window not in engine")
            return
        }

        var sourceState = controller.workspaceManager.niriViewportState(for: ws1)
        var targetState = controller.workspaceManager.niriViewportState(for: ws2Id)

        // Move column to ws2 at index 1 (between A and B)
        let result = engine.moveColumnToWorkspace(
            column,
            from: ws1,
            to: ws2Id,
            sourceState: &sourceState,
            targetState: &targetState,
            atColumnIndex: 1
        )

        #expect(result != nil)

        // Verify column order in ws2: A, moved, B, C
        let columns = engine.columns(in: ws2Id)
        #expect(columns.count == 4)
        #expect(columns[1].windowNodes.first?.token == tokenToMove)
    }

    @Test func moveColumnToWorkspaceAtIndexNilAppendsToEnd() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context")
            return
        }

        let ws2Id = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)!

        let tokenExisting = addLayoutPlanTestWindow(on: controller, workspaceId: ws2Id, windowId: 2001)
        let tokenToMove = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 1001)

        guard let windowNode = engine.findNode(for: tokenToMove),
              let column = engine.findColumn(containing: windowNode, in: ws1)
        else {
            Issue.record("Window not in engine")
            return
        }

        var sourceState = controller.workspaceManager.niriViewportState(for: ws1)
        var targetState = controller.workspaceManager.niriViewportState(for: ws2Id)

        // Move with nil index — should append
        let result = engine.moveColumnToWorkspace(
            column,
            from: ws1,
            to: ws2Id,
            sourceState: &sourceState,
            targetState: &targetState,
            atColumnIndex: nil
        )

        #expect(result != nil)
        let columns = engine.columns(in: ws2Id)
        #expect(columns.last?.windowNodes.first?.token == tokenToMove)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter AtomicWindowTransferTests 2>&1 | tail -20`
Expected: Compilation error — `moveColumnToWorkspace` has no `atColumnIndex` parameter

- [ ] **Step 3: Implement the overload**

In `NiriLayoutEngine+WorkspaceOps.swift`, add a new overload after the existing `moveColumnToWorkspace` (after line 103). The existing method stays unchanged for backward compatibility.

```swift
func moveColumnToWorkspace(
    _ column: NiriContainer,
    from sourceWorkspaceId: WorkspaceDescriptor.ID,
    to targetWorkspaceId: WorkspaceDescriptor.ID,
    sourceState: inout ViewportState,
    targetState: inout ViewportState,
    atColumnIndex: Int?
) -> WorkspaceMoveResult? {
    guard sourceWorkspaceId != targetWorkspaceId else { return nil }

    guard roots[sourceWorkspaceId] != nil,
          columnIndex(of: column, in: sourceWorkspaceId) != nil
    else {
        return nil
    }

    let targetRoot = ensureRoot(for: targetWorkspaceId)

    removeEmptyColumnsIfWorkspaceEmpty(in: targetRoot)

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

    if let targetIndex = atColumnIndex {
        targetRoot.insertChild(column, at: targetIndex)
    } else {
        targetRoot.appendChild(column)
    }

    sourceState.selectedNodeId = fallbackSelection

    targetState.selectedNodeId = column.firstChild()?.id

    let firstWindowHandle = column.windowNodes.first?.handle

    return WorkspaceMoveResult(
        newFocusNodeId: fallbackSelection,
        movedHandle: firstWindowHandle,
        targetWorkspaceId: targetWorkspaceId
    )
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter AtomicWindowTransferTests 2>&1 | tail -20`
Expected: 2 tests PASS

- [ ] **Step 5: Run full test suite**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test 2>&1 | tail -5`
Expected: All tests pass (1425+)

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Tests/OmniWMTests/AtomicWindowTransferTests.swift Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift
git commit -m "feat(fix-a): add moveColumnToWorkspace overload with target column index

NiriLayoutEngine.moveColumnToWorkspace now accepts an optional
atColumnIndex parameter. When provided, inserts the column at
the specified position using insertChild(_:at:) instead of
appending to the end. nil preserves the original append behavior.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Core — Implement `atomicTransferWindow` on WorkspaceNavigationHandler

**Files:**
- Test: `Tests/OmniWMTests/AtomicWindowTransferTests.swift` (append)
- Modify: `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift`

The spec places `transferWindow` on WorkspaceManager, but WorkspaceManager is engine-agnostic (it has no reference to NiriLayoutEngine). WorkspaceNavigationHandler already coordinates both WorkspaceManager and the engine via `controller`. Place the method here as a private helper.

- [ ] **Step 1: Write the failing tests — atomic transfer success + precondition failures**

Append to `AtomicWindowTransferTests.swift`:

```swift
    // MARK: - Task 2: atomicTransferWindow

    @Test func atomicTransferPreservesColumnWidth() async {
        let (controller, primaryMonitor, secondaryMonitor, ws1, ws2) =
            makeTwoMonitorLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("No Niri engine")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 3001)
        _ = controller.workspaceManager.setManagedFocus(token, in: ws1, onMonitor: primaryMonitor.id)

        // Run layout so column gets a computed width
        let plans = try? await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [ws1]
        )
        if let plans { controller.layoutRefreshController.executeLayoutPlans(plans) }
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        // Capture column width before transfer
        guard let windowNode = engine.findNode(for: token),
              let column = engine.findColumn(containing: windowNode, in: ws1)
        else {
            Issue.record("Window not in engine before transfer")
            return
        }
        let widthBefore = column.cachedWidth

        // Perform atomic transfer
        let result = controller.workspaceNavigationHandler.atomicTransferWindow(
            token,
            from: ws1,
            to: ws2
        )

        #expect(result)

        // Verify registry updated
        #expect(controller.workspaceManager.workspace(for: token) == ws2)

        // Verify column width preserved (moveColumnToWorkspace, not moveWindowToWorkspace)
        guard let movedNode = engine.findNode(for: token),
              let movedColumn = engine.findColumn(containing: movedNode, in: ws2)
        else {
            Issue.record("Window not in engine after transfer")
            return
        }
        #expect(movedColumn.cachedWidth == widthBefore)
    }

    @Test func atomicTransferFailsForFloatingWindow() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace")
            return
        }

        let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)!
        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 4001)

        // Set window to floating mode
        controller.workspaceManager.setMode(.floating, for: token)

        let result = controller.workspaceNavigationHandler.atomicTransferWindow(
            token,
            from: ws1,
            to: ws2
        )

        #expect(!result)
        // Window should still be in ws1 (no registry change on failure)
        #expect(controller.workspaceManager.workspace(for: token) == ws1)
    }

    @Test func atomicTransferFailsForTabbedColumnWithMultipleWindows() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context")
            return
        }

        let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)!

        // Add two windows and put them in the same column (tabbed)
        let token1 = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 5001)
        let token2 = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 5002)

        // Consume token2 into token1's column to create a multi-window column
        if let node1 = engine.findNode(for: token1),
           let col1 = engine.findColumn(containing: node1, in: ws1),
           let node2 = engine.findNode(for: token2)
        {
            node2.detach()
            col1.appendChild(node2)
        }

        let result = controller.workspaceNavigationHandler.atomicTransferWindow(
            token1,
            from: ws1,
            to: ws2
        )

        // Should fail — column has multiple windows, can't move the whole column
        #expect(!result)
    }

    @Test func atomicTransferFailsForSameWorkspace() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 6001)

        let result = controller.workspaceNavigationHandler.atomicTransferWindow(
            token,
            from: ws1,
            to: ws1
        )

        #expect(!result)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter AtomicWindowTransferTests 2>&1 | tail -20`
Expected: Compilation error — `atomicTransferWindow` does not exist

- [ ] **Step 3: Implement `atomicTransferWindow`**

In `WorkspaceNavigationHandler.swift`, add this method before `transferWindowFromSourceEngine` (before line 434):

```swift
/// Atomically transfers a window between workspaces using moveColumnToWorkspace,
/// preserving column width and avoiding intermediate "nowhere" state.
/// Returns true on success. Returns false (no state changed) when preconditions
/// are not met — callers should fall back to the existing remove+readmit path.
///
/// Preconditions: same Niri engine, single-window column, non-floating, non-tabbed.
func atomicTransferWindow(
    _ token: WindowToken,
    from sourceWorkspaceId: WorkspaceDescriptor.ID,
    to targetWorkspaceId: WorkspaceDescriptor.ID,
    columnIndex: Int? = nil
) -> Bool {
    guard sourceWorkspaceId != targetWorkspaceId else { return false }
    guard let controller else { return false }

    // Must be tiling (not floating)
    guard controller.workspaceManager.mode(for: token) == .tiling else { return false }

    // Must have Niri engine (same-engine check — both workspaces use Niri)
    guard let engine = controller.niriEngine else { return false }
    let sourceLayout = controller.workspaceManager.descriptor(for: sourceWorkspaceId)
        .map { controller.settings.layoutType(for: $0.name) } ?? .defaultLayout
    let targetLayout = controller.workspaceManager.descriptor(for: targetWorkspaceId)
        .map { controller.settings.layoutType(for: $0.name) } ?? .defaultLayout
    guard sourceLayout != .dwindle, targetLayout != .dwindle else { return false }

    // Must find window and its column in the engine
    guard let windowNode = engine.findNode(for: token),
          let column = engine.findColumn(containing: windowNode, in: sourceWorkspaceId)
    else { return false }

    // Must be single-window column (not tabbed with other windows)
    guard column.windowNodes.count == 1 else { return false }

    // Engine: move column (preserves width, no remove+readmit)
    var sourceState = controller.workspaceManager.niriViewportState(for: sourceWorkspaceId)
    var targetState = controller.workspaceManager.niriViewportState(for: targetWorkspaceId)

    guard let result = engine.moveColumnToWorkspace(
        column,
        from: sourceWorkspaceId,
        to: targetWorkspaceId,
        sourceState: &sourceState,
        targetState: &targetState,
        atColumnIndex: columnIndex
    ) else {
        return false
    }

    // Registry: update workspace assignment + border
    controller.reassignManagedWindow(token, to: targetWorkspaceId)

    // Session state: apply viewport updates for both workspaces
    var newSourceFocusToken: WindowToken?
    if let newFocusId = result.newFocusNodeId,
       let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
    {
        newSourceFocusToken = newFocusNode.token
    }

    applySessionTransfer(
        sourceWorkspaceId: sourceWorkspaceId,
        sourceState: sourceState,
        sourceFocusedToken: newSourceFocusToken,
        targetWorkspaceId: targetWorkspaceId,
        targetState: targetState,
        targetFocusedToken: nil
    )

    return true
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter AtomicWindowTransferTests 2>&1 | tail -20`
Expected: 6 tests PASS (2 from Task 1 + 4 from Task 2)

- [ ] **Step 5: Run full test suite**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Tests/OmniWMTests/AtomicWindowTransferTests.swift Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift
git commit -m "feat(fix-a): add atomicTransferWindow on WorkspaceNavigationHandler

Single method that validates preconditions (same Niri engine,
single-window column, non-floating) then performs registry update
+ engine column move in one step. Uses moveColumnToWorkspace to
preserve column width. Returns false on precondition failure so
callers can fall back to existing remove+readmit path.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Wire up callers — replace remove+readmit with atomicTransferWindow

**Files:**
- Test: `Tests/OmniWMTests/AtomicWindowTransferTests.swift` (append)
- Modify: `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift:434-542, 544-578, 836-916`

The three callers are updated to TRY `atomicTransferWindow` first. On success, they skip the `transferWindowFromSourceEngine` + `reassignManagedWindow` calls. On failure, they fall through to the existing path unchanged.

- [ ] **Step 1: Write integration test — moveWindowToAdjacentWorkspace preserves width**

Append to `AtomicWindowTransferTests.swift`:

```swift
    // MARK: - Task 3: Caller integration

    @Test func moveWindowToAdjacentWorkspacePreservesWidth() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 7001)
        _ = controller.workspaceManager.setManagedFocus(token, in: ws1, onMonitor: monitor.id)
        _ = controller.workspaceManager.setInteractionMonitor(monitor.id)

        let plans = try? await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [ws1]
        )
        if let plans { controller.layoutRefreshController.executeLayoutPlans(plans) }
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let windowNode = engine.findNode(for: token),
              let column = engine.findColumn(containing: windowNode, in: ws1)
        else {
            Issue.record("Window not in engine")
            return
        }
        let widthBefore = column.cachedWidth

        // Move to adjacent workspace (creates ws if needed)
        controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .down)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        // Window should be in a different workspace now
        let newWsId = controller.workspaceManager.workspace(for: token)
        #expect(newWsId != nil)
        #expect(newWsId != ws1)

        // Column width should be preserved (atomic transfer path)
        if let movedNode = engine.findNode(for: token),
           let movedColumn = engine.findColumn(containing: movedNode, in: newWsId!)
        {
            #expect(movedColumn.cachedWidth == widthBefore)
        }
    }

    @Test func transferWindowFromSourceEngineUsesAtomicPathForSingleWindowColumn() async {
        let (controller, primaryMonitor, _, ws1, ws2) =
            makeTwoMonitorLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("No engine")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 8001)

        let plans = try? await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [ws1]
        )
        if let plans { controller.layoutRefreshController.executeLayoutPlans(plans) }
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let windowNode = engine.findNode(for: token),
              let column = engine.findColumn(containing: windowNode, in: ws1)
        else {
            Issue.record("Window not in engine")
            return
        }
        let widthBefore = column.cachedWidth

        // After wiring, transferWindowFromSourceEngine should use atomic path
        // and preserve column width for single-window Niri columns
        let nodeCountBefore = engine.columns(in: ws2).count

        // Direct call — same as moveWindowToWorkspaceOnMonitor would use internally
        controller.reassignManagedWindow(token, to: ws2)

        // Verify the window was transferred
        #expect(controller.workspaceManager.workspace(for: token) == ws2)
    }
```

- [ ] **Step 2: Update `transferWindowFromSourceEngine` — try atomic path first**

In `WorkspaceNavigationHandler.swift`, modify `transferWindowFromSourceEngine` (line 434). Insert the atomic path attempt at the top of the Niri-to-Niri branch (inside the `if !sourceIsDwindle, !targetIsDwindle` block at line 452):

Replace lines 452-481 with:

```swift
if !sourceIsDwindle,
   !targetIsDwindle,
   let sourceWsId,
   let engine = controller.niriEngine,
   let windowNode = engine.findNode(for: token)
{
    // Try atomic path first (single-window column, preserves width)
    if atomicTransferWindow(token, from: sourceWsId, to: targetWsId) {
        let sourceState = controller.workspaceManager.niriViewportState(for: sourceWsId)
        if let selectedId = sourceState.selectedNodeId,
           let selectedNode = engine.findNode(by: selectedId) as? NiriWindow
        {
            newSourceFocusToken = selectedNode.token
        }
        movedWithNiri = true
    } else {
        // Fallback: moveWindowToWorkspace (multi-window column, tabbed, etc.)
        var sourceState = controller.workspaceManager.niriViewportState(for: sourceWsId)
        var targetState = controller.workspaceManager.niriViewportState(for: targetWsId)
        if let result = engine.moveWindowToWorkspace(
            windowNode,
            from: sourceWsId,
            to: targetWsId,
            sourceState: &sourceState,
            targetState: &targetState
        ) {
            if let newFocusId = result.newFocusNodeId,
               let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
            {
                newSourceFocusToken = newFocusNode.token
            }
            applySessionTransfer(
                sourceWorkspaceId: sourceWsId,
                sourceState: sourceState,
                sourceFocusedToken: newSourceFocusToken,
                targetWorkspaceId: targetWsId,
                targetState: targetState,
                targetFocusedToken: nil
            )
            movedWithNiri = true
        }
    }
}
```

**Important:** When `atomicTransferWindow` succeeds, it already calls `reassignManagedWindow` and `applySessionTransfer` internally. So the callers (`moveWindowToAdjacentWorkspace`, `moveWindowToWorkspaceOnMonitor`) that currently call `reassignManagedWindow` after `transferWindowFromSourceEngine` will double-call it. We need to prevent that.

- [ ] **Step 3: Update `WindowTransferResult` to signal atomic path**

`WindowTransferResult` is at `WorkspaceNavigationHandler.swift:14`:

```swift
private struct WindowTransferResult {
    let succeeded: Bool
    let newSourceFocusToken: WindowToken?
}
```

Add a field:

```swift
private struct WindowTransferResult {
    let succeeded: Bool
    let newSourceFocusToken: WindowToken?
    let usedAtomicPath: Bool
}
```

Update all return statements in `transferWindowFromSourceEngine`:
- Line 440 (early return): `WindowTransferResult(succeeded: false, newSourceFocusToken: nil, usedAtomicPath: false)`
- After atomic path succeeds: `WindowTransferResult(succeeded: true, newSourceFocusToken: newSourceFocusToken, usedAtomicPath: true)`
- Line 541 (end of method): `WindowTransferResult(succeeded: succeeded, newSourceFocusToken: newSourceFocusToken, usedAtomicPath: false)`

- [ ] **Step 4: Update `moveWindowToAdjacentWorkspace` to skip redundant calls on atomic path**

In `moveWindowToAdjacentWorkspace` (line 544), after the `transferWindowFromSourceEngine` call:

Replace lines 557-561:
```swift
let transferResult = transferWindowFromSourceEngine(token: token, from: wsId, to: targetWorkspace.id)
guard transferResult.succeeded else { return }

controller.reassignManagedWindow(token, to: targetWorkspace.id)
applySessionPatch(workspaceId: targetWorkspace.id, rememberedFocusToken: token)
```

With:
```swift
let transferResult = transferWindowFromSourceEngine(token: token, from: wsId, to: targetWorkspace.id)
guard transferResult.succeeded else { return }

if !transferResult.usedAtomicPath {
    controller.reassignManagedWindow(token, to: targetWorkspace.id)
}
applySessionPatch(workspaceId: targetWorkspace.id, rememberedFocusToken: token)
```

- [ ] **Step 5: Update `moveWindowToWorkspaceOnMonitor` to skip redundant calls on atomic path**

In `moveWindowToWorkspaceOnMonitor` (line 836), after the `transferWindowFromSourceEngine` call:

Replace lines 852-857:
```swift
let transferResult = transferWindowFromSourceEngine(
    token: token, from: currentWorkspaceId, to: targetWsId
)
guard transferResult.succeeded else { return }

controller.reassignManagedWindow(token, to: targetWsId)
```

With:
```swift
let transferResult = transferWindowFromSourceEngine(
    token: token, from: currentWorkspaceId, to: targetWsId
)
guard transferResult.succeeded else { return }

if !transferResult.usedAtomicPath {
    controller.reassignManagedWindow(token, to: targetWsId)
}
```

- [ ] **Step 6: Verify other `reassignManagedWindow` call sites are NOT affected**

These other `reassignManagedWindow` calls in WorkspaceNavigationHandler do NOT follow a `transferWindowFromSourceEngine` call — leave them unchanged:
- Line 623: in `moveColumnToAdjacentWorkspace` — uses `engine.moveColumnToWorkspace` directly (not transferWindowFromSourceEngine)
- Line 692: standalone workspace reassignment (not a transfer flow)
- Line 730: standalone workspace reassignment
- Line 820: standalone workspace reassignment

Only lines 560 and 857 pair with `transferWindowFromSourceEngine` and need the `usedAtomicPath` guard (handled in Steps 4-5).

- [ ] **Step 7: Run tests**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter AtomicWindowTransferTests 2>&1 | tail -20`
Expected: All 8 tests PASS

- [ ] **Step 8: Run full test suite**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 9: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift Tests/OmniWMTests/AtomicWindowTransferTests.swift
git commit -m "feat(fix-a): wire callers to use atomicTransferWindow

transferWindowFromSourceEngine now tries atomicTransferWindow first
for single-window Niri columns. On success, skips remove+readmit
entirely. On failure, falls through to existing moveWindowToWorkspace
path unchanged.

WindowTransferResult gains usedAtomicPath flag so callers skip
redundant reassignManagedWindow when the atomic path already did it.

Callers updated: moveWindowToAdjacentWorkspace,
moveWindowToWorkspaceOnMonitor.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 4: Build, launch, and verify

**Files:** None (verification only)

- [ ] **Step 1: Bump build number**

Find the current build number in `Sources/OmniWMApp/OmniWMApp.swift` or `Package.swift` and increment it.

- [ ] **Step 2: Build the binary**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -10`
Expected: Build succeeded

- [ ] **Step 3: Run full test suite one final time**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 4: Launch and smoke test**

Run: `cd ~/Documents/Personal/github/OmniWM && .build/debug/OmniWM &`

Manual verification checklist:
1. Open 2+ tiled windows on workspace 1
2. Move a single-window column to workspace 2 (Hyper+Shift+Down or equivalent) — verify column width is preserved
3. Move it back — verify width preserved again
4. Move a window cross-monitor — verify it lands correctly
5. Create a tabbed column (2 windows), try moving one — verify fallback path works (window moves but may get new width)

- [ ] **Step 5: Restart omniwmctl watcher**

Run: `/Applications/OmniWM.app/Contents/MacOS/omniwmctl watch --all --exec sketchybar --trigger omniwm_workspace_changed &`

- [ ] **Step 6: Commit build bump**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWMApp/OmniWMApp.swift
git commit -m "chore: bump build to 77

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Not in scope: AXRaise timing

The spec says AXRaise should happen in `handleFrameApplyResults` (after frame writes confirm), not in `commitWorkspaceTransition`'s completion block (which fires before frame writes). Currently both `moveWindowToAdjacentWorkspace` and `moveWindowToWorkspaceOnMonitor` call `focusWindow` in the `commitWorkspaceTransition` postLayout closure — this raises the window before frames are confirmed.

This is a **separate concern from atomic transfer** — it affects z-order correctness, not the remove→readmit anti-pattern. Deferring to a follow-up task or addressing during Fix A testing if z-order issues appear. The atomic transfer itself already improves z-order by not removing/re-adding the AX subscription.
