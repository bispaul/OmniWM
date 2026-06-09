# Fix E Step 2: WindowLifecycleCoordinator Extraction — Design Spec

## Goal

Extract window rule reevaluation debounce logic from AXEventHandler (169 edges, god node #3) into a dedicated WindowLifecycleCoordinator, following the existing coordinator pattern (FocusBridgeCoordinator).

## Architecture

**Pattern:** Same as FocusBridgeCoordinator — `@MainActor final class`, held by WMController, accessed by AXEventHandler via weak controller reference.

**New file:** `Sources/OmniWM/Core/Controller/WindowLifecycleCoordinator.swift`

```swift
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

## Changes

### WMController
- Add property: `private(set) var windowLifecycleCoordinator: WindowLifecycleCoordinator?`
- In `startServices` (ServiceLifecycleManager.swift): `controller.windowLifecycleCoordinator = WindowLifecycleCoordinator(controller: controller)`

### AXEventHandler — 3 call sites changed
1. **Line 380** (cgsEventObserver, .titleChange):
   `scheduleWindowRuleReevaluationIfNeeded(...)` → `controller?.windowLifecycleCoordinator?.scheduleReevaluation(...)`
2. **Line 989** (trackPreparedCreate, .creation):
   Same transformation.
3. **Line 1208** (handleRemoved, .removal):
   Same transformation.

### AXEventHandler — removed
- `scheduleWindowRuleReevaluationIfNeeded` function (lines 385-405)
- `pendingWindowRuleReevaluationTask` field (line 301)
- `pendingWindowRuleReevaluationTargets` field (line 302)
- Cancel in `stopServices` (lines 349-351) → replaced by `controller?.windowLifecycleCoordinator?.cancelPending()`

### NOT changed
- Line 3045: direct `reevaluateWindowRules` call in stabilization retry — different mechanism, stays in AXEventHandler
- `reevaluateWindowRules` function — stays in WMController
- `ReevaluationTrigger` and `WindowRuleReevaluationTarget` — stay in WindowRuleEngine.swift (already public)

## Testing

New `WindowLifecycleCoordinatorTests.swift`:
1. Debounce batching: schedule 3 targets in rapid succession, verify single reevaluateWindowRules call with all 3 targets
2. Cancel: schedule, cancel, verify no reevaluation fires
3. Guard: needsWindowReevaluation=false → verify no scheduling
4. Empty targets: verify guard rejects

## Commits (incremental)
1. Add WindowLifecycleCoordinator.swift + tests
2. Wire up in WMController/ServiceLifecycleManager + move .titleChange call site
3. Move .creation call site
4. Move .removal call site + remove old function/fields from AXEventHandler

## Alignment
- Phase 1-5: no conflict (reevaluation timing unchanged)
- Fix D: orthogonal (viewport vs lifecycle)
- Fix E steps 3-4: foundation — selectedNodeId/cachedFrame extraction builds on this coordinator
- AGENTS.md coordinator pattern: followed exactly
