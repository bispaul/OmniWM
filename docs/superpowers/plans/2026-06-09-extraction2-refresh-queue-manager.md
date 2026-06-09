# Extraction 2: RefreshQueueManager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the refresh queue state machine from LayoutRefreshController into a standalone, unit-testable RefreshQueueManager class with 25+ merge matrix tests.

**Architecture:** New `@MainActor final class RefreshQueueManager` owns queue state (`activeRefresh`, `pendingRefresh`, `activeRefreshTask`) and all merge/dispatch logic. LayoutRefreshController provides an executor closure for running refreshes and a completion callback for finishRefresh. The 25-case merge matrix becomes directly unit-testable.

**Tech Stack:** Swift 6.3, `@MainActor`, async/await, Apple Testing framework

**Design spec:** `docs/superpowers/specs/2026-06-09-extraction2-refresh-queue-manager-design.md`

---

### Task 1: Create RefreshQueueManager with merge matrix

**Files:**
- Create: `Sources/OmniWM/Core/Controller/RefreshQueueManager.swift`

This is the largest task. The implementer must:

- [ ] **Step 1: Read the source code to extract**

Read `Sources/OmniWM/Core/Controller/LayoutRefreshController.swift` at these line ranges:
- Lines 16-83: `ScheduledRefreshKind`, `WindowRemovalPayload`, `FollowUpRefresh`, `ScheduledRefresh`, `RefreshDebugCounters`, `RefreshDebugHooks` — these types will be referenced by the new class
- Lines 141-169: `LayoutState` — contains `activeRefresh`, `pendingRefresh`, `activeRefreshTask` to move
- Lines 1713-1768: `enqueueRefresh`, `handleRefresh` — queue dispatch
- Lines 1770-1917: `absorbIntoActiveFullRescan`, `mergePendingRefresh` — the merge matrix
- Lines 1919-1955: `startNextRefreshIfNeeded` — queue lifecycle
- Lines 1997-2018: `recordRefreshExecution`, `recordRefreshRequest` — debug counters
- Lines 2019-2130: all merge helpers (`mergeWindowRemovalPayloads`, `mergedAffectedWorkspaceIds`, `mergeFollowUp`, `mergeAbsorbedVisibility`, `mergeFollowUpRefresh`, `preserveCancelledRefreshState`)

- [ ] **Step 2: Create RefreshQueueManager.swift**

Create `Sources/OmniWM/Core/Controller/RefreshQueueManager.swift` with:

```swift
import Foundation

@MainActor
final class RefreshQueueManager {
    typealias Executor = (LayoutRefreshController.ScheduledRefresh) async -> Bool
    typealias CompletionHandler = (LayoutRefreshController.ScheduledRefresh, Bool) -> Void

    private(set) var activeRefresh: LayoutRefreshController.ScheduledRefresh?
    private(set) var pendingRefresh: LayoutRefreshController.ScheduledRefresh?
    private var activeRefreshTask: Task<Void, Never>?
    var debugCounters = LayoutRefreshController.RefreshDebugCounters()
    var debugHooks = LayoutRefreshController.RefreshDebugHooks()

    private let executor: Executor
    private let onComplete: CompletionHandler

    init(executor: @escaping Executor, onComplete: @escaping CompletionHandler) {
        self.executor = executor
        self.onComplete = onComplete
    }

    // Then move: enqueueRefresh, handleRefresh, mergePendingRefresh,
    // absorbIntoActiveFullRescan, startNextRefreshIfNeeded,
    // preserveCancelledRefreshState, and all 5 merge helpers
    // from LayoutRefreshController — adapting private references
    // from layoutState.activeRefresh to self.activeRefresh etc.

    func cancelActiveTask() {
        activeRefreshTask?.cancel()
    }

    func reset() {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        activeRefresh = nil
        pendingRefresh = nil
    }
}
```

The key adaptation: every `layoutState.activeRefresh` becomes `self.activeRefresh`, every `layoutState.pendingRefresh` becomes `self.pendingRefresh`, every `layoutState.activeRefreshTask` becomes `self.activeRefreshTask`.

The types (`ScheduledRefresh`, `ScheduledRefreshKind`, etc.) stay nested inside `LayoutRefreshController` — the manager references them via `LayoutRefreshController.ScheduledRefresh`.

- [ ] **Step 3: Build to verify**

Run: `swift build -c debug 2>&1 | tail -5`

Expected: Compiles (new file, no callers yet — no errors expected).

- [ ] **Step 4: Commit**

