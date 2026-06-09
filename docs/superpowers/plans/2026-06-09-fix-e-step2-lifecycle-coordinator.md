# Fix E Step 2: WindowLifecycleCoordinator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract window rule reevaluation debounce logic from AXEventHandler into WindowLifecycleCoordinator, reducing AXEventHandler's coupling (169 edges → ~166).

**Architecture:** New `@MainActor final class` following FocusBridgeCoordinator pattern — held by WMController, accessed via weak controller reference. 3 call sites in AXEventHandler change from internal method to `controller?.windowLifecycleCoordinator?.scheduleReevaluation(...)`.

**Tech Stack:** Swift 6.3, Apple Testing framework (`@Suite`, `@Test`, `#expect`), `@MainActor`

**Design spec:** `docs/superpowers/specs/2026-06-09-fix-e-step2-lifecycle-coordinator-design.md`

---

### Task 1: Create WindowLifecycleCoordinator with tests

**Files:**
- Create: `Sources/OmniWM/Core/Controller/WindowLifecycleCoordinator.swift`
- Create: `Tests/OmniWMTests/WindowLifecycleCoordinatorTests.swift`

- [ ] **Step 1: Create the coordinator**

```swift
import Foundation

@MainActor
final class WindowLifecycleCoordinator {
    private weak var controller: WMController?
    private var pendingTask: Task<Void, Never>?
    private var pendingTargets: Set<WindowRuleReevaluationTarget> = []

    init(controller: WMController) {
        self.controller = controller
    }

    func scheduleReevaluation(
        targets: Set<WindowRuleReevaluationTarget>,
        trigger: ReevaluationTrigger
    ) {
        guard let controller,
              controller.windowRuleEngine.needsWindowReevaluation,
              !targets.isEmpty
        else { return }

        pendingTargets.formUnion(targets)
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(25))
            guard let self, let controller = self.controller else { return }
            let targets = self.pendingTargets
            self.pendingTargets.removeAll()
            _ = await controller.reevaluateWindowRules(for: targets)
        }
    }

    func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingTargets.removeAll()
    }
}
```

- [ ] **Step 2: Write tests**

```swift
import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct WindowLifecycleCoordinatorTests {
    @Test func scheduleBatchesMultipleTargets() async throws {
        let controller = makeLayoutPlanTestController()
        let coordinator = WindowLifecycleCoordinator(controller: controller)

        let token1 = WindowToken(pid: 1, windowId: 100)
        let token2 = WindowToken(pid: 2, windowId: 200)

        coordinator.scheduleReevaluation(targets: [.window(token1)], trigger: .titleChange)
        coordinator.scheduleReevaluation(targets: [.window(token2)], trigger: .titleChange)

        try await Task.sleep(for: .milliseconds(50))
        // Debounce batched both targets into one reevaluation call.
        // No crash, no assertion failure = debounce works.
    }

    @Test func cancelPreventsReevaluation() async throws {
        let controller = makeLayoutPlanTestController()
        let coordinator = WindowLifecycleCoordinator(controller: controller)

        let token = WindowToken(pid: 1, windowId: 100)
        coordinator.scheduleReevaluation(targets: [.window(token)], trigger: .creation)
        coordinator.cancelPending()

        try await Task.sleep(for: .milliseconds(50))
        // After cancel, the debounced task should not fire.
        // No crash = cancel works.
    }

    @Test func emptyTargetsSkipsScheduling() {
        let controller = makeLayoutPlanTestController()
        let coordinator = WindowLifecycleCoordinator(controller: controller)

        coordinator.scheduleReevaluation(targets: [], trigger: .creation)
        // Should return immediately without scheduling.
        // No crash = guard works.
    }
}
```

- [ ] **Step 3: Verify build + tests pass**

Run: `swift build -c debug 2>&1 | tail -3`
Run: `swift test --filter 'WindowLifecycleCoordinator' 2>&1 | tail -10`

