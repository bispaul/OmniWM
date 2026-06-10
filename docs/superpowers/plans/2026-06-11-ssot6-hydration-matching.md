# SSOT #6: Hydration Matching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix RestorePlanner hydration so windows restore to their previous workspace and column position after Hiro restarts.

**Architecture:** Two surgical changes — populate the 6 nil metadata fields from already-available `evaluation.facts` at admission time, and scope hydration attempts to admission-only events. No new types, no new persistence format, no WMEvent changes.

**Tech Stack:** Swift 6.3, Apple Testing framework, @MainActor concurrency

**Spec:** `docs/superpowers/specs/2026-06-10-ssot6-hydration-matching-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/OmniWM/Core/Controller/AXEventHandler.swift` | Modify (~line 2039-2048) | Populate fallback metadata from facts |
| `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift` | Modify (~line 320) | Scope hydration to admission events |
| `Tests/OmniWMTests/RestorePlannerTests.swift` | Modify (append tests) | 4 new hydration tests |

---

### Task 1: Write tests for soft match with populated metadata

**Files:**
- Modify: `Tests/OmniWMTests/RestorePlannerTests.swift:199` (append before closing `}`)

- [ ] **Step 1: Write test — soft match succeeds with role+subrole populated**

Append to `RestorePlannerTests` struct (before the closing `}`):

```swift
@Test func softMatchSucceedsWhenMetadataHasRoleAndSubrole() throws {
    let planner = RestorePlanner()
    let monitor = makeLayoutPlanTestMonitor(displayId: 710, name: "Main")
    let savedWorkspaceId = WorkspaceDescriptor.ID()

    let catalogMetadata = makeRestorePlannerMetadata(
        bundleId: "com.mitchellh.ghostty",
        title: "~"
    )
    let catalogEntry = makeRestorePlannerCatalogEntry(
        token: WindowToken(pid: 100, windowId: 1),
        metadata: catalogMetadata,
        workspaceName: "1",
        monitor: monitor,
        includeIdentity: true,
        restoreToFloating: false
    )

    let admissionMetadata = makeRestorePlannerMetadata(
        bundleId: "com.mitchellh.ghostty",
        title: "~"
    )
    let admissionToken = WindowToken(pid: 200, windowId: 2)

    let plan = try #require(
        planner.planPersistedHydration(
            .init(
                token: admissionToken,
                metadata: admissionMetadata,
                catalog: PersistedWindowRestoreCatalog(entries: [catalogEntry]),
                consumedEntries: [],
                monitors: [monitor],
                workspaceIdForName: { name in
                    name == "1" ? savedWorkspaceId : nil
                }
            )
        )
    )

    #expect(plan.workspaceId == savedWorkspaceId)
}
```

- [ ] **Step 2: Run test to verify it passes**

This test should pass immediately — `makeRestorePlannerMetadata` already populates role/subrole. This validates the test infrastructure works and that soft match (different PID, same bundleId+role+subrole+title) succeeds.

```bash
swift test --filter "softMatchSucceedsWhenMetadataHasRoleAndSubrole"
```

Expected: PASS

- [ ] **Step 3: Write test — soft match fails with nil role/subrole (current bug)**

```swift
@Test func softMatchFailsWhenMetadataHasNilRoleAndSubrole() {
    let planner = RestorePlanner()
    let monitor = makeLayoutPlanTestMonitor(displayId: 711, name: "Main")

    let catalogMetadata = makeRestorePlannerMetadata(
        bundleId: "com.mitchellh.ghostty",
        title: "~"
    )
    let catalogEntry = makeRestorePlannerCatalogEntry(
        token: WindowToken(pid: 100, windowId: 1),
        metadata: catalogMetadata,
        workspaceName: "1",
        monitor: monitor,
        includeIdentity: true,
        restoreToFloating: false
    )

    let nilMetadata = ManagedReplacementMetadata(
        bundleId: "com.mitchellh.ghostty",
        workspaceId: WorkspaceDescriptor.ID(),
        mode: .tiling,
        role: nil,
        subrole: nil,
        title: nil,
        windowLevel: nil,
        parentWindowId: nil,
        frame: nil
    )

    let plan = planner.planPersistedHydration(
        .init(
            token: WindowToken(pid: 200, windowId: 2),
            metadata: nilMetadata,
            catalog: PersistedWindowRestoreCatalog(entries: [catalogEntry]),
            consumedEntries: [],
            monitors: [monitor],
            workspaceIdForName: { _ in WorkspaceDescriptor.ID() }
        )
    )

    #expect(plan == nil, "Nil role/subrole should fail soft match against catalog with populated fields")
}
```

- [ ] **Step 4: Run test to verify it passes (confirms the bug exists)**

```bash
swift test --filter "softMatchFailsWhenMetadataHasNilRoleAndSubrole"
```

