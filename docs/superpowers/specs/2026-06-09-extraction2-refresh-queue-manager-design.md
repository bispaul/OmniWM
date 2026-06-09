# Extraction 2: RefreshQueueManager — Design Spec

## Goal

Extract the refresh queue state machine (merge matrix + queue dispatch) from LayoutRefreshController into a standalone, unit-testable `RefreshQueueManager`. Ship with 25+ merge matrix tests that encode the implicit invariants developers got wrong (two reverts).

## Why standalone class (not private methods)

Expert panel (architect + devil's advocate) agreed:
- Merge matrix is pure logic — 141 lines, 5 helpers, zero `self` access
- Queue state is self-contained — 3 fields (`activeRefresh`, `pendingRefresh`, `activeRefreshTask`)
- 0 test coverage today — unit testing IS the primary motivation
- Different from Extraction 1 — that was a sequential pipeline coupled to controller state; this is a self-contained state machine

## Boundary

**Moves to RefreshQueueManager:**
- Queue state: `activeRefresh`, `pendingRefresh`, `activeRefreshTask`
- `enqueueRefresh` (orchestrator)
- `handleRefresh` (active-vs-incoming dispatch + cancel decision)
- `mergePendingRefresh` (141-line merge matrix)
- `absorbIntoActiveFullRescan`
- `preserveCancelledRefreshState`
- All 5 merge helpers (`mergeAbsorbedVisibility`, `mergedAffectedWorkspaceIds`, `mergeFollowUp`, `mergeWindowRemovalPayloads`, `mergeFollowUpRefresh`)
- `startNextRefreshIfNeeded` (creates Task, calls executor closure)
- Debug counters (`recordRefreshRequest`, `recordRefreshExecution`)

**Stays on LayoutRefreshController:**
- `execute()` dispatch to 5 `execute*` methods — provided as closure to manager
- `finishRefresh` — called by manager via completion callback
- `performVisibilitySideEffects`
- `resetState`, `waitForRefreshWorkForTests` — thin wrappers

## Design

```swift
@MainActor
final class RefreshQueueManager {
    typealias Executor = (ScheduledRefresh) async -> Bool
    typealias CompletionHandler = (ScheduledRefresh, Bool) -> Void

    private(set) var activeRefresh: ScheduledRefresh?
    private(set) var pendingRefresh: ScheduledRefresh?
    private var activeRefreshTask: Task<Void, Never>?

    private let executor: Executor
    private let onComplete: CompletionHandler

    init(executor: @escaping Executor, onComplete: @escaping CompletionHandler)

    func enqueue(_ refresh: ScheduledRefresh)
    func cancelActive()
    func reset()
}
```

LayoutRefreshController creates the manager in init:
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

## Testing (merged from Extraction 5)

New file: `Tests/OmniWMTests/RefreshQueueManagerTests.swift`

- 25 merge matrix cases: each `(existingKind, incomingKind)` pair verifies resulting kind, workspace ID merging, postLayoutActions accumulation, followUpRefresh chaining
- `preserveCancelledRefreshState` cases (involved in reverts)
- Empty queue enqueue/dequeue
- Cancel active
- Deferred: queue lifecycle integration tests with mock executor (Extraction 5)

## What does NOT change

- `ScheduledRefresh` struct — unchanged
- `RefreshReason` enum — unchanged
- `execute*` methods — stay on LayoutRefreshController
- Public API of LayoutRefreshController — callers use same `requestRelayout`, `requestImmediateRelayout`, etc.

## Risk: LOW

All extracted code is pure functions over value types or thin state management. Controller boundary is one closure + one callback. No delegate protocols.

## Estimated size

- `RefreshQueueManager.swift`: ~350 lines
- `RefreshQueueManagerTests.swift`: ~200 lines
- LayoutRefreshController delta: -350, +40 (thin dispatchers)
