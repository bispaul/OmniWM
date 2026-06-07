# Fix C: Sleep/Wake Restore — Final Design (2026-06-07, updated 2026-06-08)

## Bug
#2: Windows migrate to wrong monitor/workspace after sleep/wake.

## Status
- Workspace + display assignment: 10/10 ✅ (tests 18-19)
- Window tracking: 10/10 ✅ (unconditional SkyLight guard)
- No false "missing" rescan ✅ (matchedTokens fix)
- Column order: ❌ (root cause identified — see Remaining Items)
- Focus restoration: ❌ (consequence of column order — focus target scrolls off viewport)

## Scope
Restore the user's pre-sleep desktop state:
- Windows on correct workspace + display ✅
- Active workspace per monitor ✅
- Niri column order and widths (this update)
- Focused window (this update)
- Floating window geometry ✅

Out of scope: Dwindle split position persistence (feature addition, not Fix C bug fix).

## Architecture
**Snapshot + macOS as inputs, Hiro tracking as output.**

Three data sources:
1. **macOS window server** (CGS/SkyLight/AX) — ground truth, what windows exist
2. **Immutable snapshot** (SleepStateSnapshot) — desired state, captured at willSleep
3. **Hiro's live tracking** (WorkspaceManager) — output target, volatile during wake

Hiro's tracking is the OUTPUT, not the INPUT. During wake it's volatile (CGS fires "destroyed" before AX can confirm "alive"). The restore writes TO Hiro's tracking, matching snapshot records against macOS windows.

## Data Model

### SleepWindowRecord (14 fields per window)
- token, pid, bundleId, title — identity + matching
- workspaceId, monitorId — where it belongs
- frame, floatingFrame — position + size
- mode — tiling/floating
- isVisible, hiddenReason — visibility state
- isNativeFullscreen — macOS fullscreen
- layoutEngine — niri/dwindle/unmanaged

### SleepStateSnapshot
- outputIds — monitor topology
- windowRecords — per-window state
- activeWorkspaceByMonitor — which workspace user was viewing per display
- niriPlacements — column widths/indices per workspace
- viewportStates — scroll position per workspace
- focusedToken — which window had focus

## Sequence

1. **willSleep**: capture immutable snapshot. No gates, no isReconciling.
2. **systemDidWake**: start progressive restore (5 ticks x 3s = 15s).
3. **Each tick**: match snapshot records to tracked windows. setWorkspace for mismatched. Skip: nativeFullscreen, scratchpad, missing monitor.
4. **Finalization (15s)**: check for missing windows (app alive but not tracked). If any: trigger ONE requestFullRescan, wait 3s.
5. **Final restore (15s or 18s)**: authoritative — see executeFinalRestore steps below.
6. **DarkWake**: 30s timeout, no display events → cancel.

### executeFinalRestore Steps (updated)

1. **Workspace assignments** — resolve tokens, assign to correct workspace. Build tokenRemap as side effect.
2. **Niri placements** — remove windows from engine, rebuild tree from snapshot using `restoreInitialPlacements`. Reuse tokenRemap from step 1.
3. **Active workspace per monitor** — `setActiveWorkspace` for each monitor present post-wake.
4. **Viewport states** — restore ViewportState from snapshot (activeColumnIndex, viewOffsetPixels, etc.).
5. **Viewport selectedNodeId fixup** (NEW) — fix stale NodeIds after step 2 rebuilt the tree. See "Root Cause" below.
6. **Validate dead windows** — check for apps that quit during sleep.
7. **Relayout** — `requestImmediateRelayout` with `.wakeRestore` reason (NEW — was `.workspaceTransition`).
8. **Focus** — deferred 500ms after relayout settles. Resolve focusedToken, call setManagedFocus.

## Matching Cascade (for recycled window IDs)
1. Exact token (pid + windowId)
2. PID + title match
3. PID + frame size match (within 50px)
4. PID + same workspace
5. PID + first available

matchedTokens prevents double-matching (refactored to inout parameter — see Item 3).

## Phase 1-5 + ABC Impact
None. All fixes operate at the ServiceLifecycleManager level, fixing inputs to the layout pipeline. Layout engines (Phase 1), dirty-reflow (Phase 2), viewport pipeline (Phase 3), classifier (Phase 4), reconciliation (Phase 5) are all untouched. Fix A (atomic transfer) and Fix B (display eligibility) have no interaction.

---

## Remaining Items (3)

### Item 1: Viewport selectedNodeId Fixup (functional)