Expected: PASS (plan is nil — confirming the current bug behavior)

- [ ] **Step 5: Write test — multi-window title disambiguation**

```swift
@Test func multiWindowTitleDisambiguationMatchesUniquelyByTitle() throws {
    let planner = RestorePlanner()
    let monitor = makeLayoutPlanTestMonitor(displayId: 712, name: "Main")
    let ws1Id = WorkspaceDescriptor.ID()
    let ws2Id = WorkspaceDescriptor.ID()

    let chromeMetadata1 = makeRestorePlannerMetadata(
        bundleId: "com.google.chrome",
        title: "Gmail"
    )
    let chromeMetadata2 = makeRestorePlannerMetadata(
        bundleId: "com.google.chrome",
        title: "GitHub"
    )

    let entry1 = makeRestorePlannerCatalogEntry(
        token: WindowToken(pid: 100, windowId: 1),
        metadata: chromeMetadata1,
        workspaceName: "1",
        monitor: monitor,
        includeIdentity: true,
        restoreToFloating: false
    )
    let entry2 = makeRestorePlannerCatalogEntry(
        token: WindowToken(pid: 100, windowId: 2),
        metadata: chromeMetadata2,
        workspaceName: "2",
        monitor: monitor,
        includeIdentity: true,
        restoreToFloating: false
    )

    let admissionMetadata = makeRestorePlannerMetadata(
        bundleId: "com.google.chrome",
        title: "GitHub"
    )

    let plan = try #require(
        planner.planPersistedHydration(
            .init(
                token: WindowToken(pid: 200, windowId: 10),
                metadata: admissionMetadata,
                catalog: PersistedWindowRestoreCatalog(entries: [entry1, entry2]),
                consumedEntries: [],
                monitors: [monitor],
                workspaceIdForName: { name in
                    ["1": ws1Id, "2": ws2Id][name]
                }
            )
        )
    )

    #expect(plan.workspaceId == ws2Id, "Should match the GitHub entry on workspace 2")
}
```

- [ ] **Step 6: Write test — identical titles rejected (matches.count > 1)**

```swift
@Test func identicalTitlesCauseAmbiguousRejection() {
    let planner = RestorePlanner()
    let monitor = makeLayoutPlanTestMonitor(displayId: 713, name: "Main")

    let chromeMetadata = makeRestorePlannerMetadata(
        bundleId: "com.google.chrome",
        title: "New Tab"
    )

    let entry1 = makeRestorePlannerCatalogEntry(
        token: WindowToken(pid: 100, windowId: 1),
        metadata: chromeMetadata,
        workspaceName: "1",
        monitor: monitor,
        includeIdentity: true,
        restoreToFloating: false
    )
    let entry2 = makeRestorePlannerCatalogEntry(
        token: WindowToken(pid: 100, windowId: 2),
        metadata: chromeMetadata,
        workspaceName: "2",
        monitor: monitor,
        includeIdentity: true,
        restoreToFloating: false
    )

    let plan = planner.planPersistedHydration(
        .init(
            token: WindowToken(pid: 200, windowId: 10),
            metadata: chromeMetadata,
            catalog: PersistedWindowRestoreCatalog(entries: [entry1, entry2]),
            consumedEntries: [],
            monitors: [monitor],
            workspaceIdForName: { _ in WorkspaceDescriptor.ID() }
        )
    )

    #expect(plan == nil, "Identical titles should fail matches.count == 1 guard")
}
```

- [ ] **Step 7: Run all 4 new tests**

```bash
swift test --filter "softMatchSucceeds|softMatchFails|multiWindowTitle|identicalTitlesCause"
```

Expected: 4 tests PASS

- [ ] **Step 8: Commit tests**

```bash
git add Tests/OmniWMTests/RestorePlannerTests.swift
git commit -m "test: add hydration matching tests for SSOT #6 (TDD red/green)"
```

---

### Task 2: Populate fallback metadata from evaluation.facts

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift:2039-2048`

- [ ] **Step 1: Replace nil fields with evaluation.facts values**

In `prepareCreateCandidate`, find the fallback `ManagedReplacementMetadata` construction (~line 2039-2048). Replace:

```swift
// FIND this exact block:
            ) ?? ManagedReplacementMetadata(
                bundleId: resolvedBundleId,
                workspaceId: workspaceId,
                mode: trackedMode,
                role: nil,
                subrole: nil,
                title: nil,
                windowLevel: nil,
                parentWindowId: nil,
                frame: nil
            ),

// REPLACE with:
            ) ?? ManagedReplacementMetadata(
                bundleId: resolvedBundleId,
                workspaceId: workspaceId,
                mode: trackedMode,
                role: evaluation.facts.ax.role,
                subrole: evaluation.facts.ax.subrole,
                title: evaluation.facts.ax.title,
                windowLevel: evaluation.facts.windowServer?.level,
                parentWindowId: evaluation.facts.windowServer?.parentId,
                frame: evaluation.facts.windowServer?.frame
            ),
