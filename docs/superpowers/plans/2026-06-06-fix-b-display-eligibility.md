# Fix B: Display Eligibility — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the frame-comparison fullscreen heuristic (`AXWindowService.isFullscreen`) in `FocusBorderController.renderEligibility` with SkyLight Space type detection (`SLSSpaceGetType`), so maximized-but-not-fullscreen apps (Slack, VSCode on 27" portrait) no longer lose their focus border.

**Architecture:** Add `SLSCopySpacesForWindows` and `SLSSpaceGetType` to the existing SkyLight bridge using the `resolveOptional` pattern. Add a `windowIsOnFullscreenSpace(windowId:)` method on SkyLight. Replace the `appFullscreen` check in `renderEligibility` to use space type detection instead of frame comparison. Fall back to the existing check if SLS functions aren't available.

**Tech Stack:** Swift, SkyLight private API (via dlsym), swift-testing framework

**Spec:** `docs/superpowers/specs/2026-06-06-fork-release-plan.md` — Fix B section

**Spec correction:** yabai's `space.c` confirms space type values are `0`=user, `2`=system, **`4`=fullscreen** (spec said `1`). Selector for `SLSCopySpacesForWindows` is `0x7`.

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/OmniWM/Core/SkyLight/SkyLight.swift` | Modify | Add SLSCopySpacesForWindows + SLSSpaceGetType resolution, add windowIsOnFullscreenSpace method |
| `Sources/OmniWM/Core/Border/FocusBorderController.swift` | Modify | Replace appFullscreen check at line 295 with SkyLight space type check |
| `Tests/OmniWMTests/DisplayEligibilityTests.swift` | Create | Tests for Fix B |

---

### Task 1: SkyLight bridge — Add space type API functions

**Files:**
- Modify: `Sources/OmniWM/Core/SkyLight/SkyLight.swift`
- Test: `Tests/OmniWMTests/DisplayEligibilityTests.swift`

- [ ] **Step 1: Write the failing test — windowIsOnFullscreenSpace returns false for normal windows**

Create `Tests/OmniWMTests/DisplayEligibilityTests.swift`:

```swift
import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct DisplayEligibilityTests {

    // MARK: - Task 1: SkyLight space type API

    @Test func windowIsOnFullscreenSpaceReturnsFalseForNormalWindow() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 9901)

        // Test windows are not on a fullscreen space
        let result = SkyLight.shared.windowIsOnFullscreenSpace(windowId: token.windowId)
        #expect(!result)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter DisplayEligibilityTests 2>&1 | tail -20`
Expected: Compilation error — `windowIsOnFullscreenSpace` does not exist

- [ ] **Step 3: Add SLS function declarations and resolution to SkyLight.swift**

In `SkyLight.swift`, add type aliases near the existing ones (around line 70-100 where other typealias declarations are):

```swift
private typealias CopySpacesForWindowsFunc = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
private typealias SpaceGetTypeFunc = @convention(c) (Int32, UInt64) -> Int32
```

Add private properties near the other function pointer properties:

```swift
private let copySpacesForWindows: CopySpacesForWindowsFunc?
private let spaceGetType: SpaceGetTypeFunc?
```

In `init()`, resolve them using `resolveOptional` (these are optional — fallback if unavailable):

```swift
copySpacesForWindows = resolveOptional("SLSCopySpacesForWindows", as: CopySpacesForWindowsFunc.self)
spaceGetType = resolveOptional("SLSSpaceGetType", as: SpaceGetTypeFunc.self)
```

Add the public method:

