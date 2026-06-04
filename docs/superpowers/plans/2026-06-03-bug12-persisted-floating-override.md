# Bug #12 Fix: Respect Explicit Rule Decisions in Persisted Hydration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent `planPersistedHydration` from overriding the window rule engine's explicit tiling decision with a stale persisted `restoreToFloating` flag.

**Architecture:** Add `layoutDecisionKind` to `ManagedReplacementMetadata` so the rule engine's decision survives through the reconciliation pipeline. In `planPersistedHydration`, when `layoutDecisionKind == .explicitLayout`, ignore the persisted `restoreToFloating` flag.

**Tech Stack:** Swift 6.2, Apple Testing framework, os.Logger

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Sources/OmniWM/Core/Workspace/WindowModel.swift` | Modify | Add `layoutDecisionKind` field to `ManagedReplacementMetadata` |
| `Sources/OmniWM/Core/Controller/AXEventHandler.swift` | Modify | Pass `layoutDecisionKind` through `makeManagedReplacementMetadata` |
| `Sources/OmniWM/Core/Reconcile/RestorePlanner.swift` | Modify | Skip `restoreToFloating` when `explicitLayout` |
| `Tests/OmniWMTests/RestorePlannerTests.swift` | Modify | Add 2 new tests |

---

### Task 1: Write Failing Tests

**Files:**
- Modify: `Tests/OmniWMTests/RestorePlannerTests.swift`

- [ ] **Step 1: Update test helper to accept `layoutDecisionKind`**

In `RestorePlannerTests.swift`, update the `makeRestorePlannerMetadata` helper to accept the new field:

```swift
private func makeRestorePlannerMetadata(
    bundleId: String? = "com.example.editor",
    workspaceId: WorkspaceDescriptor.ID = WorkspaceDescriptor.ID(),
    mode: TrackedWindowMode = .tiling,
    title: String? = "Document",
    frame: CGRect? = nil,
    layoutDecisionKind: WindowDecisionLayoutKind = .fallbackLayout
) -> ManagedReplacementMetadata {
    ManagedReplacementMetadata(
        bundleId: bundleId,
        workspaceId: workspaceId,
        mode: mode,
        role: "AXWindow",
        subrole: "AXStandardWindow",
        title: title,
        windowLevel: 0,
        parentWindowId: nil,
        frame: frame,
        layoutDecisionKind: layoutDecisionKind
    )
}
```

- [ ] **Step 2: Add test — explicit rule overrides persisted floating flag**

Add at the end of `struct RestorePlannerTests`, before the closing `}`:

```swift
    @Test func explicitLayoutOverridesPersistedFloatingFlag() throws {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 710, name: "Main")
        let workspaceId = WorkspaceDescriptor.ID()
        let metadata = makeRestorePlannerMetadata(
            workspaceId: workspaceId,
            mode: .tiling,
            layoutDecisionKind: .explicitLayout
        )
        let token = WindowToken(pid: 741, windowId: 41)
        let entry = makeRestorePlannerCatalogEntry(
            token: token,
            metadata: metadata,
            workspaceName: "1",
            monitor: monitor,
            restoreToFloating: true
        )

        let plan = try #require(
            planner.planPersistedHydration(
                .init(
                    token: token,
                    metadata: metadata,
                    catalog: PersistedWindowRestoreCatalog(entries: [entry]),
                    consumedEntries: [],
                    monitors: [monitor],
                    workspaceIdForName: { _ in workspaceId }
                )
            )
        )

        #expect(plan.targetMode == .tiling)
        #expect(plan.floatingFrame == nil)
    }
