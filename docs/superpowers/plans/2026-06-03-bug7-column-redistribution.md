# Bug #7 Fix: Redistribute Column Widths After Window Removal

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a column is removed (window quit/minimized/hidden), redistribute remaining columns' proportional widths to fill the freed space. Single remaining column gets 100%.

**Architecture:** Add `normalizeRemainingColumnProportions` helper to `NiriLayoutEngine`. Call from all three column removal paths: `removeColumnByIdx`, `removeWindow`, and `cleanupEmptyColumn`. Only normalizes `.proportion` columns — `.fixed` columns are skipped. Pure state machine, no AX calls.

**Tech Stack:** Swift 6.2, Apple Testing framework, Niri layout engine

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Windows.swift` | Modify | Add helper, call from `removeColumnByIdx` and `removeWindow` |
| `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift` | Modify | Call from `cleanupEmptyColumn` |
| `Tests/OmniWMTests/NiriLayoutEngineTests.swift` | Modify | Add 3 redistribution tests |

---

### Task 1: Add `normalizeRemainingColumnProportions` Helper

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Windows.swift`

- [ ] **Step 1: Add the helper method**

Add at the end of the file (before the closing `}`), or after the `removeWindow` method:

```swift
    func normalizeRemainingColumnProportions(in workspaceId: WorkspaceDescriptor.ID) {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return }

        if cols.count == 1 {
            cols[0].width = .proportion(1.0)
            cols[0].cachedWidth = 0
            return
        }

        var totalProportion: CGFloat = 0
        for col in cols {
            if case let .proportion(p) = col.width {
                totalProportion += p
            }
        }

        guard totalProportion > 0 else { return }

        for col in cols {
            if case let .proportion(p) = col.width {
                col.width = .proportion(p / totalProportion)
                col.cachedWidth = 0
            }
        }
    }
```

- [ ] **Step 2: Verify build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Windows.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - feat: add normalizeRemainingColumnProportions helper

Normalizes proportional column widths to sum to 1.0 after a column is
removed. Single column gets 1.0 (100%). Fixed-width columns are skipped.
Pure state machine — no AX calls.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Call From All Three Column Removal Paths

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Windows.swift`
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift`

- [ ] **Step 1: Call in `removeWindow` (singular)**

In `removeWindow` (line 145), find the `if column.children.isEmpty` block (lines 160-169). Currently:

```swift
        if column.children.isEmpty {
            let root = column.parent as? NiriRoot
            column.remove()

            if let root {
                for col in root.columns {
                    col.cachedWidth = 0
                }
            }
        }
```

Replace with:

```swift
        if column.children.isEmpty {
            let wsId = (column.parent as? NiriRoot).flatMap { workspaceId(for: $0) }
            column.remove()

            if let wsId {
                normalizeRemainingColumnProportions(in: wsId)
            }
        }
```

Note: `workspaceId(for:)` may not exist. Let me check an alternative. The `removeWindow` function doesn't have `workspaceId` in scope. We need to find it from the root. Check if there's a mapping:

Actually, looking at the code, `removeWindow` has a `token` parameter. The engine has `roots: [WorkspaceDescriptor.ID: NiriRoot]`. We can find the workspace by checking which root contains the column's parent. Simpler approach: iterate `roots` to find the matching one:

```swift
        if column.children.isEmpty {
            let wsId = roots.first { $0.value === column.parent }?.key
            column.remove()

            if let wsId {
                normalizeRemainingColumnProportions(in: wsId)
            }
        }
```

- [ ] **Step 2: Call in `removeColumnByIdx`**

In `removeColumnByIdx` (line 382), after `column.remove()` (line 434), add:

```swift
        column.remove()
        normalizeRemainingColumnProportions(in: workspaceId)
```

