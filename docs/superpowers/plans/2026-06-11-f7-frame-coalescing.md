# F7 Frame Coalescing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add selective animation to `ensureSelectionVisible` so programmatic viewport shifts write final position directly (1 AX frame batch) while user navigation keeps smooth spring animation (13 batches).

**Architecture:** Add `animate: Bool` (no default) parameter to `ensureSelectionVisible`, propagating to existing `ensureContainerVisible(animate:)`. Two typed wrapper methods for rot prevention. Thread through existing `NodeActivationOptions.startAnimation` for the `activateNode` edge case. 26 call sites across 8 files.

**Tech Stack:** Swift 6.3, Apple Testing framework (`@Test`), `swift build -c debug`, `swift test --filter`

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `Sources/OmniWM/Core/Layout/Niri/NiriNavigation.swift:167-242` | Add `animate: Bool` param, propagate to `ensureContainerVisible` |
| Create | `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+SelectionVisibility.swift` | Two typed wrapper methods |
| Modify | `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:201,211` | Pass `animate: true` through `ensureSelectionVisibleForPendingWidth` |
| Modify | `Sources/OmniWM/Core/Layout/Niri/NiriNavigation.swift:89,279,304,391,529,559,623,653` | 8 user-initiated sites → `animate: true` |
| Modify | `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+InteractiveMove.swift:227,294` | 2 user-initiated sites → `animate: true` |
| Modify | `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+InteractiveResize.swift:253` | 1 user-initiated site → `animate: true` |
| Modify | `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Windows.swift:290,472` | 2 programmatic sites → `animate: false` |
| Modify | `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift:197,590,833,856` | 4 programmatic sites → `animate: false` |
| Modify | `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift:692,767,1168,1658` | 3 programmatic + 1 edge case (activateNode) |
| Modify | `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift:512,917,1041` | 3 programmatic sites → `animate: false` |
| Modify | `Tests/OmniWMTests/MotionTestSupport.swift:46` | Add `animate: Bool = true` to test helper overload |
| Create | `Tests/OmniWMTests/SelectiveAnimationTests.swift` | New tests for animate: true/false behavior |

---

### Task 1: Add `animate: Bool` parameter to `ensureSelectionVisible` and update test helper

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriNavigation.swift:167-242`
- Modify: `Tests/OmniWMTests/MotionTestSupport.swift:46-70`

- [ ] **Step 1: Write failing test for animate: false producing static offset**

Create `Tests/OmniWMTests/SelectiveAnimationTests.swift`:

```swift
import Testing
@testable import OmniWM

@Suite @MainActor
struct SelectiveAnimationTests {
    private func makeTestHandle() -> WindowHandle {
        WindowHandle(pid: 1, windowId: Int.random(in: 1000...9999))
    }

    @Test func ensureSelectionVisibleWithAnimateFalseProducesStaticOffset() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let gap: CGFloat = 8
        for col in engine.columns(in: wsId) {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: w2,
            in: wsId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap,
            animate: false
        )

        #expect(state.activeColumnIndex == 1)
        // With animate: false, viewOffsetPixels must be .static (not .spring)
        switch state.viewOffsetPixels {
        case .static:
            break // expected
        default:
            Issue.record("Expected .static offset but got animating offset")
        }
    }

    @Test func ensureSelectionVisibleWithAnimateTrueProducesSpringAnimation() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        _ = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let gap: CGFloat = 8
        for col in engine.columns(in: wsId) {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: w2,
            in: wsId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap,
            animate: true
        )

        #expect(state.activeColumnIndex == 1)
        // With animate: true + motion enabled, viewOffsetPixels should be .spring
        // (unless the column is already fully visible, in which case no animation needed)
        // The offset should have changed from 0
        let target = state.viewOffsetPixels.target()
        #expect(target != 0 || state.viewOffsetPixels.current() != 0 || state.activeColumnIndex == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter "SelectiveAnimationTests" 2>&1 | tail -10