```swift
/// Returns true if the window is on a native fullscreen macOS Space.
/// Uses SLSSpaceGetType to distinguish native fullscreen (separate Space, type 4)
/// from maximized (fills display bounds but same Space, type 0).
/// Returns false if SLS functions are unavailable (safe fallback).
func windowIsOnFullscreenSpace(windowId: Int) -> Bool {
    guard let copySpacesForWindows, let spaceGetType else {
        WMLog.focus.info("windowIsOnFullscreenSpace: SLS space functions unavailable, fallback=false")
        return false
    }

    let conn = connectionId
    let windowArray = [CGWindowID(windowId)] as CFArray

    guard let spacesCF = copySpacesForWindows(conn, 0x7, windowArray)?.takeRetainedValue() as? [UInt64],
          !spacesCF.isEmpty
    else {
        return false
    }

    for spaceId in spacesCF {
        let spaceType = spaceGetType(conn, spaceId)
        if spaceType == 4 { // fullscreen space (yabai: space_is_fullscreen)
            return true
        }
    }

    return false
}
```

**Important notes:**
- `connectionId` is the existing property for `SLSMainConnectionID()` result (verify the actual property name in SkyLight.swift)
- `takeRetainedValue()` because `SLSCopySpacesForWindows` returns a CF object with +1 retain (Copy rule)
- Space type `4` = fullscreen (from yabai `space.c`), NOT `1` as the original spec said
- Selector `0x7` includes all space types in the query

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter DisplayEligibilityTests 2>&1 | tail -20`
Expected: 1 test PASS

- [ ] **Step 5: Run full test suite**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/SkyLight/SkyLight.swift Tests/OmniWMTests/DisplayEligibilityTests.swift
git commit -m "feat(fix-b): add SLSCopySpacesForWindows and SLSSpaceGetType to SkyLight bridge

Resolve SLS Space API functions via resolveOptional (safe fallback if
unavailable). Add windowIsOnFullscreenSpace(windowId:) that checks
SLSSpaceGetType == 4 (fullscreen space per yabai's space.c).

Returns false when SLS functions unavailable or window is on a
normal/user space (type 0). Distinguishes native fullscreen (separate
macOS Space) from maximized (fills display bounds, same Space).

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Replace appFullscreen check in renderEligibility

**Files:**
- Test: `Tests/OmniWMTests/DisplayEligibilityTests.swift` (append)
- Modify: `Sources/OmniWM/Core/Border/FocusBorderController.swift:295-300`

- [ ] **Step 1: Write failing test — maximized window should get border (not hide)**

Append to `DisplayEligibilityTests.swift`:

```swift
    // MARK: - Task 2: renderEligibility integration

    @Test func renderEligibilityDoesNotHideForMaximizedNonFullscreenWindow() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let ws1 = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: ws1, windowId: 9902)
        _ = controller.workspaceManager.setManagedFocus(token, in: ws1, onMonitor: monitor.id)

        // Sync into engine
        guard let engine = controller.niriEngine else {
            Issue.record("No engine")
            return
        }
        engine.syncWindows([token], in: ws1, selectedNodeId: nil)

        // Run layout
        let plans = try? await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [ws1]
        )
        if let plans { controller.layoutRefreshController.executeLayoutPlans(plans) }
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        // Even if isAppFullscreenActive is set (simulating the false positive),
        // the border should NOT hide if the window is not on a fullscreen space.
        // This test verifies the old appFullscreen path no longer triggers for
        // non-fullscreen windows.
        controller.workspaceManager.sessionState.focus.isAppFullscreenActive = true

        // The border controller should check SkyLight space type, not the
        // isAppFullscreenActive flag. Test window is NOT on a fullscreen space,
        // so the border should be visible (not hidden).
        let borderVisible = confirmFocusedBorderForLayoutPlanTests(on: controller, token: token)
        // After Fix B, this should be true (border visible despite isAppFullscreenActive)
        // Before Fix B, this would be false (border hidden due to false appFullscreen)
        #expect(borderVisible)
    }
```

**Note:** This test may need adjustment based on how `confirmFocusedBorderForLayoutPlanTests` works and whether `renderEligibility` is called as part of the border update cycle. The implementer should verify the test helper's behavior and adjust as needed.

- [ ] **Step 2: Run test to verify it fails (pre-Fix B: border hidden by false appFullscreen)**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter DisplayEligibilityTests 2>&1 | tail -20`
Expected: `renderEligibilityDoesNotHideForMaximizedNonFullscreenWindow` FAILS