```

- [ ] **Step 3: Add test — fallback layout respects persisted floating flag**

Add right after the previous test:

```swift
    @Test func fallbackLayoutRespectsPersistedFloatingFlag() throws {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 711, name: "Main")
        let workspaceId = WorkspaceDescriptor.ID()
        let metadata = makeRestorePlannerMetadata(
            workspaceId: workspaceId,
            mode: .tiling,
            layoutDecisionKind: .fallbackLayout
        )
        let token = WindowToken(pid: 742, windowId: 42)
        let entry = makeRestorePlannerCatalogEntry(
            token: token,
            metadata: metadata,
            workspaceName: "1",
            monitor: monitor,
            restoreToFloating: true
        )

        let plan = try #require(
            planner.planPersistedHydration(
                .init(
                    token: token,
                    metadata: metadata,
                    catalog: PersistedWindowRestoreCatalog(entries: [entry]),
                    consumedEntries: [],
                    monitors: [monitor],
                    workspaceIdForName: { _ in workspaceId }
                )
            )
        )

        #expect(plan.targetMode == .floating)
        #expect(plan.floatingFrame != nil)
    }
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter RestorePlannerTests 2>&1 | tail -20`

Expected: Compilation error — `ManagedReplacementMetadata` has no member `layoutDecisionKind`. This confirms the tests reference the new field before it exists.

- [ ] **Step 5: Commit failing tests**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Tests/OmniWMTests/RestorePlannerTests.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - test: add failing tests for bug #12 — explicit layout vs persisted floating

Two new tests in RestorePlannerTests:
- explicitLayoutOverridesPersistedFloatingFlag: metadata with
  explicitLayout + restoreToFloating=true should hydrate as tiling
- fallbackLayoutRespectsPersistedFloatingFlag: metadata with
  fallbackLayout + restoreToFloating=true should hydrate as floating

Both fail at compile time — ManagedReplacementMetadata doesn't have
layoutDecisionKind yet.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add `layoutDecisionKind` to `ManagedReplacementMetadata`

**Files:**
- Modify: `Sources/OmniWM/Core/Workspace/WindowModel.swift:8-37`

- [ ] **Step 1: Add `layoutDecisionKind` field**

In `ManagedReplacementMetadata`, add the field after `degradedWindowServerChildEvidence`:

```swift
    var degradedWindowServerChildEvidence = false
    var layoutDecisionKind: WindowDecisionLayoutKind = .fallbackLayout
```

- [ ] **Step 2: Update `mergingNonNilValues`**

Add `layoutDecisionKind` to the `ManagedReplacementMetadata(...)` init call inside `mergingNonNilValues`. Add after the `degradedWindowServerChildEvidence` line:

```swift
            degradedWindowServerChildEvidence: degradedWindowServerChildEvidence
                || overlay.degradedWindowServerChildEvidence,
            layoutDecisionKind: overlay.layoutDecisionKind
```

Note: overlay's value always wins (not optional, most recent evaluation should take precedence).

- [ ] **Step 3: Verify build compiles**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds. The default value `.fallbackLayout` means existing call sites don't need changes.

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Workspace/WindowModel.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - feat: add layoutDecisionKind to ManagedReplacementMetadata

Stores the window rule engine's layout decision kind (explicitLayout
vs fallbackLayout) so it survives through the reconciliation pipeline.
Defaults to .fallbackLayout for backward compatibility.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Pass `layoutDecisionKind` Through Admission Pipeline

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift:2503-2522` (makeManagedReplacementMetadata)
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift:2180` (prepareCreateCandidate call site)

- [ ] **Step 1: Add parameter to `makeManagedReplacementMetadata`**

Update the function signature at line 2503 to accept `layoutDecisionKind`:

```swift
    private func makeManagedReplacementMetadata(
        bundleId: String?,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts,
        layoutDecisionKind: WindowDecisionLayoutKind = .fallbackLayout
    ) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: workspaceId,
            mode: mode,
            role: facts.ax.role,
            subrole: facts.ax.subrole,
            title: facts.ax.title,
            windowLevel: facts.windowServer?.level,
            parentWindowId: normalizedParentWindowId(facts.windowServer?.parentId),
            frame: facts.windowServer?.frame,
            transientWindowServerEvidence: facts.windowServer?.hasTransientSurfaceEvidence ?? false,
            degradedWindowServerChildEvidence: facts.degradedWindowServerChildEvidence,
            layoutDecisionKind: layoutDecisionKind
        )
    }