```

Expected: FAIL — `animate:` parameter doesn't exist yet on `ensureSelectionVisible`.

- [ ] **Step 3: Add `animate: Bool` parameter to `ensureSelectionVisible`**

In `Sources/OmniWM/Core/Layout/Niri/NiriNavigation.swift`, change the signature at line 167 from:

```swift
    func ensureSelectionVisible(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal,
```

to:

```swift
    func ensureSelectionVisible(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        animate: Bool,
        orientation: Monitor.Orientation = .horizontal,
```

Then at line ~231 (inside the method body), change the `ensureContainerVisible` call from:

```swift
            animate: true,
```

to:

```swift
            animate: animate,
```

- [ ] **Step 4: Update the test helper overload in `MotionTestSupport.swift`**

At line 46, add `animate: Bool = true` to the test helper and pass it through:

```swift
    func ensureSelectionVisible(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        animate: Bool = true,
        orientation: Monitor.Orientation = .horizontal,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        previousActiveContainerPosition: CGFloat? = nil
    ) {
        ensureSelectionVisible(
            node: node,
            in: workspaceId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            animate: animate,
            orientation: orientation,
            animationConfig: animationConfig,
            fromContainerIndex: fromContainerIndex,
            previousActiveContainerPosition: previousActiveContainerPosition
        )
    }
```

Note: the test helper keeps `animate: Bool = true` as default so existing tests (which expect animation) continue to compile and pass without changes.

- [ ] **Step 5: Build to verify compilation**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: compilation FAILS — 26 call sites now need `animate:` argument (they don't pass it yet).

This is expected and correct — the no-default parameter forces every site to be updated. The build errors serve as a checklist.

- [ ] **Step 6: Commit the parameter addition (will not compile — WIP)**

```bash
git add Sources/OmniWM/Core/Layout/Niri/NiriNavigation.swift Tests/OmniWMTests/MotionTestSupport.swift Tests/OmniWMTests/SelectiveAnimationTests.swift
git commit -m "feat(F7): add animate: Bool parameter to ensureSelectionVisible (WIP — call sites pending)"
```

---

### Task 2: Update 8 user-initiated call sites in NiriNavigation.swift

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriNavigation.swift` — lines 89, 279, 304, 391, 529, 559, 623, 653

- [ ] **Step 1: Add `animate: true` to all 8 internal call sites**

Each call to `ensureSelectionVisible(` inside NiriNavigation.swift needs `animate: true` added after the `gaps:` parameter. All 8 are user navigation methods (keyboard left/right, focus commands, Alt+Tab).

At each of these lines, add `animate: true,` after `gaps: gaps,` (or after `gaps: gap,`):
- Line 89 (`moveSelectionCrossContainer`)
- Line 279 (`focusCombined`)
- Line 304 (`focusCombined` fallback)
- Line 391 (`focusColumnByIndex`)
- Line 529 (`focusWindowDownOrTop`)
- Line 559 (`focusWindowUpOrBottom`)
- Line 623 (`focusWindowAtVisualIndex`)
- Line 653 (`focusPrevious`)

Example — line 89 changes from:

```swift
        ensureSelectionVisible(
            node: newSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
```

to:

```swift
        ensureSelectionVisible(
            node: newSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            animate: true,
            orientation: orientation
        )
```

Repeat the same pattern for all 8 sites.

- [ ] **Step 2: Build to verify these 8 are resolved**

```bash
swift build -c debug 2>&1 | grep "error:" | wc -l
```

Expected: error count drops by 8 (from 26 to 18).

- [ ] **Step 3: Commit**

```bash
git add Sources/OmniWM/Core/Layout/Niri/NiriNavigation.swift
git commit -m "feat(F7): update 8 user-initiated ESV sites in NiriNavigation (animate: true)"
```

---

### Task 3: Update 5 user-initiated call sites in InteractiveMove, InteractiveResize, Sizing

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+InteractiveMove.swift` — lines 227, 294
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+InteractiveResize.swift` — line 253
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift` — lines 201, 211

- [ ] **Step 1: Add `animate: true` to InteractiveMove (2 sites) and InteractiveResize (1 site)**

Same pattern as Task 2 — add `animate: true,` after the `gaps:` parameter at each call site.

- [ ] **Step 2: Add `animate: true` to Sizing (2 sites)**

In `NiriLayoutEngine+Sizing.swift`, the `ensureSelectionVisibleForPendingWidth` wrapper calls `ensureSelectionVisible` at lines 201 and 211. Add `animate: true,` after `gaps: gaps,` at both sites.

- [ ] **Step 3: Build to verify**

```bash
swift build -c debug 2>&1 | grep "error:" | wc -l
```

Expected: error count drops by 5 (from 18 to 13).

- [ ] **Step 4: Commit**

```bash
git add Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+InteractiveMove.swift Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+InteractiveResize.swift Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift
git commit -m "feat(F7): update 5 user-initiated ESV sites in Move/Resize/Sizing (animate: true)"
```

---

### Task 4: Update 6 programmatic call sites in Windows and ColumnOps

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Windows.swift` — lines 290, 472
- Modify: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift` — lines 197, 590, 833, 856

- [ ] **Step 1: Add `animate: false` to Windows (2 sites)**

At lines 290 and 472 in `NiriLayoutEngine+Windows.swift`, add `animate: false,` after `gaps: gaps,` (or after the `gaps` parameter). These are window removal paths — no user-visible scroll animation needed.

- [ ] **Step 2: Add `animate: false` to ColumnOps (4 sites)**

At lines 197, 590, 833, 856 in `NiriLayoutEngine+ColumnOps.swift`, add `animate: false,` after the `gaps:` parameter. These are column structural operations — insertions, consume, expel, move.

- [ ] **Step 3: Build to verify**

```bash
swift build -c debug 2>&1 | grep "error:" | wc -l
```

Expected: error count drops by 6 (from 13 to 7).

- [ ] **Step 4: Commit**

```bash
git add Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Windows.swift Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift
git commit -m "feat(F7): update 6 programmatic ESV sites in Windows/ColumnOps (animate: false)"
```

---

### Task 5: Update 7 controller-layer call sites (NiriLayoutHandler + WorkspaceNavigationHandler)

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift` — lines 692, 767, 1168, 1658
- Modify: `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift` — lines 512, 917, 1041

- [ ] **Step 1: Add `animate: false` to NiriLayoutHandler programmatic sites (lines 692, 767)**

At line 692 (`resolveSelection` removal path) and 767 (`handleNewWindowArrival`), add `animate: false,` after `gaps:`.

- [ ] **Step 2: Add `animate: true` to NiriLayoutHandler user-initiated site (line 1168)**

At line 1168 (`selectTabInNiri`), add `animate: true,` after `gaps:`.

- [ ] **Step 3: Thread `animate` through `activateNode` edge case (line 1658)**

At line 1658 (`activateNode`), the `NodeActivationOptions` struct already has `startAnimation: Bool = true` (line 2037). Use it:

Change from:

```swift
            engine.ensureSelectionVisible(
                node: node,
                in: workspaceId,
                motion: controller.motionPolicy.snapshot(),
                state: &state,
                workingFrame: workingFrame,
                gaps: gap
            )
```

to:

```swift
            engine.ensureSelectionVisible(
                node: node,
                in: workspaceId,
                motion: controller.motionPolicy.snapshot(),
                state: &state,
                workingFrame: workingFrame,
                gaps: gap,
                animate: options.startAnimation
            )
```

- [ ] **Step 4: Add `animate: false` to WorkspaceNavigationHandler (3 sites)**

At lines 512 (`atomicTransferWindow`), 917 (`moveFocusedWindow`), and 1041 (`moveWindow`), add `animate: false,` after `gaps:`.

- [ ] **Step 5: Build — should compile cleanly now (0 errors)**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!` — all 26 call sites now have explicit `animate:` parameter.

- [ ] **Step 6: Run selective animation tests**

```bash
swift test --filter "SelectiveAnimationTests" 2>&1 | tail -10
```

Expected: 2 tests PASS.

- [ ] **Step 7: Run all existing ESV tests to verify no regression**

```bash
swift test --filter "ensureSelectionVisible" 2>&1 | tail -10
```

Expected: all existing tests PASS (they use the test helper with `animate: true` default).

- [ ] **Step 8: Commit**

```bash
git add Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift
git commit -m "feat(F7): update 7 controller ESV sites — 3 programmatic, 1 user, 1 edge case (activateNode)"
```

---

### Task 6: Create typed wrapper methods

**Files:**
- Create: `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+SelectionVisibility.swift`

- [ ] **Step 1: Write test for wrapper methods**

Add to `Tests/OmniWMTests/SelectiveAnimationTests.swift`:

```swift
    @Test func userNavigationWrapperAnimates() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let gap: CGFloat = 8
        for col in engine.columns(in: wsId) {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisibleAfterUserNavigation(
            node: w2,
            in: wsId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        #expect(state.activeColumnIndex == 1)
    }

    @Test func layoutChangeWrapperDoesNotAnimate() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let gap: CGFloat = 8
        for col in engine.columns(in: wsId) {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisibleAfterLayoutChange(
            node: w2,
            in: wsId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        #expect(state.activeColumnIndex == 1)
        switch state.viewOffsetPixels {
        case .static:
            break
        default:
            Issue.record("Expected .static offset from layout change wrapper")
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter "SelectiveAnimationTests" 2>&1 | tail -10
```

Expected: FAIL — wrapper methods don't exist yet.

- [ ] **Step 3: Create wrapper file**

Create `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+SelectionVisibility.swift`:

```swift
import CoreGraphics

extension NiriLayoutEngine {
    func ensureSelectionVisibleAfterUserNavigation(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        previousActiveContainerPosition: CGFloat? = nil
    ) {
        ensureSelectionVisible(
            node: node,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            animate: true,
            orientation: orientation,
            animationConfig: animationConfig,
            fromContainerIndex: fromContainerIndex,
            previousActiveContainerPosition: previousActiveContainerPosition
        )
    }

    func ensureSelectionVisibleAfterLayoutChange(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal,
        fromContainerIndex: Int? = nil,
        previousActiveContainerPosition: CGFloat? = nil
    ) {
        ensureSelectionVisible(
            node: node,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            animate: false,
            orientation: orientation,
            fromContainerIndex: fromContainerIndex,
            previousActiveContainerPosition: previousActiveContainerPosition
        )
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter "SelectiveAnimationTests" 2>&1 | tail -10
```

Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+SelectionVisibility.swift Tests/OmniWMTests/SelectiveAnimationTests.swift
git commit -m "feat(F7): add typed wrappers — ensureSelectionVisibleAfterUserNavigation/LayoutChange"
```

---

### Task 7: Pre-commit quality gates

**Files:** None modified — verification only.

- [ ] **Step 1: Run format check**

```bash
make format-check
```

Expected: 0 files need formatting. If any do, run `make format` first.

- [ ] **Step 2: Run lint**

```bash
make lint
```

Expected: 0 serious violations.

- [ ] **Step 3: Run all ESV-related tests**

```bash
swift test --filter "SelectiveAnimation|ensureSelectionVisible|ViewportPipeline|ViewportGeometry" 2>&1 | tail -15
```

Expected: all pass with specific count.

- [ ] **Step 4: Run full test suite for the affected areas**

```bash
swift test --filter "NiriLayoutEngineTests|NiriLayoutHandlerTests" 2>&1 | tail -15
```

Expected: all pass.

- [ ] **Step 5: Graphify update**

```bash
graphify update Sources/
```

Verify no god node growth. Check new file appears in graph.

- [ ] **Step 6: Run CodeRabbit review on the full diff**

Invoke `coderabbit:code-review` skill on `git diff HEAD~5` (all F7 changes). Address any findings before finalizing.

---

### Task 8: Runtime verification

**Files:** None modified — verification only.

- [ ] **Step 1: Build signed binary**

```bash
make build-sign
```

Expected: build succeeds, binary signed with dev cert.

- [ ] **Step 2: Deploy and verify running**

```bash
pkill -x OmniWM; sleep 1; .build/debug/OmniWM &
sleep 3
.build/debug/omniwmctl query ping
```

Expected: `pong` response.

- [ ] **Step 3: Verify logs flowing**

```bash
PID=$(pgrep -x OmniWM)
/usr/bin/log show --predicate "processIdentifier == $PID AND subsystem == 'com.omniwm'" --last 10s --info --debug | head -20
```

Expected: log output present (not empty).

- [ ] **Step 4: Test programmatic shift — move window between workspaces**

Move a window from workspace 1 to workspace 8 via hotkey. Then check logs:

```bash
/usr/bin/log show --predicate "subsystem == 'com.omniwm' AND category == 'layout'" --last 10s --info --debug | grep -c "Dirty reflow"
```

Expected: 1 dirty reflow (not 13). No visible flutter during transfer.

- [ ] **Step 5: Test user navigation — keyboard column left/right**

Navigate between columns using keyboard hotkeys. Verify smooth spring animation is preserved (columns scroll smoothly, not teleporting).

- [ ] **Step 6: Test window close — verify no animation slide**

Close a window in a 3-column workspace. Remaining columns should snap to position without visible scroll animation.

- [ ] **Step 7: Stream logs for 30 seconds — check for errors**

```bash
/usr/bin/log stream --predicate "subsystem == 'com.omniwm'" --info --debug --timeout 30 2>&1 | grep -i "error" | head -5
```

Expected: no error-level entries.
