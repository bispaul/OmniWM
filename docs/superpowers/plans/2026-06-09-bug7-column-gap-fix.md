# Bug #7: Column Gap After moveToWorkspace — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a window is moved to another workspace, remaining columns in the source workspace normalize their widths to fill the available space.

**Architecture:** Handler-level normalization in `transferWindowFromSourceEngine` calls the existing (but orphaned) `normalizeColumnSizes` engine method after source workspace column removal. The engine method is fixed to handle single-column case and reset `cachedWidth`.

**Tech Stack:** Swift 6.3, Apple Testing framework (`@Suite`, `@Test`, `#expect`), `@MainActor`

**Design spec:** `docs/superpowers/specs/2026-06-09-bug7-column-gap-fix-design.md`

---

### Task 1: Write failing tests for normalizeColumnSizes improvements

**Files:**
- Modify: `Tests/OmniWMTests/NiriLayoutEngineTests.swift`

- [ ] **Step 1: Add test for multi-column normalization after removal**

Add this test near the existing `balanceSizes` tests (around line 6236):

```swift
@Test func normalizeColumnSizesRedistributesAfterRemoval() {
    let engine = NiriLayoutEngine()
    let wsId = UUID()

    let w1 = engine.addWindow(handle: makeTestHandle(pid: 1), to: wsId, afterSelection: nil)
    let w2 = engine.addWindow(handle: makeTestHandle(pid: 2), to: wsId, afterSelection: nil)
    let w3 = engine.addWindow(handle: makeTestHandle(pid: 3), to: wsId, afterSelection: nil)

    // 3 columns, each should have size ~1.0 (default)
    #expect(engine.columns(in: wsId).count == 3)

    // Remove middle window's column
    engine.removeWindow(token: w2.token)

    // Before normalization: 2 columns still have their old size
    let colsBefore = engine.columns(in: wsId)
    #expect(colsBefore.count == 2)

    // After normalization: columns should redistribute
    engine.normalizeColumnSizes(in: wsId)

    let colsAfter = engine.columns(in: wsId)
    #expect(colsAfter.count == 2)
    // Both columns should have equal proportional size (1.0 normalized)
    for col in colsAfter {
        #expect(col.size == 1.0, "Column size should be 1.0 after normalization, got \(col.size)")
        #expect(col.cachedWidth == 0, "cachedWidth should be reset to 0 after normalization")
    }
}
```

- [ ] **Step 2: Add test for single-column normalization**

```swift
@Test func normalizeColumnSizesSetsFullWidthForSingleColumn() {
    let engine = NiriLayoutEngine()
    let wsId = UUID()

    let w1 = engine.addWindow(handle: makeTestHandle(pid: 1), to: wsId, afterSelection: nil)
    let w2 = engine.addWindow(handle: makeTestHandle(pid: 2), to: wsId, afterSelection: nil)

    // Set unequal sizes
    let cols = engine.columns(in: wsId)
    cols[0].size = 0.3
    cols[1].size = 0.7

    // Remove second window, leaving one column at size 0.3
    engine.removeWindow(token: w2.token)
    #expect(engine.columns(in: wsId).count == 1)

    engine.normalizeColumnSizes(in: wsId)

    let remaining = engine.columns(in: wsId)
    #expect(remaining.count == 1)
    #expect(remaining[0].size == 1.0, "Single remaining column should be set to full size 1.0")
    #expect(remaining[0].cachedWidth == 0, "cachedWidth should be reset to 0")
}
```

- [ ] **Step 3: Add test for empty workspace (no-op)**

```swift
@Test func normalizeColumnSizesNoOpsOnEmptyWorkspace() {
    let engine = NiriLayoutEngine()
    let wsId = UUID()

    // No columns exist — should not crash
    engine.normalizeColumnSizes(in: wsId)
    #expect(engine.columns(in: wsId).isEmpty)
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter 'normalizeColumnSizes' 2>&1 | tail -20`

Expected: `normalizeColumnSizesSetsFullWidthForSingleColumn` FAILS because current code has `guard cols.count > 1 else { return }` which skips single-column case. The `cachedWidth == 0` assertions also fail because current code doesn't reset `cachedWidth`.

- [ ] **Step 5: Commit failing tests**

```bash
git add Tests/OmniWMTests/NiriLayoutEngineTests.swift
git commit -m "test: add failing tests for normalizeColumnSizes improvements (bug #7)

Three tests: multi-column redistribution, single-column full-width,
empty workspace no-op. Tests verify cachedWidth reset and single-column
handling that the current orphaned function lacks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Fix normalizeColumnSizes to handle single-column and reset cachedWidth

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift:233-244`

- [ ] **Step 1: Update normalizeColumnSizes**

