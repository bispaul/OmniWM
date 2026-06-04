# Bug #5 Fix: Skip Minimized Windows During Focus Navigation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent `focusNeighbor` (Caps+H/L) from targeting minimized windows, which causes unintended unminimization.

**Architecture:** Track miniaturized window IDs in `AXEventHandler` via a `Set<Int>`. Clear on activation, destroy, and app termination. In `NiriLayoutHandler.focusNeighbor`, loop `focusTarget` calls to skip minimized nodes, capped at `tiledEntries.count` to prevent infinite loops with `infiniteLoop` wrapping.

**Tech Stack:** Swift 6.2, Apple Testing framework, @MainActor

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Sources/OmniWM/Core/Controller/AXEventHandler.swift` | Modify | Add miniaturizedWindowIds tracking + isWindowMiniaturized |
| `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift` | Modify | Loop focusTarget to skip minimized |

---

### Task 1: Add Miniaturized Window Tracking to AXEventHandler

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/AXEventHandler.swift`

- [ ] **Step 1: Add `miniaturizedWindowIds` property**

After line 325 (`var windowExistsInWindowServerForTests: ((UInt32) -> Bool)?`), add:

```swift
    private(set) var miniaturizedWindowIds: Set<Int> = []
```

- [ ] **Step 2: Add `isWindowMiniaturized` method**

After `handleWindowMiniaturized` (after line 1639), add:

```swift
    func isWindowMiniaturized(_ windowId: Int) -> Bool {
        miniaturizedWindowIds.contains(windowId)
    }
```

- [ ] **Step 3: Modify `handleWindowMiniaturized` to track state**

Replace the current `handleWindowMiniaturized` (lines 1634-1639):

```swift
    func handleWindowMiniaturized(pid: pid_t, windowId: Int) {
        controller?.clearKeyboardFocusTarget(
            matching: WindowToken(pid: pid, windowId: windowId),
            pid: pid
        )
    }
```

With:

```swift
    func handleWindowMiniaturized(pid: pid_t, windowId: Int) {
        miniaturizedWindowIds.insert(windowId)
        WMLog.ax.info("windowMiniaturized: windowId=\(windowId, privacy: .public) pid=\(pid, privacy: .public)")
        controller?.clearKeyboardFocusTarget(
            matching: WindowToken(pid: pid, windowId: windowId),
            pid: pid
        )
    }
```

- [ ] **Step 4: Clear flag in `handleAppActivation`**

In `handleAppActivation`, after line 1255 (`let token = WindowToken(pid: pid, windowId: axRef.windowId)`), add:

```swift
        miniaturizedWindowIds.remove(axRef.windowId)
```

- [ ] **Step 5: Clear flag in `handleCGSWindowDestroyed`**

In `handleCGSWindowDestroyed`, after line 791 (the `WMLog.ax.info("Window destroyed:...` log), add:

```swift
        miniaturizedWindowIds.remove(Int(windowId))
```

- [ ] **Step 6: Clear flags in `cleanupFocusStateForTerminatedApp`**

In `cleanupFocusStateForTerminatedApp` (line 3250), after `let entries = controller.workspaceManager.entries(forPid: pid)` (line 3252), add:

```swift
        let terminatedWindowIds = Set(entries.map { $0.token.windowId })
        miniaturizedWindowIds.subtract(terminatedWindowIds)
```

- [ ] **Step 7: Verify build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 8: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/AXEventHandler.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - feat: track miniaturized window state in AXEventHandler

Add miniaturizedWindowIds set — inserted on kAXWindowMiniaturized,
cleared on app activation (covers dock click, Cmd+Tab), window destroy,
and app termination. Exposed via isWindowMiniaturized() for focus
navigation to query.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Modify focusNeighbor to Skip Minimized Windows

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift:1098-1113`

- [ ] **Step 1: Replace the single focusTarget call with a skip loop**

Replace the block at lines 1098-1113:

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
            WMLog.focus.debug("focusNeighbor: direction=\(String(describing: direction), privacy: .public) currentNode=\(String(describing: currentId), privacy: .public) targetNode=\(String(describing: newNode.id), privacy: .public)")
            activateNode(
                newNode, in: wsId, state: &state,
                options: .init(activateWindow: false, ensureVisible: false)
            )
        }
```

With:

```swift
        var candidateNode = currentNode
        var attempts = 0
        let maxAttempts = controller.workspaceManager.tiledEntries(in: wsId).count
        while attempts < maxAttempts,
              let newNode = engine.focusTarget(
                  direction: direction,
                  currentSelection: candidateNode,
                  in: wsId,
                  motion: controller.motionPolicy.snapshot(),
                  state: &state,
                  workingFrame: workingFrame,
                  gaps: gap
              )
        {
            attempts += 1
            if let windowNode = newNode as? NiriWindow,
               controller.axEventHandler.isWindowMiniaturized(windowNode.token.windowId)
            {
                WMLog.focus.debug("focusNeighbor: skipping minimized windowId=\(windowNode.token.windowId, privacy: .public)")
                candidateNode = newNode
                continue
            }
            WMLog.focus.debug("focusNeighbor: direction=\(String(describing: direction), privacy: .public) currentNode=\(String(describing: currentId), privacy: .public) targetNode=\(String(describing: newNode.id), privacy: .public)")
            activateNode(
                newNode, in: wsId, state: &state,
                options: .init(activateWindow: false, ensureVisible: false)
            )
            break
        }
```

- [ ] **Step 2: Verify build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - fix: focusNeighbor skips minimized windows (bug #5)

focusNeighbor now loops focusTarget calls, skipping nodes whose windows
are miniaturized (tracked via AXEventHandler.isWindowMiniaturized).
Loop is capped at tiledEntries.count to prevent infinite loops when
infiniteLoop wrapping is enabled and all windows are minimized.

Viewport state deltas telescope correctly across skip iterations:
sum of (posA-posB) + (posB-posC) = (posA-posC).

Fixes bug #5.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Verify End-to-End, Bump Version, Push

- [ ] **Step 1: Build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build complete.

- [ ] **Step 2: Bump build version**

In `Info.plist`, change `CFBundleVersion` from `59` to `60`.

- [ ] **Step 3: Commit and push**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Info.plist
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - chore: bump build to 60

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
git push origin fix/tiled-window-z-order
```

- [ ] **Step 4: Manual verification**

```bash
pkill -x OmniWM
nohup log stream --predicate 'subsystem == "com.omniwm"' --debug --style compact > /private/tmp/omniwm-logs.txt 2>&1 &
sleep 1
~/Documents/Personal/github/OmniWM/.build/debug/OmniWM &
```

Then:
1. Open 3 windows (e.g., Ghostty, Chrome, VSCode) on one workspace
2. Minimize Chrome (Cmd+M)
3. Press Caps+L (focus right) — should skip Chrome and go to VSCode
4. Check logs: `grep "skipping minimized\|windowMiniaturized" /private/tmp/omniwm-logs.txt`

Expected:
- `"windowMiniaturized: windowId=NNN pid=812"` when Chrome minimized
- `"focusNeighbor: skipping minimized windowId=NNN"` when focus skips it