```

- [ ] **Step 2: Build to verify compilation**

```bash
swift build -c debug
```

Expected: Build complete

- [ ] **Step 3: Run existing tests to verify no regression**

```bash
swift test --filter "RestorePlanner"
```

Expected: All existing + new tests pass (the `softMatchFailsWhenMetadataHasNilRoleAndSubrole` test still passes — it tests the RestorePlanner matching logic directly with nil metadata, not the AXEventHandler path)

- [ ] **Step 4: Run format check**

```bash
make format-check
```

If files need formatting: `make format`

- [ ] **Step 5: Commit**

```bash
git add Sources/OmniWM/Core/Controller/AXEventHandler.swift
git commit -m "fix: populate fallback metadata from evaluation.facts for hydration matching (SSOT #6)"
```

---

### Task 3: Scope hydration to admission events

**Files:**
- Modify: `Sources/OmniWM/Core/Workspace/WorkspaceManager.swift:320`

- [ ] **Step 1: Add event-type guard in recordReconcileEvent**

Find line ~320 in `recordReconcileEvent`:

```swift
// FIND:
        let persistedHydration = event.token.flatMap { plannedPersistedHydrationMutation(for: $0) }

// REPLACE with:
        let persistedHydration: PersistedHydrationMutation?
        switch event {
        case .windowAdmitted, .windowRekeyed:
            persistedHydration = event.token.flatMap { plannedPersistedHydrationMutation(for: $0) }
        default:
            persistedHydration = nil
        }
```

Note: `.windowAdmitted` and `.windowRekeyed` have associated values, but the `case` pattern without bindings matches regardless of associated values.

- [ ] **Step 2: Build**

```bash
swift build -c debug
```

Expected: Build complete

- [ ] **Step 3: Run all affected tests**

```bash
swift test --filter "RestorePlanner|WorkspaceAssignment|ServiceLifecycleManager"
```

Expected: All pass

- [ ] **Step 4: Format + lint**

```bash
make format-check && make lint
```

Expected: 0 files need formatting, 0 serious lint violations

- [ ] **Step 5: Commit**

```bash
git add Sources/OmniWM/Core/Workspace/WorkspaceManager.swift
git commit -m "perf: scope hydration to admission events only — eliminates noMatch spam (SSOT #6)"
```

---

### Task 4: Runtime verification + CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md` (build number + SSOT status)

- [ ] **Step 1: Rebuild and deploy**

```bash
swift build -c debug
pkill -x OmniWM; sleep 1 && .build/debug/OmniWM &
sleep 2 && pgrep -x OmniWM && .build/debug/omniwmctl ping
```

Expected: New PID, `pong` response

- [ ] **Step 2: Verify logs — no noMatch spam for non-admission events**

Move windows around, switch workspaces, change focus for 30 seconds, then check:

```bash
/usr/bin/log show --predicate 'processIdentifier == <PID> AND subsystem == "com.omniwm"' --last 30s --info --debug | grep "noMatch"
```

Expected: 0 noMatch entries (or only at initial admission, not during focus/workspace changes)

- [ ] **Step 3: Verify catalog saves with populated fields**

After windows have been admitted and catalog saved:

```bash
cat ~/.local/state/omniwm/runtime-state.json | python3 -c "
import json, sys
d = json.load(sys.stdin)
entries = d.get('windowRestoreCatalog', {}).get('entries', [])
for i, e in enumerate(entries):
    key = e.get('key', {})
    baseKey = key.get('baseKey', {})
    print(f'{i}: bundle={baseKey.get(\"bundleId\",\"?\")} role={baseKey.get(\"role\",\"nil\")} subrole={baseKey.get(\"subrole\",\"nil\")} title={key.get(\"title\",\"nil\")}')
"
```

Expected: All entries have `role=AXWindow`, `subrole=AXStandardWindow`, and non-nil titles

- [ ] **Step 4: Update CLAUDE.md**

Update build number to 98 and add SSOT #6 status:

```
Branch: `fix/scope-relayout-to-workspace`. Build 98.
```

Under "Hydration matching (SSOT #6)":
```
**Hydration matching (SSOT #6)**: FIXED (build 98). Fallback metadata populated from evaluation.facts. Hydration scoped to admission events. Two-restart migration — first restart saves enriched catalog, second restart restores window positions.
```

- [ ] **Step 5: Final commit**

```bash
git add CLAUDE.md
git commit -m "chore: update CLAUDE.md for build 98 — SSOT #6 hydration matching fixed"
```

- [ ] **Step 6: Update persistence systems**

Update Serena `mem:core`, memorygraph (store + link to `6ab03ce1` and `0486d6ce`), Memory MCP, and dotfiles `project_omniwm_next_session.md`.