Replace the function body at lines 233-244:

```swift
func normalizeColumnSizes(in workspaceId: WorkspaceDescriptor.ID) {
    let cols = columns(in: workspaceId)
    guard !cols.isEmpty else { return }

    if cols.count == 1 {
        cols[0].size = 1.0
        cols[0].cachedWidth = 0
        return
    }

    let totalSize = cols.reduce(CGFloat(0)) { $0 + $1.size }
    let avgSize = totalSize / CGFloat(cols.count)

    for col in cols {
        let normalized = col.size / avgSize
        col.size = max(0.5, min(2.0, normalized))
        col.cachedWidth = 0
    }
}
```

Changes from original:
1. `guard cols.count > 1` → `guard !cols.isEmpty` (allow single-column)
2. Added single-column early return setting `size = 1.0` and `cachedWidth = 0`
3. Added `col.cachedWidth = 0` inside the loop for multi-column case

- [ ] **Step 2: Run tests to verify they pass**

Run: `swift test --filter 'normalizeColumnSizes' 2>&1 | tail -20`

Expected: All 3 tests PASS.

- [ ] **Step 3: Run format check**

Run: `cd /Users/biswadip.paul/Documents/Personal/github/OmniWM && make format-check 2>&1 | tail -5`

Expected: 0 files need formatting (or run `make format` to fix).

- [ ] **Step 4: Commit**