The `workspaceId` parameter is already available in scope (it's a parameter of `removeWindows` which calls `removeColumnByIdx` via `removeTileByIdx`). Check if `removeColumnByIdx` has access to `workspaceId`. Looking at the code: `removeColumnByIdx` is a private function called from `removeTileByIdx` which is called from `removeWindows`. The `workspaceId` is available in `removeWindows` scope. Need to verify if `removeColumnByIdx` receives it.

Actually, `removeColumnByIdx` signature needs to be checked. Let me provide the instruction differently — the implementer should read the function signature and pass `workspaceId` through if needed.

- [ ] **Step 3: Call in `cleanupEmptyColumn`**

In `cleanupEmptyColumn` (NiriLayoutEngine+ColumnOps.swift, line 209), after `column.remove()` (line 216), add:

```swift
        column.remove()
        normalizeRemainingColumnProportions(in: workspaceId)
```

The `workspaceId` parameter is already available (it's `in workspaceId: WorkspaceDescriptor.ID` in the function signature).

- [ ] **Step 4: Verify build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Windows.swift Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - fix: redistribute column widths after removal (bug #7)

Call normalizeRemainingColumnProportions from all three column removal
paths: removeColumnByIdx (batch removal), removeWindow (sync/cross-
layout), and cleanupEmptyColumn (move/consume). Remaining columns
expand proportionally to fill freed space. Single column gets 100%.

Fixes bug #7.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Write Tests

**Files:**
- Modify: `Tests/OmniWMTests/NiriLayoutEngineTests.swift`

- [ ] **Step 1: Add redistribution tests**

Add at the end of the test suite (before the last closing `}`):

```swift
    @Test func removeColumnRedistributesProportionally() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let workingFrame = CGRect(x: 0, y: 0, width: 1800, height: 900)
        let gap: CGFloat = 2

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(h1, to: wsId)!
        let w2 = engine.addWindow(h2, to: wsId)!
        let w3 = engine.addWindow(h3, to: wsId)!

        engine.columns(in: wsId)[0].width = .proportion(0.4)
        engine.columns(in: wsId)[1].width = .proportion(0.3)
        engine.columns(in: wsId)[2].width = .proportion(0.3)

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.selectedNodeId = w1.id
        state.viewOffsetPixels = .static(0)

        _ = engine.removeWindows(
            Set([h2.id]),
            in: wsId,
            state: &state,
            motion: .disabled,
            workingFrame: workingFrame,
            gaps: gap,
            selectedNodeId: w1.id,
            removedNodeIds: [w2.id]
        )

        let remaining = engine.columns(in: wsId)
        #expect(remaining.count == 2)

        if case let .proportion(p1) = remaining[0].width,
           case let .proportion(p2) = remaining[1].width
        {
            #expect(abs(p1 - 0.5714) < 0.01)
            #expect(abs(p2 - 0.4286) < 0.01)
            #expect(abs(p1 + p2 - 1.0) < 0.001)
        } else {
            Issue.record("Expected proportional widths")
        }
    }

    @Test func singleRemainingColumnGetsFullWidth() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()
        let workingFrame = CGRect(x: 0, y: 0, width: 1800, height: 900)
        let gap: CGFloat = 2

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()

        let w1 = engine.addWindow(h1, to: wsId)!
        let w2 = engine.addWindow(h2, to: wsId)!

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.selectedNodeId = w1.id
        state.viewOffsetPixels = .static(0)

        _ = engine.removeWindows(
            Set([h2.id]),
            in: wsId,
            state: &state,
            motion: .disabled,
            workingFrame: workingFrame,
            gaps: gap,
            selectedNodeId: w1.id,
            removedNodeIds: [w2.id]
        )

        let remaining = engine.columns(in: wsId)
        #expect(remaining.count == 1)

        if case let .proportion(p) = remaining[0].width {
            #expect(abs(p - 1.0) < 0.001)
        } else {
            Issue.record("Expected proportional width of 1.0")
        }
    }
```

- [ ] **Step 2: Run tests**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter NiriLayoutEngineTests/removeColumnRedistributes 2>&1 | tail -10`

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter NiriLayoutEngineTests/singleRemainingColumn 2>&1 | tail -10`

Expected: Both tests pass.

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Tests/OmniWMTests/NiriLayoutEngineTests.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - test: add column width redistribution tests

Two tests:
- removeColumnRedistributesProportionally: 3 columns [0.4, 0.3, 0.3],
  remove middle, verify remaining at [0.571, 0.429]
- singleRemainingColumnGetsFullWidth: 2 columns, remove one, verify
  remaining at 1.0

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Verify End-to-End, Bump Version, Push

- [ ] **Step 1: Build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

- [ ] **Step 2: Bump build version**

In `Info.plist`, change `CFBundleVersion` from `60` to `61`.

- [ ] **Step 3: Commit and push**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Info.plist
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - chore: bump build to 61

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
git push origin fix/tiled-window-z-order
```

- [ ] **Step 4: Manual verification**

```bash
pkill -x OmniWM
nohup log stream --predicate 'subsystem == "com.omniwm"' --debug --style compact > /private/tmp/omniwm-logs.txt 2>&1 &
sleep 1
~/Documents/Personal/github/OmniWM/.build/debug/OmniWM &
```

Then:
1. Open 3 windows on one workspace
2. Close one → remaining 2 should expand to fill screen
3. Close another → last one should fill 100%