- [ ] **Step 3: Modify renderEligibility in FocusBorderController.swift**

At `FocusBorderController.swift:295-300`, replace:

```swift
if target.isManaged,
   (controller.workspaceManager.isAppFullscreenActive || isManagedWindowFullscreen(target.token))
{
    WMLog.focus.debug("renderEligibility: hide reason=appFullscreen token=\(String(describing: target.token), privacy: .public)")
    return .hide
}
```

With:

```swift
if target.isManaged, let token = target.token {
    let isOnFullscreenSpace = SkyLight.shared.windowIsOnFullscreenSpace(windowId: token.windowId)
    if isOnFullscreenSpace || isManagedWindowFullscreen(token) {
        WMLog.focus.info("renderEligibility: hide reason=appFullscreen token=\(String(describing: token), privacy: .public) spaceCheck=\(isOnFullscreenSpace, privacy: .public)")
        return .hide
    }
}
```

**Key changes:**
- Removed `controller.workspaceManager.isAppFullscreenActive` — this was the false positive source
- Added `SkyLight.shared.windowIsOnFullscreenSpace(windowId:)` — checks actual macOS Space type
- Kept `isManagedWindowFullscreen(token)` as secondary check (engine-side fullscreen state)
- Added `.info` logging with space check result for diagnostics

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter DisplayEligibilityTests 2>&1 | tail -20`
Expected: 2 tests PASS

- [ ] **Step 5: Run full test suite**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Border/FocusBorderController.swift Tests/OmniWMTests/DisplayEligibilityTests.swift
git commit -m "feat(fix-b): replace frame-based fullscreen check with SkyLight space type

renderEligibility now uses SkyLight.windowIsOnFullscreenSpace instead
of WorkspaceManager.isAppFullscreenActive. This correctly distinguishes
native fullscreen (separate macOS Space, type 4) from maximized apps
that fill display bounds but remain on the same Space.

Fixes Slack and VSCode losing focus borders on 27\" portrait display
when they fill the screen without entering native fullscreen.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Build, deploy, and verify

**Files:** None (verification only)

Follow the MANDATORY deploy sequence from memorygraph.

- [ ] **Step 1: Bump build number**

In `Info.plist`, change CFBundleVersion from `77` to `78`.

- [ ] **Step 2: Run full test suite**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 3: Build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 4: Deploy (MANDATORY sequence)**

```bash
kill -9 $(pgrep -x OmniWM) 2>/dev/null
sleep 2
cd ~/Documents/Personal/github/OmniWM && nohup .build/debug/OmniWM > /dev/null 2>&1 &
sleep 3
NEW_PID=$(pgrep -x OmniWM)
echo "New PID: $NEW_PID"
# Verify running
.build/debug/omniwmctl ping && .build/debug/omniwmctl query windows 2>&1 | head -5
# Restart watcher
pkill -f "omniwmctl watch" 2>/dev/null; sleep 1
/Applications/OmniWM.app/Contents/MacOS/omniwmctl watch --all --exec sketchybar --trigger omniwm_workspace_changed &
```

- [ ] **Step 5: Verify via logs (MUST use --info --debug)**

```bash
# Log the space type for Slack on 27" display
command log show --predicate 'subsystem == "com.omniwm" AND processIdentifier == $NEW_PID' --last 30s --style compact --info --debug 2>&1 | grep -i "fullscreen\|spaceCheck\|eligibility"
```

Manual verification:
1. Focus Slack on 27" portrait display — border should be visible (was hidden before)
2. Toggle a window to native fullscreen (Cmd+Ctrl+F) — border should hide
3. Exit native fullscreen — border should reappear
4. Focus VSCode on 32" display (fills screen) — border should be visible

- [ ] **Step 6: Commit build bump**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Info.plist
git commit -m "chore: bump build to 78

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```