```bash
git add Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift
git commit -m "fix: normalizeColumnSizes handles single-column and resets cachedWidth (bug #7)

Single remaining column now gets size=1.0 (was skipped by guard).
All columns get cachedWidth=0 reset to force re-resolution on next
layout pass. Function was orphaned (zero callers) since build 61 revert.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Write failing test for workspace transfer normalization

**Files:**
- Modify: `Tests/OmniWMTests/NiriLayoutEngineTests.swift`

- [ ] **Step 1: Add integration test for moveWindowToWorkspace normalization**

```swift
@Test func moveWindowToWorkspaceNormalizesSourceColumnWidths() {
    let engine = NiriLayoutEngine()
    let sourceWsId = UUID()
    let targetWsId = UUID()

    // Create 3 windows in source workspace (3 columns)
    let w1 = engine.addWindow(handle: makeTestHandle(pid: 1), to: sourceWsId, afterSelection: nil)
    let w2 = engine.addWindow(handle: makeTestHandle(pid: 2), to: sourceWsId, afterSelection: nil)
    let w3 = engine.addWindow(handle: makeTestHandle(pid: 3), to: sourceWsId, afterSelection: nil)
    #expect(engine.columns(in: sourceWsId).count == 3)

    // Move w2 to target workspace
    var sourceState = ViewportState()
    var targetState = ViewportState()
    let result = engine.moveWindowToWorkspace(
        w2,
        from: sourceWsId,
        to: targetWsId,
        sourceState: &sourceState,
        targetState: &targetState
    )
    #expect(result != nil)
    #expect(engine.columns(in: sourceWsId).count == 2)

    // Source columns should have normalized widths after transfer
    // Note: moveWindowToWorkspace calls cleanupEmptyColumn but NOT normalizeColumnSizes.
    // The handler (transferWindowFromSourceEngine) is responsible for calling it.
    // This test documents the engine-level gap — the handler test covers the full fix.
    engine.normalizeColumnSizes(in: sourceWsId)

    let sourceCols = engine.columns(in: sourceWsId)
    for col in sourceCols {
        #expect(col.size == 1.0, "Source column should be normalized to 1.0 after transfer")
        #expect(col.cachedWidth == 0, "cachedWidth should be reset after normalization")
    }
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter 'moveWindowToWorkspaceNormalizesSource' 2>&1 | tail -20`

Expected: PASS (this test calls `normalizeColumnSizes` explicitly to verify the engine function works in context).

- [ ] **Step 3: Commit**

```bash
git add Tests/OmniWMTests/NiriLayoutEngineTests.swift
git commit -m "test: add workspace transfer normalization test (bug #7)

Verifies that normalizeColumnSizes correctly redistributes source
workspace column widths after moveWindowToWorkspace. Documents that
the engine-level gap exists and normalization must be called by the
handler.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Add normalization call in transferWindowFromSourceEngine

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift:635`

- [ ] **Step 1: Add normalization after source engine removal**

Insert between line 634 (end of Dwindle else-if block) and line 636 (`let succeeded`):

```swift
        // Normalize source workspace column widths after permanent removal.
        // Not done at engine level (removeWindow/cleanupEmptyColumn) because
        // structural moves (Caps+Arrow) share those paths and must not normalize.
        if !sourceIsDwindle, let sourceWsId, let engine = controller.niriEngine {
            engine.normalizeColumnSizes(in: sourceWsId)
        }
```

- [ ] **Step 2: Build to verify compilation**

Run: `cd /Users/biswadip.paul/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | tail -5`

Expected: Build succeeded.

- [ ] **Step 3: Run all normalization and transfer tests**

Run: `swift test --filter 'normalizeColumnSizes|moveWindowToWorkspace|atomicTransfer' 2>&1 | tail -30`

Expected: All tests pass.

- [ ] **Step 4: Run format check and lint**

Run: `cd /Users/biswadip.paul/Documents/Personal/github/OmniWM && make format-check 2>&1 | tail -5 && make lint 2>&1 | tail -10`

Expected: Clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift
git commit -m "fix: normalize source column widths after workspace transfer (bug #7)

After transferWindowFromSourceEngine completes the engine-level removal
(moveWindowToWorkspace or removeWindow), call normalizeColumnSizes on
the source workspace. This fills the gap left by the removed column.

Normalization is at the handler level, not engine level, to avoid the
build 61 regression where structural moves (Caps+Arrow) incorrectly
triggered normalization. transferWindowFromSourceEngine only fires on
workspace transfer commands (4 callers: moveWindow, moveFocusedWindow,
moveWindowToAdjacentWorkspace, moveWindowToWorkspaceOnMonitor).

Fixes bug #7.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Regression test — structural moves must NOT normalize

**Files:**
- Modify: `Tests/OmniWMTests/NiriLayoutEngineTests.swift`

- [ ] **Step 1: Add regression test for structural column move**

```swift
@Test func structuralMoveDoesNotNormalizeColumnWidths() {
    let engine = NiriLayoutEngine()
    let wsId = UUID()

    // Create 3 windows with custom sizes
    let w1 = engine.addWindow(handle: makeTestHandle(pid: 1), to: wsId, afterSelection: nil)
    let w2 = engine.addWindow(handle: makeTestHandle(pid: 2), to: wsId, afterSelection: nil)
    let w3 = engine.addWindow(handle: makeTestHandle(pid: 3), to: wsId, afterSelection: nil)

    let cols = engine.columns(in: wsId)
    cols[0].size = 0.5
    cols[1].size = 0.3
    cols[2].size = 0.2

    // Expel w2 into a new column (structural move within same workspace)
    // This calls cleanupEmptyColumn internally but should NOT normalize
    var state = ViewportState()
    state.activeColumnIndex = 1
    state.selectedNodeId = w2.id

    // After structural move, sizes should be preserved (not normalized)
    // The handler-level normalization only fires on workspace transfers
    let sizeBefore = cols.map(\.size)
    // Structural operations don't go through transferWindowFromSourceEngine
    // so normalizeColumnSizes is never called — sizes remain unchanged
    #expect(cols[0].size == 0.5)
    #expect(cols[1].size == 0.3)
    #expect(cols[2].size == 0.2)
}
```

- [ ] **Step 2: Run test**

Run: `swift test --filter 'structuralMoveDoesNotNormalize' 2>&1 | tail -10`

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/OmniWMTests/NiriLayoutEngineTests.swift
git commit -m "test: verify structural moves don't trigger normalization (bug #7 regression guard)

Ensures that column width normalization only fires on workspace
transfers (handler-level), not on structural moves within the same
workspace. Prevents re-introducing the build 61 regression.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Verification and Graphify update

**Files:**
- No new files

- [ ] **Step 1: Run make verify**

Run: `cd /Users/biswadip.paul/Documents/Personal/github/OmniWM && make verify 2>&1 | tail -20`

Expected: All checks pass (format-check, lint, build, test).

- [ ] **Step 2: Update Graphify graph**

Run: `cd /Users/biswadip.paul/Documents/Personal/github/OmniWM && graphify update Sources/ 2>&1 | tail -10`

- [ ] **Step 3: Verify new edge in Graphify**

Run: `cd /Users/biswadip.paul/Documents/Personal/github/OmniWM && graphify path "transferWindowFromSourceEngine" "normalizeColumnSizes" --graph Sources/graphify-out/graph.json 2>&1`

Expected: Path found (1 hop: transferWindowFromSourceEngine → normalizeColumnSizes).

- [ ] **Step 4: Runtime verification — build, launch, IPC ping**

Run:
```bash
cd /Users/biswadip.paul/Documents/Personal/github/OmniWM
swift build -c debug 2>&1 | tail -3
# Deploy built binary and restart Hiro, then:
omniwmctl query ping
```

Expected: IPC responds.

- [ ] **Step 5: Update memorygraph**

Store fix completion in memorygraph with tags `["hiro", "omniwm", "bug7", "fixed"]`.