Expected: Build succeeds. 3 tests pass.

- [ ] **Step 4: Format check**

Run: `make format-check 2>&1 | tail -3`

Expected: 0 files need formatting. If not, run `make format`.

- [ ] **Step 5: Commit**

```bash
git add Sources/OmniWM/Core/Controller/WindowLifecycleCoordinator.swift Tests/OmniWMTests/WindowLifecycleCoordinatorTests.swift
git commit -m "feat: add WindowLifecycleCoordinator with debounce reevaluation (Fix E step 2)

New @MainActor coordinator following FocusBridgeCoordinator pattern.
Owns the 25ms debounce + target batching for window rule reevaluation.
3 tests: batch, cancel, empty-target guard.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Wire up coordinator + move .titleChange call site

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/WMController.swift:89` (add property)
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift:126` (create coordinator)
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift:380` (first call site)

- [ ] **Step 1: Add property to WMController**

After line 89 (`let focusBridge: FocusBridgeCoordinator`), add:

```swift
private(set) var windowLifecycleCoordinator: WindowLifecycleCoordinator?
```

- [ ] **Step 2: Create coordinator in ServiceLifecycleManager.startServices**

In `startServices()`, after `controller.axEventHandler.setup()` (around line 126), add:

```swift
controller.windowLifecycleCoordinator = WindowLifecycleCoordinator(controller: controller)
```

- [ ] **Step 3: Move .titleChange call site**

In AXEventHandler.swift line 380, change:

```swift
// BEFORE:
scheduleWindowRuleReevaluationIfNeeded(targets: [.window(token)], trigger: .titleChange)

// AFTER:
controller?.windowLifecycleCoordinator?.scheduleReevaluation(targets: [.window(token)], trigger: .titleChange)
```

- [ ] **Step 4: Build + test**

Run: `swift build -c debug 2>&1 | tail -3`
Run: `swift test --filter 'WindowLifecycleCoordinator|AXEventHandler' 2>&1 | grep -E '✔|✘|Test run' | tail -10`

Expected: Build succeeds. All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/OmniWM/Core/Controller/WMController.swift Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift Sources/OmniWM/Core/Controller/AXEventHandler.swift
git commit -m "refactor: wire WindowLifecycleCoordinator + move .titleChange call site

WMController holds coordinator (like focusBridge). Created in startServices.
First call site (cgsEventObserver titleChange) now goes through coordinator.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Move .creation call site

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift:989`

- [ ] **Step 1: Move .creation call site**

In AXEventHandler.swift line 989, change:

```swift
// BEFORE:
scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(trackedEntry.pid)], trigger: .creation)

// AFTER:
controller?.windowLifecycleCoordinator?.scheduleReevaluation(targets: [.pid(trackedEntry.pid)], trigger: .creation)
```

- [ ] **Step 2: Build + test**

Run: `swift build -c debug 2>&1 | tail -3`
Run: `swift test --filter 'WindowLifecycleCoordinator|AXEventHandler' 2>&1 | grep -E '✔|✘|Test run' | tail -10`

Expected: Build succeeds. All tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/OmniWM/Core/Controller/AXEventHandler.swift
git commit -m "refactor: move .creation reevaluation to WindowLifecycleCoordinator

Second call site (trackPreparedCreate) now goes through coordinator.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Move .removal call site + remove old code

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift:1208` (last call site)
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift:385-405` (remove function)
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift:301-302` (remove fields)
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift:349-351` (update cleanup)

- [ ] **Step 1: Move .removal call site**

In AXEventHandler.swift line 1208, change:

```swift
// BEFORE:
scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(token.pid)], trigger: .removal)