**Root cause**: `restoreInitialPlacements` (step 2) creates new `NiriContainer` and `NiriWindow` nodes. Each `NiriNode` generates a fresh `NodeId` in `init()`. The viewport state's `selectedNodeId` (restored from snapshot in step 4) references the pre-sleep NodeId, which no longer exists in the new tree.

**Failure chain**:
1. Step 2 rebuilds Niri tree with fresh NodeIds
2. Step 4 restores viewport including stale `selectedNodeId`
3. Step 7 triggers relayout → `resolveSelection` → `validateSelection`
4. `validateSelection` can't find stale NodeId → falls back to `columns.first?.firstChild()?.id`
5. `ensureSelectionVisible` scrolls viewport to column 0 instead of user's active column
6. Previously-visible column (e.g., Ghostty at column 3) scrolls off viewport → `layoutTransient(hidden)`
7. Focus restore can't focus a hidden window → focus fails

**Why build 66 didn't have this**: Build 66 never rebuilt the Niri tree. Unconditional SkyLight guard kept all windows tracked with their original NodeIds. Viewport's `selectedNodeId` stayed valid.

**Fix**: Add step 5 (between viewport restore and relayout):
```
for each workspace in snapshot.niriPlacements:
    viewportState = wm.niriViewportState(for: wsId)
    columns = engine.columns(in: wsId)
    if columns.isEmpty: continue
    clampedIndex = min(viewportState.activeColumnIndex, columns.count - 1)
    if let activeWindow = columns[clampedIndex].activeWindow:
        viewportState.selectedNodeId = activeWindow.id
        wm.updateNiriViewportState(viewportState, for: wsId)
```

**Expert validation**:
- Architect ✅: fixes inputs to viewport pipeline, pipeline itself unchanged
- Coder ✅: minimal, well-bounded change in executeFinalRestore
- Debugger ✅: edge cases handled (empty columns skip, index clamped, nil activeWindow)
- Devil's Advocate ✅: build 66 validates the theory; all steps synchronous in @MainActor frame

### Item 2: RefreshReason.wakeRestore (code quality)

**Problem**: `finalizeWakeRestore` calls `requestFullRescan(reason: .monitorConfigurationChanged)`. `executeFinalRestore` calls `requestImmediateRelayout(reason: .workspaceTransition)`. Both are semantically wrong — they're wake restore operations, not monitor config changes or workspace transitions. Affects log clarity.

**Fix**: Add two new RefreshReason cases:
- `.wakeRescan` — requestRoute: `.fullRescan`, scheduling: `.plain`
- `.wakeRestore` — requestRoute: `.immediateRelayout`, scheduling: `.plain`

Update call sites:
- `finalizeWakeRestore`: `.monitorConfigurationChanged` → `.wakeRescan`
- `executeFinalRestore` step 7: `.workspaceTransition` → `.wakeRestore`

### Item 3: matchedTokens Refactor (code quality)

**Problem**: `matchedTokens` is a mutable `Set<WindowToken>` instance property on `ServiceLifecycleManager`. Depends on call order (`.removeAll()` must be called before each use). Caused missingCount bug when stale tokens from tick 5 leaked into finalization.

**Fix**: Remove instance property. Add `matchedTokens: inout Set<WindowToken>` parameter to `resolveTrackedToken`. Each caller creates a local set:
- `tryRestoreWorkspaces` — local var per tick
- `finalizeWakeRestore` — local var for missing check
- `executeFinalRestore` step 1 — local var for workspace assignment
- `executeFinalRestore` step 8 focus — local var for focus token resolution

Eliminates the stale-state bug class entirely. `.removeAll()` calls become unnecessary.

---

## Test Results

### Test 16 (2026-06-07, before unconditional guard fix)
- 10/10 workspace correct, column order + focus issues

### Test 19 (2026-06-07, after unconditional guard + stale matchedTokens fix)
- 10/10 tracked, 10/10 ws+display correct
- No false "missing" rescan
- Column order shifted on WS8 (Niri)
- Focus failed: Ghostty hidden as layoutTransient(right) — scrolled off viewport
- Root cause: stale selectedNodeId → viewport scrolled to column 0

## What's Working (don't touch)
- Unconditional SkyLight guard
- Progressive ticks (5 × 3s)
- Save-wait-restore architecture (snapshot + macOS as inputs, Hiro as output)
- PID+title+frame matching cascade
- Snapshot data model (14 fields + activeWorkspaceByMonitor)