```bash
git add Sources/OmniWM/Core/Controller/RefreshQueueManager.swift
git commit -m "feat: add RefreshQueueManager with merge matrix (Extraction 2)

New @MainActor class owns queue state + 25-case merge matrix.
Executor closure + completion callback pattern. Types remain
nested in LayoutRefreshController — manager references them
via qualified names.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Write merge matrix tests

**Files:**
- Create: `Tests/OmniWMTests/RefreshQueueManagerTests.swift`

- [ ] **Step 1: Write tests for the merge matrix**

Create test file with tests for the 25-case merge matrix. Each test creates a `RefreshQueueManager` with a no-op executor, enqueues two refreshes with specific kinds, and verifies the resulting `pendingRefresh.kind`.

Key cases to test (minimum):
- fullRescan + fullRescan → fullRescan (keeps priority)
- fullRescan + anything → fullRescan (absorbs lower priority)
- visibilityRefresh + fullRescan → fullRescan (upgrades)
- windowRemoval + windowRemoval → windowRemoval (merges payloads)
- windowRemoval + immediateRelayout → windowRemoval + followUp(immediateRelayout)
- immediateRelayout + relayout → immediateRelayout (keeps priority)
- relayout + immediateRelayout → immediateRelayout (upgrades)
- Empty queue enqueue → becomes pending
- Cancel active → active cleared

Each test should verify: resulting `kind`, `affectedWorkspaceIds` merging, `postLayoutActions` accumulation.

- [ ] **Step 2: Build + run tests**

Run: `swift build -c debug && swift test --filter 'RefreshQueueManager' 2>&1 | tail -15`

Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/OmniWMTests/RefreshQueueManagerTests.swift
git commit -m "test: add merge matrix tests for RefreshQueueManager (Extraction 2)

25+ test cases covering all (existingKind, incomingKind) merge pairs.
Verifies kind priority, workspace ID merging, postLayoutActions,
followUpRefresh chaining, and preserveCancelledRefreshState.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Wire up LayoutRefreshController to use RefreshQueueManager

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/LayoutRefreshController.swift`

- [ ] **Step 1: Add queueManager property**

Add to LayoutRefreshController (near `controller` property, around line 103):

```swift
private(set) var queueManager: RefreshQueueManager?
```

- [ ] **Step 2: Initialize in setup or init**

Find where LayoutRefreshController is initialized/set up. Create the queue manager with executor and completion closures:

```swift
queueManager = RefreshQueueManager(
    executor: { [weak self] refresh in
        guard let self else { return false }
        return await self.executeRefresh(refresh)
    },
    onComplete: { [weak self] refresh, completed in
        self?.finishRefresh(refresh, didComplete: completed)
    }
)
```

Where `executeRefresh` is the existing execution dispatch that calls `executeFullRescan`, `executeRelayout`, etc.

- [ ] **Step 3: Replace direct queue access with queueManager calls**

In LayoutRefreshController, replace:
- `enqueueRefresh(refresh)` → `queueManager?.enqueue(refresh)`
- `layoutState.activeRefresh` reads → `queueManager?.activeRefresh`
- `layoutState.pendingRefresh` reads → `queueManager?.pendingRefresh`
- `layoutState.activeRefreshTask?.cancel()` → `queueManager?.cancelActiveTask()`

- [ ] **Step 4: Remove moved code from LayoutRefreshController**

Remove these methods (now in RefreshQueueManager):
- `enqueueRefresh`
- `handleRefresh`
- `mergePendingRefresh`
- `absorbIntoActiveFullRescan`
- `startNextRefreshIfNeeded`
- `preserveCancelledRefreshState`
- `mergeWindowRemovalPayloads`
- `mergedAffectedWorkspaceIds`
- `mergeFollowUp`
- `mergeAbsorbedVisibility`
- `mergeFollowUpRefresh`
- `recordRefreshRequest` and `recordRefreshExecution` (if moved)

Remove from LayoutState:
- `activeRefresh`
- `pendingRefresh`
- `activeRefreshTask`

- [ ] **Step 5: Build + run all related tests**

Run: `swift build -c debug 2>&1 | tail -5`
Run: `swift test --filter 'RefreshQueueManager|LayoutRefreshController|RefreshRouting' 2>&1 | grep -E '✔|✘|Test run' | tail -10`

Expected: Build succeeds. All tests pass.

- [ ] **Step 6: Format + lint**

Run: `make format-check 2>&1 | tail -3 && make lint 2>&1 | tail -5`

Fix any issues.

- [ ] **Step 7: CodeRabbit review BEFORE commit**

Dispatch CodeRabbit reviewer on `git diff`.

- [ ] **Step 8: Commit**

```bash
git add Sources/OmniWM/Core/Controller/LayoutRefreshController.swift Sources/OmniWM/Core/Controller/RefreshQueueManager.swift
git commit -m "refactor: wire LayoutRefreshController to use RefreshQueueManager (Extraction 2)

Queue state (activeRefresh, pendingRefresh, activeRefreshTask) and
all merge/dispatch logic now owned by RefreshQueueManager.
LayoutRefreshController provides executor closure + completion callback.
Removed ~350 lines from LayoutRefreshController.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Verification + deploy + persistence sync

- [ ] **Step 1: Graphify update + verify**

Run: `graphify update Sources/ 2>&1 | tail -3 && graphify explain "RefreshQueueManager" --graph Sources/graphify-out/graph.json 2>&1 && graphify explain "LayoutRefreshController" --graph Sources/graphify-out/graph.json 2>&1 | head -5`

Expected: RefreshQueueManager node exists. LayoutRefreshController degree decreased.

- [ ] **Step 2: Deploy + runtime verify**

Run: `pkill -x OmniWM; sleep 2; swift build -c debug && .build/debug/OmniWM & sleep 3 && pgrep -x OmniWM && .build/debug/omniwmctl ping`

Expected: PID exists, pong.

- [ ] **Step 3: 30s log stream**

Run: `/usr/bin/log stream --predicate 'subsystem == "com.omniwm"' --info --debug --style compact --timeout 30 2>/dev/null | grep -iE 'error|crash' | head -10; echo "---done"`

Expected: 0 errors.

- [ ] **Step 4: Update ALL 9 persistence systems**

Memorygraph, Serena mem:core, Memory MCP, CLAUDE.md, evaluation, next-session, MEMORY.md, Graphify (done in step 1), hooks (no change needed).
