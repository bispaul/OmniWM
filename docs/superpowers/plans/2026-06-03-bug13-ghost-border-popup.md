# Bug #13 Fix: Clear Border When Non-Managed Window No Longer Exists

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent ghost focus borders from persisting after transient popup windows (e.g., Notion Calendar notifications) dismiss.

**Architecture:** Add a `SkyLight.queryWindowInfo` existence check in `renderEligibility` for non-managed targets, and a deferred 500ms refresh in `focusChanged` to ensure prompt cleanup even if no other event triggers a render.

**Tech Stack:** Swift 6.2, Apple Testing framework, @MainActor, SkyLight private API

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Sources/OmniWM/Core/Border/FocusBorderController.swift` | Modify | Add test hook, nonManagedRefreshTask, modify renderEligibility + focusChanged |
| `Tests/OmniWMTests/FocusBorderControllerTests.swift` | Create | 2 tests for non-managed window border cleanup |

---

### Task 1: Add Properties and Test Hook

**Files:**
- Modify: `Sources/OmniWM/Core/Border/FocusBorderController.swift:23-31`

- [ ] **Step 1: Add test hook and task property**

After line 27 (`var suppressNextFrameHintForTests: ((WindowToken) -> Bool)?`), add:

```swift
    var windowExistsProviderForTests: ((UInt32) -> Bool)?
```

After line 31 (`private var suppressedManagedTargets: Set<WindowToken> = []`), add:

```swift
    private var nonManagedRefreshTask: Task<Void, Never>?
```

- [ ] **Step 2: Verify build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Border/FocusBorderController.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - feat: add windowExistsProviderForTests and nonManagedRefreshTask

Test hook for SkyLight window existence check (matches *ForTests pattern
from AXEventHandler). Task property for deferred non-managed refresh
(matches DisplayConfigurationObserver debounce pattern).

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add Non-Managed Window Check in renderEligibility

**Files:**
- Modify: `Sources/OmniWM/Core/Border/FocusBorderController.swift:266-310`

- [ ] **Step 1: Add existence check before final return**

In `renderEligibility`, replace the final `return .update` (line 310) with:

```swift
        if !target.isManaged {
            guard let wid = UInt32(exactly: target.windowId) else {
                WMLog.focus.debug("renderEligibility: clear reason=invalidWindowId windowId=\(target.windowId, privacy: .public)")
                return .clear
            }
            let windowExists = windowExistsProviderForTests?(wid)
                ?? (SkyLight.shared.queryWindowInfo(wid) != nil)
            if !windowExists {
                WMLog.focus.debug("renderEligibility: clear reason=nonManagedWindowGone windowId=\(target.windowId, privacy: .public)")
                return .clear
            }
        }

        return .update
```

- [ ] **Step 2: Verify build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Border/FocusBorderController.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - fix: clear border when non-managed window no longer exists (bug #13)

renderEligibility now checks SkyLight.queryWindowInfo for non-managed
targets. If the window is gone (popup dismissed, app quit), returns
.clear to remove the border. Uses UInt32(exactly:) to avoid trapping
on invalid window IDs.

Fixes bug #13.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add Deferred Refresh in focusChanged

**Files:**
- Modify: `Sources/OmniWM/Core/Border/FocusBorderController.swift:41-61`

- [ ] **Step 1: Add deferred refresh after the existing return**

Replace the `focusChanged` method body. The current body ends with:

```swift
        return refresh(
            preferredFrame: preferredFrame,
            preferredFrameSource: preferredFrameSource,
            forceOrdering: forceOrdering
        )
    }
```

Replace with:

```swift
        let result = refresh(
            preferredFrame: preferredFrame,
            preferredFrameSource: preferredFrameSource,
            forceOrdering: forceOrdering
        )

        nonManagedRefreshTask?.cancel()
        if let target, !target.isManaged {
            let token = target.token
            nonManagedRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, self.lastAXConfirmedTarget?.token == token else { return }
                _ = self.refresh()
            }
        } else {
            nonManagedRefreshTask = nil
        }

        return result
    }
```

- [ ] **Step 2: Verify build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Border/FocusBorderController.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - feat: deferred refresh for non-managed focus targets

When focus changes to a non-managed window, schedules a 500ms deferred
refresh to detect if the window was dismissed. Cancels previous deferred
task on each focus change to avoid redundant checks. Matches the
DisplayConfigurationObserver debounce pattern.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Write Tests

**Files:**
- Create: `Tests/OmniWMTests/FocusBorderControllerTests.swift`

- [ ] **Step 1: Create test file with two tests**

```swift
import CoreGraphics
import Foundation
@testable import OmniWM
import Testing

@Suite struct FocusBorderControllerTests {
    @Test @MainActor func nonManagedTargetWithDeadWindowClearsBorder() {
        let defaults = UserDefaults(suiteName: "com.omniwm.border.test.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let borderController = controller.focusBorderController

        borderController.windowExistsProviderForTests = { _ in false }

        let token = WindowToken(pid: 99999, windowId: 99999)
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 99999)
        let target = KeyboardFocusTarget(
            token: token,
            axRef: axRef,
            workspaceId: nil,
            isManaged: false
        )

        _ = borderController.focusChanged(to: target)
        _ = borderController.refresh()

        #expect(borderController.currentTarget == nil)
    }

    @Test @MainActor func nonManagedTargetWithLiveWindowKeepsBorder() {
        let defaults = UserDefaults(suiteName: "com.omniwm.border.test.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let borderController = controller.focusBorderController

        borderController.windowExistsProviderForTests = { _ in true }

        let token = WindowToken(pid: 99998, windowId: 99998)
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 99998)
        let target = KeyboardFocusTarget(
            token: token,
            axRef: axRef,
            workspaceId: nil,
            isManaged: false
        )

        _ = borderController.focusChanged(to: target)

        #expect(borderController.currentTarget != nil)
        #expect(borderController.currentTarget?.token == token)
    }
}
```

- [ ] **Step 2: Run tests**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter FocusBorderControllerTests 2>&1 | tail -20`

Expected: Both tests pass.

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Tests/OmniWMTests/FocusBorderControllerTests.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - test: add FocusBorderController tests for non-managed window cleanup

Two tests:
- nonManagedTargetWithDeadWindowClearsBorder: windowExistsProvider
  returns false, border is cleared after refresh
- nonManagedTargetWithLiveWindowKeepsBorder: windowExistsProvider
  returns true, border persists

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Verify End-to-End, Bump Version, Push

- [ ] **Step 1: Run tests**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter FocusBorderControllerTests 2>&1 | tail -20`

Expected: Both tests pass.

- [ ] **Step 2: Build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build complete.

- [ ] **Step 3: Bump build version**

In `Info.plist`, change `CFBundleVersion` from `58` to `59`.

- [ ] **Step 4: Commit and push**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Info.plist
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - chore: bump build to 59

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
git push origin fix/tiled-window-z-order
```

- [ ] **Step 5: Manual verification**

```bash
pkill -x OmniWM
nohup log stream --predicate 'subsystem == "com.omniwm"' --debug --style compact > /private/tmp/omniwm-logs.txt 2>&1 &
sleep 1
~/Documents/Personal/github/OmniWM/.build/debug/OmniWM &
```

Trigger a Notion Calendar notification or other popup. Check logs:
```bash
grep "nonManagedWindowGone" /private/tmp/omniwm-logs.txt
```

Expected: `"renderEligibility: clear reason=nonManagedWindowGone"` appears within 500ms of popup dismiss. Border clears cleanly.
