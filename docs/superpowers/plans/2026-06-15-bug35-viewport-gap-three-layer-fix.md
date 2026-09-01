# Bug #35 Three-Layer Viewport Gap Fix

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate viewport gap on Caps+H/L navigation by porting upstream's revision system, aligning focusNeighbor with upstream, and verifying hotkey dispatch path.

**Architecture:** Three-layer fix: (1) Port upstream's RuntimeRevision stale-patch rejection system — prevents ANY async layout pass from overwriting viewport state with stale data. (2) Align focusNeighbor's activateNode options with upstream (`layoutRefresh:false, axFocus:false`) + port `requestSelectedWindowFocusAfterLayout`. (3) Verify whether virtual hyper async dispatch contributes to the race and fix if needed.

**Tech Stack:** Swift 6.3, @MainActor concurrency, Apple Testing framework

**Root cause:** Expert subagent analysis (architect + debugger + devil's advocate) identified: (a) fork stripped upstream's RuntimeRevision system — applySessionPatch has zero stale-patch guards, (b) focusNeighbor uses `layoutRefresh:true` (upstream uses `false`), (c) virtual hyper dispatch is async, creating a timing window. Memorygraph `98f505a4`.

**Constraints:**
- Preserve Phase 1-5 + Fix A-E + SSOT invariants
- Preserve F7 frame coalescing (`animate:false` in resolveSelection)
- No god node coupling increase (WM already 248 edges)
- `swift test --filter` only — never unfiltered on active desktop

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `Sources/OmniWM/Core/Runtime/RuntimeRevision.swift` | RuntimeRevisionDomain OptionSet + RuntimeRevision struct |
| Modify | `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift` | Add revision counters, bump/check methods, update applySessionPatch guards |
| Modify | `Sources/OmniWM/Core/Layout/Niri/ViewportState.swift` | Add `selectionRevision: UInt64` field |
| Modify | `Sources/OmniWM/Core/Layout/LayoutBoundary.swift` | Add runtimeRevision to WorkspaceSessionPatch + snapshots |
| Modify | `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift` | Thread runtimeRevision through layout pipeline, port requestSelectedWindowFocusAfterLayout, align focusNeighbor |
| Modify | `Sources/OmniWM/Core/Controller/DwindleLayoutHandler.swift` | Thread runtimeRevision through patches |
| Modify | `Sources/OmniWM/Core/Controller/LayoutRefreshController.swift` | Add postLayoutDomains param, port requestLayoutCommandRelayout |
| Modify | `Sources/OmniWM/Core/Input/Hotkeys.swift` | Verify/fix virtual hyper dispatch (Layer 1) |
| Create | `Tests/OmniWMTests/RuntimeRevisionTests.swift` | Revision matching + staleness tests |
| Modify | `Tests/OmniWMTests/ViewportPipelineTests.swift` | focusNeighbor gap regression test |

---

### Task 1: RuntimeRevision Types

**Files:**
- Create: `Sources/OmniWM/Core/Runtime/RuntimeRevision.swift`

- [ ] **Step 1: Write failing test for RuntimeRevision matching**

Create `Tests/OmniWMTests/RuntimeRevisionTests.swift`:

```swift
import Testing
@testable import OmniWM

@Suite struct RuntimeRevisionTests {
    @Test func matchingRevisionsReturnTrue() {
        let rev = RuntimeRevision(runtime: 1, workspace: 2, layout: 3, focus: 4, fullscreen: 5)
        #expect(rev.matches(rev, domains: .layoutCommit))
    }

    @Test func mismatchedLayoutReturnsFalse() {
        let rev1 = RuntimeRevision(runtime: 1, workspace: 2, layout: 3, focus: 4, fullscreen: 5)
        let rev2 = RuntimeRevision(runtime: 1, workspace: 2, layout: 99, focus: 4, fullscreen: 5)
        #expect(!rev1.matches(rev2, domains: .layoutCommit))
    }

    @Test func mismatchedFocusIgnoredByLayoutCommit() {
        let rev1 = RuntimeRevision(runtime: 1, workspace: 2, layout: 3, focus: 4, fullscreen: 5)
        let rev2 = RuntimeRevision(runtime: 1, workspace: 2, layout: 3, focus: 99, fullscreen: 5)
        #expect(rev1.matches(rev2, domains: .layoutCommit))
    }

    @Test func focusCommitChecksFocusDomain() {
        let rev1 = RuntimeRevision(runtime: 1, workspace: 2, layout: 3, focus: 4, fullscreen: 5)
        let rev2 = RuntimeRevision(runtime: 1, workspace: 2, layout: 3, focus: 99, fullscreen: 5)
        #expect(!rev1.matches(rev2, domains: .focusCommit))
    }
}
```

Run: `swift test --filter RuntimeRevisionTests`
Expected: FAIL — types don't exist yet

- [ ] **Step 2: Implement RuntimeRevision types**

Create `Sources/OmniWM/Core/Runtime/RuntimeRevision.swift`:

```swift
struct RuntimeRevisionDomain: OptionSet {
    let rawValue: UInt8

    static let workspace = RuntimeRevisionDomain(rawValue: 1 << 0)
    static let layout = RuntimeRevisionDomain(rawValue: 1 << 1)
    static let focus = RuntimeRevisionDomain(rawValue: 1 << 2)
    static let fullscreen = RuntimeRevisionDomain(rawValue: 1 << 3)

    static let layoutCommit: RuntimeRevisionDomain = [.workspace, .layout, .fullscreen]
    static let focusCommit: RuntimeRevisionDomain = .focus
}

struct RuntimeRevision: Equatable {
    let runtime: UInt64
    let workspace: UInt64
    let layout: UInt64
    let focus: UInt64
    let fullscreen: UInt64

    func matches(_ other: RuntimeRevision, domains: RuntimeRevisionDomain) -> Bool {
        if domains.contains(.workspace), workspace != other.workspace { return false }
        if domains.contains(.layout), layout != other.layout { return false }
        if domains.contains(.focus), focus != other.focus { return false }
        if domains.contains(.fullscreen), fullscreen != other.fullscreen { return false }
        return true
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter RuntimeRevisionTests`
Expected: 4/4 PASS

- [ ] **Step 4: Commit**

```
feat: add RuntimeRevision types (upstream port for stale-patch rejection)
```

---

### Task 2: ViewportState selectionRevision + WorkspaceSessionPatch runtimeRevision

**Files:**
- Modify: `Sources/OmniWM/Core/Layout/Niri/ViewportState.swift:168` — add `selectionRevision`
- Modify: `Sources/OmniWM/Core/Layout/LayoutBoundary.swift` — add fields to WorkspaceSessionPatch + snapshots

- [ ] **Step 1: Add selectionRevision to ViewportState**

In `ViewportState.swift`, add after `var requiresViewportRecalc: Bool = false` (~line 168):

```swift
var selectionRevision: UInt64 = 0
```

- [ ] **Step 2: Add runtimeRevision to WorkspaceSessionPatch**

In `LayoutBoundary.swift`, modify `struct WorkspaceSessionPatch`:

```swift
struct WorkspaceSessionPatch {
    let workspaceId: WorkspaceDescriptor.ID
    var viewportState: ViewportState?
    var rememberedFocusToken: WindowToken?
    var baseSelectionRevision: UInt64? = nil
    var runtimeRevision: RuntimeRevision
}
```

- [ ] **Step 3: Add runtimeRevision to NiriWorkspaceSnapshot and DwindleWorkspaceSnapshot**

Find struct `NiriWorkspaceSnapshot` in LayoutBoundary.swift and add:
```swift
let runtimeRevision: RuntimeRevision
```

Find struct `DwindleWorkspaceSnapshot` and add:
```swift
let runtimeRevision: RuntimeRevision
```

- [ ] **Step 4: Fix all compilation errors from new required fields**

Every `WorkspaceSessionPatch(...)` creation site needs `runtimeRevision:` parameter.
Every `NiriWorkspaceSnapshot(...)` and `DwindleWorkspaceSnapshot(...)` creation site needs `runtimeRevision:`.

For each: pass `controller.workspaceManager.runtimeRevision(for: workspaceId)` — but this method doesn't exist yet. Add a temporary stub to WorkspaceManager:

```swift
func runtimeRevision(for workspaceId: WorkspaceDescriptor.ID) -> RuntimeRevision {
    RuntimeRevision(runtime: 0, workspace: 0, layout: 0, focus: 0, fullscreen: 0)
}
```

Fix ALL 5 WorkspaceSessionPatch creation sites (2 in DwindleLayoutHandler, 2 in NiriLayoutHandler, plus the focusNeighbor applySessionPatch).
Fix ALL snapshot creation sites.

- [ ] **Step 5: Build + run existing tests**

Run: `swift build -c debug`
Run: `swift test --filter ViewportPipelineTests`
Expected: All pass (stub revision returns zero, matches everything)

- [ ] **Step 6: Commit**

```
feat: add selectionRevision + runtimeRevision fields (stub, no guards yet)
```

---

### Task 3: WorkspaceManager Revision Tracking Infrastructure

**Files:**
- Modify: `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift`

- [ ] **Step 1: Add revision counter fields**

After `var onSessionStateChanged: (() -> Void)?` (~line 234), add:

```swift
var onRuntimeRevisionChanged: ((WorkspaceDescriptor.ID?, RuntimeRevisionDomain) -> Void)?
private var runtimeRevisionSerial: UInt64 = 0
private var globalWorkspaceRevision: UInt64 = 0
private var globalLayoutRevision: UInt64 = 0
private var globalFocusRevision: UInt64 = 0
private var globalFullscreenRevision: UInt64 = 0
private var workspaceRevisions: [WorkspaceDescriptor.ID: UInt64] = [:]
private var layoutRevisions: [WorkspaceDescriptor.ID: UInt64] = [:]
private var focusRevisions: [WorkspaceDescriptor.ID: UInt64] = [:]
private var fullscreenRevisions: [WorkspaceDescriptor.ID: UInt64] = [:]
```

- [ ] **Step 2: Replace runtimeRevision stub with real implementation**

Replace the stub from Task 2 with:

```swift
func runtimeRevision(for workspaceId: WorkspaceDescriptor.ID) -> RuntimeRevision {
    RuntimeRevision(
        runtime: runtimeRevisionSerial,
        workspace: workspaceRevisions[workspaceId, default: 0],
        layout: layoutRevisions[workspaceId, default: 0],
        focus: focusRevisions[workspaceId, default: 0],
        fullscreen: fullscreenRevisions[workspaceId, default: 0]
    )
}
```

- [ ] **Step 3: Add bump + check methods**

```swift
func isRuntimeRevisionCurrent(
    _ revision: RuntimeRevision,
    for workspaceId: WorkspaceDescriptor.ID,
    domains: RuntimeRevisionDomain
) -> Bool {
    guard workspacesById[workspaceId] != nil else { return false }
    return revision.matches(runtimeRevision(for: workspaceId), domains: domains)
}

func invalidateLayoutRevision(for workspaceIds: Set<WorkspaceDescriptor.ID>) {
    for workspaceId in workspaceIds {
        bumpRuntimeRevision(for: workspaceId, domains: .layout)
    }
}

private func bumpRuntimeRevision(
    for workspaceId: WorkspaceDescriptor.ID?,
    domains: RuntimeRevisionDomain
) {
    runtimeRevisionSerial &+= 1
    guard let workspaceId else {
        for wsId in workspacesById.keys {
            bumpRuntimeRevisionDomains(for: wsId, domains: domains)
        }
        onRuntimeRevisionChanged?(nil, domains)
        return
    }
    bumpRuntimeRevisionDomains(for: workspaceId, domains: domains)
    onRuntimeRevisionChanged?(workspaceId, domains)
}

private func bumpRuntimeRevisionDomains(
    for workspaceId: WorkspaceDescriptor.ID,
    domains: RuntimeRevisionDomain
) {
    if domains.contains(.workspace) {
        globalWorkspaceRevision &+= 1
        workspaceRevisions[workspaceId, default: 0] &+= 1
    }
    if domains.contains(.layout) {
        globalLayoutRevision &+= 1
        layoutRevisions[workspaceId, default: 0] &+= 1
    }
    if domains.contains(.focus) {
        globalFocusRevision &+= 1
        focusRevisions[workspaceId, default: 0] &+= 1
    }
    if domains.contains(.fullscreen) {
        globalFullscreenRevision &+= 1
        fullscreenRevisions[workspaceId, default: 0] &+= 1
    }
}
```

- [ ] **Step 4: Wire bumpRuntimeRevision into recordReconcileEvent**

In the existing `recordReconcileEvent(_ event: WMEvent)` method, add `bumpRuntimeRevision(for: event)` call. This is the SINGLE point where state changes are recorded — it already exists, we just add the revision bump.

Add a private method that maps WMEvent to domains:

```swift
private func bumpRuntimeRevision(for event: WMEvent) {
    switch event {
    case let .windowAdmitted(_, workspaceId, _, _, _),
         let .windowModeChanged(_, workspaceId, _, _, _),
         let .hiddenStateChanged(_, workspaceId, _, _, _),
         let .managedReplacementMetadataChanged(_, workspaceId, _, _):
        bumpRuntimeRevision(for: workspaceId, domains: [.workspace, .layout, .focus])
    case let .floatingGeometryUpdated(_, workspaceId, _, _, _, _):
        bumpRuntimeRevision(for: workspaceId, domains: [.workspace, .layout])
    case let .windowRekeyed(_, _, workspaceId, _, _, _):
        bumpRuntimeRevision(for: workspaceId, domains: [.workspace, .layout, .focus])
    case let .workspaceAssigned(_, _, toWorkspaceId, _, _):
        bumpRuntimeRevision(for: toWorkspaceId, domains: [.workspace, .layout, .focus])
    default:
        break
    }
}
```

Note: Match the exact WMEvent cases from upstream. Some cases may differ — check all cases in fork's WMEvent enum and map the relevant ones.

- [ ] **Step 5: Build + test**

Run: `swift build -c debug`
Run: `swift test --filter RuntimeRevisionTests`
Expected: Pass

- [ ] **Step 6: Commit**

```
feat: add revision tracking infrastructure to WorkspaceManager (upstream port)
```

---

### Task 4: applySessionPatch Stale-Patch Guards

**Files:**
- Modify: `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift` — update applySessionPatch
- Modify: `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift` — update updateNiriViewportState

- [ ] **Step 1: Write failing test for stale patch rejection**

Add to `RuntimeRevisionTests.swift`:

```swift
@Test @MainActor func applySessionPatchRejectsStaleRevision() {
    let controller = makeLayoutPlanTestController()
    controller.enableNiriLayout()

    guard let workspaceId = controller.workspaceManager.monitors.first
        .flatMap({ controller.workspaceManager.activeWorkspaceOrFirst(on: $0.id)?.id })
    else {
        Issue.record("Missing workspace")
        return
    }

    let rev = controller.workspaceManager.runtimeRevision(for: workspaceId)

    // Bump revision (simulates intervening state change)
    controller.workspaceManager.invalidateLayoutRevision(for: [workspaceId])

    // Now the captured revision is stale
    let applied = controller.workspaceManager.applySessionPatch(
        .init(
            workspaceId: workspaceId,
            viewportState: ViewportState(),
            runtimeRevision: rev
        )
    )
    #expect(!applied, "Stale patch should be rejected")
}
```

Run: `swift test --filter applySessionPatchRejectsStaleRevision`
Expected: FAIL (current applySessionPatch has no guards)

- [ ] **Step 2: Add revision guards to applySessionPatch**

Replace the current `applySessionPatch` with:

```swift
func applySessionPatch(_ patch: WorkspaceSessionPatch) -> Bool {
    guard isRuntimeRevisionCurrent(
        patch.runtimeRevision,
        for: patch.workspaceId,
        domains: .layoutCommit
    ) else {
        return false
    }

    var changed = false

    if var viewportState = patch.viewportState {
        let currentState = niriViewportState(for: patch.workspaceId)
        let patchHasStaleSelection = patch.baseSelectionRevision
            .map { $0 < currentState.selectionRevision } ?? false
        if patchHasStaleSelection {
            viewportState.selectedNodeId = currentState.selectedNodeId
            viewportState.activeColumnIndex = currentState.activeColumnIndex
            viewportState.selectionProgress = currentState.selectionProgress
            viewportState.selectionRevision = currentState.selectionRevision
        }
        if viewportState.viewOffsetPixels.isGesture {
            if case .spring = currentState.viewOffsetPixels {
                viewportState.viewOffsetPixels = currentState.viewOffsetPixels
                viewportState.activeColumnIndex = currentState.activeColumnIndex
            }
        }
        updateNiriViewportState(viewportState, for: patch.workspaceId)
        changed = true
    }

    if let rememberedFocusToken = patch.rememberedFocusToken {
        if isRuntimeRevisionCurrent(
            patch.runtimeRevision,
            for: patch.workspaceId,
            domains: .focusCommit
        ) {
            changed = rememberFocus(rememberedFocusToken, in: patch.workspaceId) || changed
        }
    }

    return changed
}
```

- [ ] **Step 3: Add selectionRevision tracking to updateNiriViewportState**

Replace the current `updateNiriViewportState` with:

```swift
func updateNiriViewportState(
    _ state: ViewportState,
    for workspaceId: WorkspaceDescriptor.ID
) {
    var workspaceSession = sessionState.workspaceSessions[workspaceId] ?? SessionState.WorkspaceSession()
    let currentState = workspaceSession.niriViewportState
    var nextState = state
    if let currentState {
        if nextState.selectedNodeId != currentState.selectedNodeId {
            nextState.selectionRevision = max(nextState.selectionRevision, currentState.selectionRevision &+ 1)
        } else {
            nextState.selectionRevision = max(nextState.selectionRevision, currentState.selectionRevision)
        }
    } else if nextState.selectedNodeId != nil {
        nextState.selectionRevision = max(nextState.selectionRevision, 1)
    }
    workspaceSession.niriViewportState = nextState
    sessionState.workspaceSessions[workspaceId] = workspaceSession
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter RuntimeRevisionTests`
Run: `swift test --filter ViewportPipelineTests`
Expected: All pass

- [ ] **Step 5: Commit**

```
feat: add stale-patch guards to applySessionPatch (upstream revision system)
```

---

### Task 5: requestLayoutCommandRelayout + focusNeighbor Alignment (Layer 3)

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift` — add helpers, fix focusNeighbor
- Modify: `Sources/OmniWM/Core/Controller/LayoutRefreshController.swift` — add requestLayoutCommandRelayout

- [ ] **Step 1: Write failing test for focusNeighbor gap**

The test from `ViewportPipelineTests.swift` already exists (`focusNeighborWritesSpringBeforeRelayout`). Verify it captures the correct behavior — after focusNeighbor, the viewport should shift to show the newly focused column without leaving a gap.

- [ ] **Step 2: Add requestLayoutCommandRelayout to LayoutRefreshController**

```swift
func requestLayoutCommandRelayout(
    affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
    postLayout: PostLayoutAction? = nil
) {
    controller?.workspaceManager.invalidateLayoutRevision(for: affectedWorkspaceIds)
    requestImmediateRelayout(
        reason: .layoutCommand,
        affectedWorkspaceIds: affectedWorkspaceIds,
        postLayout: postLayout
    )
}
```

- [ ] **Step 3: Add requestSelectedWindowFocusAfterLayout to NiriLayoutHandler**

Add before `func toggleFullscreen()`:

```swift
private func requestSelectedWindowFocusAfterLayout(in workspaceId: WorkspaceDescriptor.ID) {
    controller?.layoutRefreshController.requestLayoutCommandRelayout(
        affectedWorkspaceIds: [workspaceId]
    ) { [weak controller] in
        guard let controller else { return }
        let viewportState = controller.workspaceManager.niriViewportState(for: workspaceId)
        guard let selectedNodeId = viewportState.selectedNodeId,
              let selectedWindow = controller.niriEngine?.findNode(by: selectedNodeId) as? NiriWindow,
              controller.workspaceManager.entry(for: selectedWindow.token)?.workspaceId == workspaceId
        else { return }
        controller.focusWindow(selectedWindow.token)
    }
}
```

- [ ] **Step 4: Align focusNeighbor with upstream**

In `focusNeighbor`, replace the success path:

```swift
if let newNode = engine.focusTarget(
    direction: direction,
    currentSelection: currentNode,
    in: wsId,
    motion: controller.motionPolicy.snapshot(),
    state: &state,
    workingFrame: workingFrame,
    gaps: gap
) {
    WMLog.focus
        .debug(
            "focusNeighbor: direction=\(String(describing: direction), privacy: .public) currentNode=\(String(describing: currentId), privacy: .public) targetNode=\(String(describing: newNode.id), privacy: .public)"
        )
    activateNode(
        newNode, in: wsId, state: &state,
        options: .init(
            activateWindow: false,
            ensureVisible: false,
            layoutRefresh: false,
            axFocus: false
        )
    )
    _ = controller.workspaceManager.applySessionPatch(
        .init(
            workspaceId: wsId,
            viewportState: state,
            rememberedFocusToken: nil,
            runtimeRevision: controller.workspaceManager.runtimeRevision(for: wsId)
        )
    )
    requestSelectedWindowFocusAfterLayout(in: wsId)
    startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
}
```

Remove the `applySessionPatch` that was OUTSIDE the if-block (it only applied for the no-navigation-happened case, which is now handled by the early return path that already has its own applySessionPatch).

- [ ] **Step 5: Build + test**

Run: `swift build -c debug`
Run: `swift test --filter ViewportPipelineTests`
Run: `swift test --filter SelectiveAnimationTests`
Run: `swift test --filter NiriLayoutEngineTests`
Expected: All pass

- [ ] **Step 6: Commit**

```
fix(#35): align focusNeighbor with upstream — layoutRefresh:false + requestSelectedWindowFocusAfterLayout
```

---

### Task 6: Virtual Hyper Dispatch Verification (Layer 1)

**Files:**
- Modify: `Sources/OmniWM/Core/Input/Hotkeys.swift` (if needed)

- [ ] **Step 1: Verify which hotkey path the user's Caps+L takes**

The user has Karabiner remapping Caps Lock → Cmd+Ctrl+Opt+Shift (Hyper). Check if OmniWM receives the hotkey through:
a) Carbon hotkeys (synchronous) — Karabiner sends modifier+key, Carbon matches
b) Virtual hyper state machine (async) — OmniWM's internal CapsLock detection

Add temporary log to both paths:
- In `handleVirtualHyperKeyDown` at line 770: `WMLog.input.debug("VIRTUAL-HYPER-PATH")`
- In Carbon hotkey callback: check existing `Hotkey command dispatched` log

Deploy, press Caps+L, check which log fires.

- [ ] **Step 2: If virtual hyper path is used, evaluate sync dispatch**

If `VIRTUAL-HYPER-PATH` fires: the async `DispatchQueue.main.async` in `dispatchVirtualHyperActionLater` creates a timing window.

Check upstream — upstream ALSO uses `DispatchQueue.main.async` at the same location. So upstream has the same async dispatch. The difference is upstream's revision system (Task 4) rejects stale patches that arrive during the async window.

With our revision system in place (Tasks 1-4), the async dispatch is safe — stale patches get rejected. No code change needed for Layer 1.

- [ ] **Step 3: Remove temporary logs, commit**

```
chore: verify virtual hyper dispatch path — revision system handles async safety
```

---

### Task 7: Integration Test + Deploy

**Files:**
- Modify: `Tests/OmniWMTests/ViewportPipelineTests.swift`

- [ ] **Step 1: Run full test suite**

```bash
swift test --filter "ViewportPipelineTests|SelectiveAnimationTests|NiriLayoutEngineTests|RuntimeRevisionTests|RefreshRoutingTests"
```

Expected: All pass (except pre-existing test #2 `sameMonitorWorkspaceSwitchSkipsAnimationWhenTargetWasHidden`)

- [ ] **Step 2: Format + lint**

```bash
make format-check
make lint
```

Expected: 0 files need formatting, 0 serious lint violations

- [ ] **Step 3: Build signed binary + deploy**

```bash
make build-sign
kill $(pgrep -x OmniWM)
sleep 1
.build/debug/OmniWM &
sleep 2
omniwmctl ping
```

- [ ] **Step 4: Reproduce gap test**

```bash
# Navigate R L R L R on WS8 via IPC
omniwmctl command focus right; sleep 1.5
omniwmctl command focus left; sleep 1.5
omniwmctl command focus right; sleep 1.5
omniwmctl command focus left; sleep 1.5
omniwmctl command focus right; sleep 1.5

# Check positions — should be correct (no 1275px gap)
omniwmctl query windows | python3 -c "..."
```

- [ ] **Step 5: Ask user to test Caps+H/L on WS8**

User tests keyboard navigation. Capture logs during test. Verify no gap.

- [ ] **Step 6: Update CLAUDE.md + persistence systems**

Update Bug #35 status to FIXED in CLAUDE.md Status Dashboard.
Update memorygraph, Serena, dotfiles memory.

- [ ] **Step 7: Commit all changes**

```
fix(#35): three-layer viewport gap fix — revision system + focusNeighbor alignment
```