```

- [ ] **Step 2: Pass `layoutDecisionKind` in `prepareCreateCandidate`**

At line 2180, update the `makeManagedReplacementMetadata` call inside `prepareCreateCandidate` to pass the evaluation's decision kind:

```swift
            replacementMetadata: makeManagedReplacementMetadata(
                bundleId: resolvedBundleId,
                workspaceId: workspaceId,
                mode: trackedMode,
                facts: evaluation.facts,
                layoutDecisionKind: evaluation.decision.layoutDecisionKind
            ),
```

- [ ] **Step 3: Verify build compiles**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds. Other call sites of `makeManagedReplacementMetadata` use the default `.fallbackLayout`, which is correct — only the primary admission path in `prepareCreateCandidate` has the evaluation available.

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/AXEventHandler.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - feat: pass layoutDecisionKind through admission pipeline

makeManagedReplacementMetadata now accepts layoutDecisionKind parameter
(defaults to .fallbackLayout). prepareCreateCandidate passes the rule
engine's evaluation.decision.layoutDecisionKind so it's preserved in
the metadata through reconciliation.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Fix `planPersistedHydration` to Respect Explicit Layout

**Files:**
- Modify: `Sources/OmniWM/Core/Reconcile/RestorePlanner.swift:271-278`

- [ ] **Step 1: Update targetMode decision logic**

Replace the single-line `targetMode` assignment at line 271-272:

```swift
        let targetMode: TrackedWindowMode = persistedEntry.restoreIntent.restoreToFloating ? .floating : input.metadata
            .mode
        let floatingFrame = persistedEntry.restoreIntent.restoreToFloating
```

With:

```swift
        let shouldRestoreToFloating = persistedEntry.restoreIntent.restoreToFloating
            && input.metadata.layoutDecisionKind != .explicitLayout
        let targetMode: TrackedWindowMode = shouldRestoreToFloating ? .floating : input.metadata.mode
        let floatingFrame = shouldRestoreToFloating
```

This changes two things:
- `targetMode`: when `explicitLayout`, ignores persisted flag and uses the rule engine's mode from metadata
- `floatingFrame`: only resolves floating frame when actually restoring to floating (prevents stale frame data)

- [ ] **Step 2: Run the new tests to verify they pass**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter RestorePlannerTests 2>&1 | tail -20`

Expected: All 6 tests pass (4 existing + 2 new).

- [ ] **Step 3: Run full build to verify no regressions**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Reconcile/RestorePlanner.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - fix: skip persisted restoreToFloating when rule engine says explicitLayout

When the window rule engine explicitly decided the layout (user rule
with layout=tile or built-in rule), planPersistedHydration now ignores
the persisted restoreToFloating flag. This breaks the self-perpetuating
cycle where a window incorrectly saved as floating would stay floating
on every restart despite having an explicit tiling rule.

Heuristic-decided windows (fallbackLayout) still respect the persisted
flag — existing behavior preserved.

Fixes bug #12.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Verify End-to-End and Push

- [ ] **Step 1: Run targeted test suite**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter RestorePlannerTests 2>&1 | tail -20`

Expected: All 6 tests pass.

- [ ] **Step 2: Build release to ensure no warnings**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build complete with no errors.

- [ ] **Step 3: Bump build version**

In `Info.plist`, change `CFBundleVersion` from `56` to `57`.

- [ ] **Step 4: Push to remote**

```bash
cd ~/Documents/Personal/github/OmniWM && git push origin fix/tiled-window-z-order
```

- [ ] **Step 5: Manual verification — restart Hiro with log stream**

```bash
pkill -x OmniWM
nohup log stream --predicate 'subsystem == "com.omniwm"' --debug --style compact > /private/tmp/omniwm-logs.txt 2>&1 &
sleep 1
~/Documents/Personal/github/OmniWM/.build/debug/OmniWM &
```

Then check logs:
```bash
grep "planPersistedHydration.*pid: 801" /private/tmp/omniwm-logs.txt
```

Expected: `targetMode=tiling` (not `targetMode=floating`) for Ghostty (pid 801).

Verify visually: Ghostty and Chrome windows should be tiled, not floating.
