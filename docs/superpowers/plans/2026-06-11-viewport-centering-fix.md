# Niri Viewport Centering Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix destination viewport gap after atomic workspace transfer by adding `ensureSelectionVisible` call, following the established non-atomic transfer pattern.

**Architecture:** Single surgical change — add viewport centering for the transferred column on the destination workspace inside `atomicTransferWindow`, matching the pattern already used by the non-atomic transfer paths at lines 886 and 1010.

**Tech Stack:** Swift 6.3, Apple Testing framework, @MainActor concurrency

**Spec:** `docs/superpowers/specs/2026-06-11-viewport-centering-fix-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift` | Modify (~line 503) | Add destination viewport centering |

---

### Task 1: Add destination viewport centering to atomicTransferWindow

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift:503`

- [ ] **Step 1: Add viewport centering block after reassignManagedWindow**

Find the block at ~line 503 in `atomicTransferWindow`:

```swift
// FIND this exact sequence:
        controller.reassignManagedWindow(token, to: targetWorkspaceId)

        var newSourceFocusToken: WindowToken?
```

Insert between them:

```swift
        controller.reassignManagedWindow(token, to: targetWorkspaceId)

        if let movedNode = engine.findNode(for: token),
           let targetMonitor = controller.workspaceManager.monitor(for: targetWorkspaceId)
        {
            targetState.selectedNodeId = movedNode.id
            let gap = CGFloat(controller.workspaceManager.gaps)
            let workingFrame = controller.insetWorkingFrame(for: targetMonitor)
            engine.ensureSelectionVisible(
                node: movedNode,
                in: targetWorkspaceId,
                motion: controller.motionPolicy.snapshot(),
                state: &targetState,
                workingFrame: workingFrame,
                gaps: gap
            )
        }

        var newSourceFocusToken: WindowToken?
```

This follows the exact pattern from the non-atomic transfer path at lines 878-892, which:
1. Finds the moved node via `engine.findNode(for: token)`
2. Gets the target monitor
3. Sets `targetState.selectedNodeId`
4. Calls `engine.ensureSelectionVisible` with the target workspace's state

Note: `engine` (NiriLayoutEngine), `controller` (WMController), `token` (WindowToken), `targetWorkspaceId`, and `targetState` (inout ViewportState) are ALL already in scope at this location.

- [ ] **Step 2: Build**

```bash
swift build -c debug
```

Expected: Build complete (no new types, no new imports — all types already in scope)

- [ ] **Step 3: Run affected tests**

```bash
swift test --filter "WorkspaceManager|WorkspaceNavigation|ViewportGeometry"
```

Expected: All pass (this change doesn't affect test-level behavior — viewport state changes are committed via applySessionTransfer which tests already exercise)

- [ ] **Step 4: Format + lint**

```bash
make format-check
```

If files need formatting: `make format`

```bash
make lint
```

Expected: 0 serious violations

- [ ] **Step 5: Commit**

```bash
git add Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift
git commit -m "fix: center destination viewport after atomic workspace transfer (Bug #7/27)

atomicTransferWindow was the ONLY transfer path missing ensureSelectionVisible
on the destination workspace. Non-atomic paths (lines 886, 1010) already had it.
Follows the established pattern exactly.

Fixes: viewport gap after moveToWorkspace on all Niri displays."
```

---

### Task 2: Deploy and runtime verification

- [ ] **Step 1: Rebuild and deploy**

```bash
swift build -c debug
pkill -x OmniWM; sleep 1 && .build/debug/OmniWM &
sleep 2 && pgrep -x OmniWM && .build/debug/omniwmctl ping
```

Expected: New PID, `pong` response

- [ ] **Step 2: Test moveToWorkspace on Retina**

Move a window from WS1 to WS2 (or any other workspace on the same display):
- Press the moveToWorkspace hotkey
- Verify: NO visual gap on the destination workspace
- Capture IPC state:

```bash
.build/debug/omniwmctl query windows --workspace <target> --fields app,frame --format json | python3 -c "
import json, sys
d = json.load(sys.stdin)
for w in d['result']['payload']['windows']:
    f = w['frame']
    print(f'{w[\"app\"][\"name\"]:15s} x={f[\"x\"]:7.0f} w={f[\"width\"]:7.0f} x+w={f[\"x\"]+f[\"width\"]:7.0f}')
"
```

Expected: Columns fill the display width with standard 2px gaps

- [ ] **Step 3: Test moveToWorkspace cross-display**

Move a window from Retina (1728px) to 32" (2560px):
- Verify: NO gap, column centered on destination
- Check logs for ensureSelectionVisible evidence:

```bash
/usr/bin/log show --predicate 'processIdentifier == <PID> AND subsystem == "com.omniwm"' --last 10s --info --debug | grep "atomicTransfer\|ensureSelection\|overspread"
```

- [ ] **Step 4: Verify source workspace recenters**

After transferring a window OUT of a workspace:
- Switch back to the source workspace
- Verify: remaining columns are properly positioned (no gap where the transferred column was)

- [ ] **Step 5: Update CLAUDE.md**

Update build number to 99. Update Bug #7/27 status:

```
- **Bug #7/27** (column gap after moveToWorkspace): FIXED (build 99). Destination viewport centering added to atomicTransferWindow following non-atomic path pattern.
```

- [ ] **Step 6: Commit CLAUDE.md**

```bash
git add CLAUDE.md
git commit -m "chore: update CLAUDE.md for build 99 — Bug #7/27 viewport centering fixed"
```

- [ ] **Step 7: Update persistence systems**

Update Serena `mem:core`, memorygraph (link to `0486d6ce`), Memory MCP, and dotfiles `project_omniwm_next_session.md`.