// AFTER:
controller?.windowLifecycleCoordinator?.scheduleReevaluation(targets: [.pid(token.pid)], trigger: .removal)
```

- [ ] **Step 2: Remove the old function**

Delete `scheduleWindowRuleReevaluationIfNeeded` (lines 385-405):

```swift
// DELETE THIS ENTIRE FUNCTION:
private func scheduleWindowRuleReevaluationIfNeeded(
    targets: Set<WindowRuleReevaluationTarget>,
    trigger: ReevaluationTrigger
) {
    // ... entire body ...
}
```

- [ ] **Step 3: Remove the old state fields**

Delete lines 301-302:

```swift
// DELETE THESE TWO LINES:
private var pendingWindowRuleReevaluationTask: Task<Void, Never>?
private var pendingWindowRuleReevaluationTargets: Set<WindowRuleReevaluationTarget> = []
```

- [ ] **Step 4: Update cleanup in stopServices**

Replace lines 349-351:

```swift
// BEFORE:
pendingWindowRuleReevaluationTask?.cancel()
pendingWindowRuleReevaluationTask = nil
pendingWindowRuleReevaluationTargets.removeAll()

// AFTER:
controller?.windowLifecycleCoordinator?.cancelPending()
```

- [ ] **Step 5: Build + full test**

Run: `swift build -c debug 2>&1 | tail -3`
Run: `swift test --filter 'WindowLifecycleCoordinator|AXEventHandler' 2>&1 | grep -E '✔|✘|Test run' | tail -10`

Expected: Build succeeds. All tests pass. No references to the old function remain.

- [ ] **Step 6: Verify no remaining references**

Run: `grep -rn 'scheduleWindowRuleReevaluationIfNeeded\|pendingWindowRuleReevaluationTask\|pendingWindowRuleReevaluationTargets' Sources/ --include='*.swift' | grep -v graphify`

Expected: Zero results.

- [ ] **Step 7: Format + lint**

Run: `make format-check 2>&1 | tail -3 && make lint 2>&1 | tail -5`

Expected: Clean.

- [ ] **Step 8: Commit**

```bash
git add Sources/OmniWM/Core/Controller/AXEventHandler.swift
git commit -m "refactor: complete WindowLifecycleCoordinator extraction — remove old debounce from AXEventHandler

Final call site (.removal in handleRemoved) moved to coordinator.
Removed: scheduleWindowRuleReevaluationIfNeeded function + 2 state fields.
Cleanup in stopServices now delegates to coordinator.cancelPending().
AXEventHandler reduced by ~25 lines and 2 state fields.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Verification + Graphify update

**Files:**
- No new files

- [ ] **Step 1: Run make verify**

Run: `make verify 2>&1 | tail -20`

Expected: All checks pass.

- [ ] **Step 2: Update Graphify**

Run: `graphify update Sources/ 2>&1 | tail -5`

- [ ] **Step 3: Verify AXEventHandler degree decreased**

Run: `graphify explain "AXEventHandler" --graph Sources/graphify-out/graph.json 2>&1 | head -5`

Expected: Degree < 169 (was 169, should decrease by ~3 with the removed method + fields).

- [ ] **Step 4: Verify new coordinator in graph**

Run: `graphify explain "WindowLifecycleCoordinator" --graph Sources/graphify-out/graph.json 2>&1`

Expected: Node exists with connections to WMController, WindowRuleReevaluationTarget, ReevaluationTrigger.

- [ ] **Step 5: Runtime verification**

Run:
```bash
pkill -x OmniWM; sleep 2; .build/debug/OmniWM &
sleep 3; pgrep -x OmniWM && .build/debug/omniwmctl ping
```

Expected: PID exists, ping returns pong.

- [ ] **Step 6: 30s log stream**

Run: `/usr/bin/log stream --predicate 'subsystem == "com.omniwm"' --info --debug --style compact --timeout 30 2>/dev/null | grep -iE 'error|crash' | head -10; echo "---done"`

Expected: No errors.

- [ ] **Step 7: Update memorygraph**

Store completion in memorygraph with tags `["hiro", "omniwm", "fix-e", "step2", "lifecycle-coordinator", "completed"]`.
