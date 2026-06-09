# Extraction 4: ManagedReplacementCorrelator — Design Spec

## Goal

Extract managed replacement burst correlation from AXEventHandler into a standalone class. Reduces AXEventHandler from 3,557 to ~2,900 lines. Gives managed replacement an independent identity for testing and upstream contribution.

## Why standalone class

- 9 private types + 4 state fields + Task-based scheduling = stateful component
- 77% pure methods (matching logic) — directly unit-testable once extracted
- Private methods can't move types or state out of AXEventHandler
- Expert panel validated: one pipeline (enqueue → burst → flush → match → rekey/replay), splitting creates artificial seams

## Boundary

**Moves to ManagedReplacementCorrelator:**
- 9 type definitions (ManagedReplacementKey, PendingManagedReplacementBurst, MatchedManagedReplacementPair, etc.)
- 4 state fields (pendingBursts, pendingTasks, nextSequence, trace)
- ~35 methods: pure matching (11), lifecycle (8), metadata building (7), helpers (9)
- Task-based scheduling (scheduleManagedReplacementFlush)
- ForTests hooks (timeSourceForTests, windowExistsInWindowServerForTests)

**Stays on AXEventHandler:**
- `updateManagedReplacementFrame/Title` (thin forwarding to workspaceManager)
- `refreshBorderAfterManagedRekey` (UI concern)
- `managedReplacementFacts` (AX query)
- `prepareDestroyCandidate` (builds PreparedDestroy)
- Delegate conformance (7 implementations)
- Test forwarding: `flushPendingManagedReplacementEventsForTests` → `correlator.flushForTests()`

## Delegate Protocol

```swift
@MainActor
protocol ManagedReplacementCorrelatorDelegate: AnyObject {
    // Actions (called during flush)
    func correlatorRekeyReplacement(from oldToken: WindowToken, to create: PreparedCreate) -> Bool
    func correlatorReplayCreate(_ create: PreparedCreate)
    func correlatorReplayDestroy(pid: pid_t, windowId: UInt32)
    func correlatorShouldSuppressDestroyReplay(windowId: UInt32) -> Bool

    // Queries (called during structural matching)
    func correlatorActiveWorkspaceId() -> WorkspaceDescriptor.ID?
    func correlatorEntriesForPid(_ pid: pid_t) -> [TrackedWindowEntry]
    func correlatorWindowInfo(windowId: UInt32) -> SkyLightWindowInfo?
}
```

## Design

```swift
@MainActor
final class ManagedReplacementCorrelator {
    weak var delegate: ManagedReplacementCorrelatorDelegate?

    // State
    private var pendingBursts: [ManagedReplacementKey: PendingManagedReplacementBurst] = [:]
    private var pendingTasks: [ManagedReplacementKey: Task<Void, Never>] = [:]
    private var nextSequence: UInt64 = 0
    private var trace: [ManagedReplacementTraceEvent] = []

    // Public API
    func enqueueCreate(_ candidate: PreparedCreate, ...)
    func enqueueDestroy(_ candidate: PreparedDestroy, ...)
    func rekeyIfNeeded(token:windowId:axRef:bundleId:mode:facts:) -> Bool
    func reset()
    func flushForTests()
    func traceSnapshotForTests() -> [ManagedReplacementTraceEvent]
}
```

## Test migration

Zero test file changes — AXEventHandler keeps forwarding methods:
```swift
func flushPendingManagedReplacementEventsForTests() {
    managedReplacementCorrelator?.flushForTests()
}
```

## Estimated size

- ManagedReplacementCorrelator.swift: ~650 lines
- AXEventHandler delta: -650 lines, +30 delegate + forwarding = -620 net
- AXEventHandler: 3,557 → ~2,937 lines

## Risk: MEDIUM

Largest extraction. 7-method delegate protocol. Re-entrancy safe (burst removed before replay). Mitigated by 77% pure methods and zero test file changes.
