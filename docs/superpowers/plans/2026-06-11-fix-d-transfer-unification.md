# Fix D Layer 1: Transfer Path Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `commitWorkspaceTransition` to `atomicTransferWindow` so it triggers a relayout like all other transfer paths.

**Architecture:** Single-site fix — `atomicTransferWindow` is the only transfer path missing `commitWorkspaceTransition`. Adding it follows the established pattern from `moveColumnToWorkspace` (line 776). PostLayoutAction focuses the source workspace's new focus window.

**Tech Stack:** Swift 6.3, @MainActor concurrency

**Spec:** `docs/superpowers/specs/2026-06-11-fix-d-transfer-unification-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift` | Modify (~line 536) | Add commitWorkspaceTransition |

---

### Task 1: Add commitWorkspaceTransition to atomicTransferWindow

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift:536`

- [ ] **Step 1: Add commitWorkspaceTransition after applySessionTransfer**

Find the block at ~line 528-537 in `atomicTransferWindow`:

```swift
// FIND this exact sequence:
        applySessionTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            sourceState: sourceState,
            sourceFocusedToken: newSourceFocusToken,
            targetWorkspaceId: targetWorkspaceId,
            targetState: targetState,
            targetFocusedToken: nil
        )

        return true
```

Replace with:

```swift
        applySessionTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            sourceState: sourceState,
            sourceFocusedToken: newSourceFocusToken,
            targetWorkspaceId: targetWorkspaceId,
            targetState: targetState,
            targetFocusedToken: nil
        )

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: affectedWorkspaceIds(
                sourceWorkspaceId: sourceWorkspaceId,
                targetWorkspaceId: targetWorkspaceId
            ),
            reason: .workspaceTransition
        ) { [weak controller] in
            if let newSourceFocusToken {
                controller?.focusWindow(newSourceFocusToken)
            }
        }

        return true
```

This follows the exact pattern from `moveColumnToWorkspace` at lines 776-786.

All variables are already in scope:
- `controller` — `self.controller` (weak optional, already guarded at method start)
- `sourceWorkspaceId` — `WorkspaceDescriptor.ID` (method local)
- `targetWorkspaceId` — `WorkspaceDescriptor.ID` (method local)
- `newSourceFocusToken` — `WindowToken?` (computed above at line ~507-510)
- `affectedWorkspaceIds(sourceWorkspaceId:targetWorkspaceId:)` — private helper already used at lines 776 and 845
- `controller.layoutRefreshController.commitWorkspaceTransition(affectedWorkspaces:reason:_:)` — already used at lines 776 and 845

- [ ] **Step 2: Build**

```bash
swift build -c debug
```

Expected: Build complete (no new types, all symbols already in scope)

- [ ] **Step 3: Run tests**

```bash
swift test --filter "WorkspaceManager|ViewportGeometry|WorkspaceNavigation"
```

Expected: All pass

- [ ] **Step 4: Format + lint**

```bash
make format-check
```

If needed: `make format`

```bash
make lint
```

Expected: 0 serious violations

- [ ] **Step 5: Commit**

```bash
git add Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift
git commit -m "fix: add commitWorkspaceTransition to atomicTransferWindow (Fix D, Bug #7/27/#30)

atomicTransferWindow was the ONLY transfer path missing commitWorkspaceTransition.
All other 4 callers of applySessionTransfer already had it. This completes the
pattern, triggering relayout with correct destination monitor geometry.

Fixes: viewport gap after moveToWorkspace, cross-display frame geometry mismatch."
```

---

### Task 2: Deploy and runtime verification

- [ ] **Step 1: Rebuild and deploy**

```bash
swift build -c debug
pkill -x OmniWM; sleep 1 && .build/debug/OmniWM &
sleep 2 && pgrep -x OmniWM && .build/debug/omniwmctl ping
```

Expected: New PID, `pong`

- [ ] **Step 2: Test same-display transfer**

Move a window between workspaces on the SAME display (e.g., ws1→ws2 on Retina):

```bash
# Before transfer — capture frames
.build/debug/omniwmctl query windows --workspace 1 --fields app,frame --format json | python3 -c "
import json, sys
d = json.load(sys.stdin)
for w in d['result']['payload']['windows']:
    f = w['frame']
    print(f'{w[\"app\"][\"name\"]:15s} x={f[\"x\"]:7.0f} w={f[\"width\"]:7.0f} x+w={f[\"x\"]+f[\"width\"]:7.0f}')
"
```

After transfer: verify no viewport gap, columns fill display width.

- [ ] **Step 3: Test cross-display transfer**

Move a window between displays (e.g., ws8 on 32" → ws1 on Retina):

```bash
# Check logs for verificationMismatch
/usr/bin/log show --predicate 'processIdentifier == <PID> AND subsystem == "com.omniwm"' --last 10s --info --debug | grep "verificationMismatch\|Frame write failed"
```

Expected: 0 verificationMismatch errors

- [ ] **Step 4: Verify source workspace recenters**

After transferring a window OUT, switch back to the source workspace. Verify remaining columns are positioned correctly.

- [ ] **Step 5: Update CLAUDE.md**

Update build number to 100. Update Bug #7/27 and #30 status.

- [ ] **Step 6: Commit CLAUDE.md**

```bash
git add CLAUDE.md
git commit -m "chore: update CLAUDE.md for build 100 — Fix D Layer 1, Bug #7/27/#30"
```

- [ ] **Step 7: Update persistence systems**

Update Serena `mem:core`, memorygraph (link to `72434591`, `0486d6ce`, `e8a27ef5`), Memory MCP, dotfiles `project_omniwm_next_session.md`.
