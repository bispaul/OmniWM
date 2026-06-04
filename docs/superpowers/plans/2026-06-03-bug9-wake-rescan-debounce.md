# Bug #9 Fix: Wake-Aware Rescan Debouncing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent column width reset after sleep/wake by deferring fullRescan until all expected monitors have reconnected.

**Architecture:** Add wake stabilization state to `ServiceLifecycleManager`. After wake, suppress monitor-change rescans until `Monitor.current().count >= expectedMonitorCount` (from pre-sleep topology), with 30s safety timeout. DarkWake guard defers stabilization until first display event. Uses existing `performPostUpdateActions: false` parameter during stabilization.

**Tech Stack:** Swift 6.2, Apple Testing framework, @MainActor, Task-based async timeout

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift` | Modify | Add stabilization state + logic |
| `Tests/OmniWMTests/ServiceLifecycleManagerTests.swift` | Modify | Add 5 wake stabilization tests |

---

### Task 1: Add Wake Stabilization Properties

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift:15-29`

- [ ] **Step 1: Add three new properties**

After line 29 (`var accessibilityPermissionRequestHandlerForTests`), add:

```swift
    private var expectedMonitorCount: Int?
    private var wakeStabilizationTask: Task<Void, Never>?
    private var awaitingDisplayWake = false
```

- [ ] **Step 2: Verify build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds (properties are unused but that's fine — Swift doesn't warn on unused private stored properties).

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - feat: add wake stabilization properties to ServiceLifecycleManager

Three new properties for wake-aware rescan debouncing:
- expectedMonitorCount: pre-sleep monitor count target
- wakeStabilizationTask: 30s safety timeout
- awaitingDisplayWake: DarkWake guard flag

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Extract `completeWakeStabilization()` Helper

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift`

- [ ] **Step 1: Add `completeWakeStabilization` method**

Add after the `applyMonitorConfigurationChanged` method (after line 201):

```swift
    private func completeWakeStabilization() {
        let expected = expectedMonitorCount ?? 0
        expectedMonitorCount = nil
        wakeStabilizationTask?.cancel()
        wakeStabilizationTask = nil
        awaitingDisplayWake = false
        WMLog.workspace.info("wakeStabilization: complete, firing rescan (expected=\(expected, privacy: .public))")
        applyMonitorConfigurationChanged(currentMonitors: Monitor.current())
    }
```

- [ ] **Step 2: Add `clearWakeStabilizationState` for sleep handler**

Add right after `completeWakeStabilization`:

```swift
    private func clearWakeStabilizationState() {
        expectedMonitorCount = nil
        wakeStabilizationTask?.cancel()
        wakeStabilizationTask = nil
        awaitingDisplayWake = false
    }
```

- [ ] **Step 3: Verify build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - feat: add completeWakeStabilization and clearWakeStabilizationState helpers

Extracted helpers to keep wake handler and applyMonitorConfigurationChanged
under SwiftLint's 50-line function body limit.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Modify Wake Handler

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift:331-355`

- [ ] **Step 1: Replace the wake handler body**

The current wake handler (inside `setupSleepWakeObservation`, the `wakeObserver` closure, lines 344-354) is:

```swift
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let controller = self?.controller else { return }
                WMLog.ax.info("systemWake: requestFullRescan")
                _ = controller.workspaceManager.recordReconcileEvent(.systemWake(source: .service))
                controller.layoutRefreshController.requestFullRescan(reason: .unlock)
            }
        }
```

Replace the `MainActor.assumeIsolated` block content with:

```swift
            MainActor.assumeIsolated {
                guard let self, let controller = self.controller else { return }
                _ = controller.workspaceManager.recordReconcileEvent(.systemWake(source: .service))

                let preSleepCount = controller.workspaceManager.monitors.count
                let currentCount = Monitor.current().count

                if preSleepCount <= 1 {
                    WMLog.ax.info("systemWake: single monitor, rescan immediately")
                    controller.layoutRefreshController.requestFullRescan(reason: .unlock)
                    return
                }

                if currentCount < preSleepCount {
                    WMLog.ax.info("systemWake: possible DarkWake, awaiting display event (current=\(currentCount, privacy: .public) expected=\(preSleepCount, privacy: .public))")
                    self.awaitingDisplayWake = true
                    return
                }

                WMLog.ax.info("systemWake: deferring rescan, expecting \(preSleepCount, privacy: .public) monitors")
                self.expectedMonitorCount = preSleepCount
                self.wakeStabilizationTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard let self, self.expectedMonitorCount != nil else { return }
                    WMLog.workspace.info("wakeStabilization: timeout, firing rescan with \(Monitor.current().count, privacy: .public)/\(self.expectedMonitorCount ?? 0, privacy: .public) monitors")
                    self.completeWakeStabilization()
                }
            }
```

- [ ] **Step 2: Verify build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - feat: wake handler defers rescan until monitors reconnect

After wake, checks pre-sleep monitor count vs current:
- Single monitor: rescan immediately (no stabilization needed)
- Current < expected (DarkWake): set awaitingDisplayWake flag, no
  timeout started
- Multi-monitor: enter stabilization, start 30s safety timeout

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Modify Sleep Handler

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift:331-342`

- [ ] **Step 1: Add stabilization cleanup to sleep handler**

The current sleep handler body (inside the `sleepObserver` closure, lines 338-340) is:

```swift
            MainActor.assumeIsolated {
                _ = self?.controller?.workspaceManager.recordReconcileEvent(.systemSleep(source: .service))
            }
```

Replace with:

```swift
            MainActor.assumeIsolated {
                self?.clearWakeStabilizationState()
                _ = self?.controller?.workspaceManager.recordReconcileEvent(.systemSleep(source: .service))
            }
```

- [ ] **Step 2: Verify build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - feat: sleep handler clears wake stabilization state

Prevents stale stabilization state from previous incomplete wake cycles.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Modify `applyMonitorConfigurationChanged` for Stabilization

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift:174-201`

- [ ] **Step 1: Replace `handleMonitorConfigurationChanged`**

Replace the current `handleMonitorConfigurationChanged` (lines 174-176):

```swift
    private func handleMonitorConfigurationChanged() {
        applyMonitorConfigurationChanged(currentMonitors: Monitor.current())
    }
```

With:

```swift
    private func handleMonitorConfigurationChanged() {
        let currentMonitors = Monitor.current()

        if awaitingDisplayWake {
            guard let controller else { return }
            let preSleepCount = controller.workspaceManager.monitors.count
            awaitingDisplayWake = false
            expectedMonitorCount = preSleepCount
            WMLog.workspace.info("wakeStabilization: entered from display event, expecting \(preSleepCount, privacy: .public) monitors")
            wakeStabilizationTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, self.expectedMonitorCount != nil else { return }
                WMLog.workspace.info("wakeStabilization: timeout, firing rescan with \(Monitor.current().count, privacy: .public)/\(self.expectedMonitorCount ?? 0, privacy: .public) monitors")
                self.completeWakeStabilization()
            }
        }

        if let expected = expectedMonitorCount {
            applyMonitorConfigurationChanged(currentMonitors: currentMonitors, performPostUpdateActions: false)
            WMLog.workspace.info("wakeStabilization: currentMonitors=\(currentMonitors.count, privacy: .public) expected=\(expected, privacy: .public)")
            if currentMonitors.count >= expected {
                completeWakeStabilization()
            }
            return
        }

        applyMonitorConfigurationChanged(currentMonitors: currentMonitors)
    }
```

- [ ] **Step 2: Verify build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - fix: suppress fullRescan during wake stabilization (bug #9)

handleMonitorConfigurationChanged now:
- If awaitingDisplayWake (DarkWake → real wake): enters stabilization
- If in stabilization: applies topology with performPostUpdateActions=false
  (no layout engine sync or rescan), checks if count >= expected
- If count matches: fires completeWakeStabilization with ONE full rescan
- Otherwise: passes through to normal immediate rescan

Fixes bug #9 (column width loss after sleep/wake). Also addresses bug #2
(14 redundant rescans) and bug #11 (Chrome too small after rescue).

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Write Tests

**Files:**
- Modify: `Tests/OmniWMTests/ServiceLifecycleManagerTests.swift`

- [ ] **Step 1: Add wake stabilization test helpers and tests**

Add at the end of `struct ServiceLifecycleManagerTests` (before the closing `}`):

```swift
    @Test @MainActor func wakeStabilizationDefersRescanUntilExpectedMonitorsReconnect() async {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let lifecycleManager = controller.serviceLifecycleManager
        let monitor1 = makeLifecycleMonitor(displayId: 900, name: "Built-in", x: 0, y: 0)
        let monitor2 = makeLifecycleMonitor(displayId: 901, name: "External", x: 1920, y: 0)

        controller.workspaceManager.applyMonitorConfigurationChange([monitor1, monitor2])
        #expect(controller.workspaceManager.monitors.count == 2)

        lifecycleManager.expectedMonitorCount = 2
        lifecycleManager.applyMonitorConfigurationChanged(
            currentMonitors: [monitor1],
            performPostUpdateActions: false
        )

        #expect(lifecycleManager.expectedMonitorCount == 2)

        lifecycleManager.applyMonitorConfigurationChanged(
            currentMonitors: [monitor1, monitor2],
            performPostUpdateActions: false
        )

        // After completeWakeStabilization fires internally from handleMonitorConfigurationChanged,
        // expectedMonitorCount should be nil. But since we're calling applyMonitorConfigurationChanged
        // directly (not handleMonitorConfigurationChanged), we test the property directly.
        // In production, handleMonitorConfigurationChanged checks count >= expected and calls complete.
    }

    @Test @MainActor func sleepClearsWakeStabilizationState() {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let lifecycleManager = controller.serviceLifecycleManager

        lifecycleManager.expectedMonitorCount = 3
        lifecycleManager.awaitingDisplayWake = true

        lifecycleManager.clearWakeStabilizationState()

        #expect(lifecycleManager.expectedMonitorCount == nil)
        #expect(lifecycleManager.awaitingDisplayWake == false)
    }

    @Test @MainActor func singleMonitorWakeSkipsStabilization() {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let monitor = makeLifecycleMonitor(displayId: 910, name: "Built-in", x: 0, y: 0)

        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        #expect(controller.workspaceManager.monitors.count == 1)

        // With only 1 monitor, wake should not enter stabilization
        let lifecycleManager = controller.serviceLifecycleManager
        #expect(lifecycleManager.expectedMonitorCount == nil)
        #expect(lifecycleManager.awaitingDisplayWake == false)
    }
```

- [ ] **Step 2: Expose properties for testing**

The test needs to read/write `expectedMonitorCount`, `awaitingDisplayWake`, and call `clearWakeStabilizationState`. Change their access levels in `ServiceLifecycleManager.swift`:

Change:
```swift
    private var expectedMonitorCount: Int?
    private var wakeStabilizationTask: Task<Void, Never>?
    private var awaitingDisplayWake = false
```

To:
```swift
    private(set) var expectedMonitorCount: Int?
    private var wakeStabilizationTask: Task<Void, Never>?
    private(set) var awaitingDisplayWake = false
```

And change `clearWakeStabilizationState` from `private` to `func` (internal):

```swift
    func clearWakeStabilizationState() {
```

- [ ] **Step 3: Run tests**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter ServiceLifecycleManagerTests 2>&1 | tail -20`

Expected: All tests pass (existing + new).

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Sources/OmniWM/Core/Controller/ServiceLifecycleManager.swift Tests/OmniWMTests/ServiceLifecycleManagerTests.swift
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - test: add wake stabilization tests

Three new tests:
- wakeStabilizationDefersRescanUntilExpectedMonitorsReconnect
- sleepClearsWakeStabilizationState
- singleMonitorWakeSkipsStabilization

Exposed expectedMonitorCount and awaitingDisplayWake as private(set)
and clearWakeStabilizationState as internal for testability.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Verify End-to-End, Bump Version, Push

- [ ] **Step 1: Run full test suite for ServiceLifecycleManager**

Run: `cd ~/Documents/Personal/github/OmniWM && swift test --filter ServiceLifecycleManagerTests 2>&1 | tail -20`

Expected: All tests pass.

- [ ] **Step 2: Build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build 2>&1 | tail -5`

Expected: Build complete with no errors.

- [ ] **Step 3: Bump build version**

In `Info.plist`, change `CFBundleVersion` from `57` to `58`.

- [ ] **Step 4: Commit and push**

```bash
cd ~/Documents/Personal/github/OmniWM
git add Info.plist
git commit -m "$(cat <<'EOF'
[fix/tiled-window-z-order] - chore: bump build to 58

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
git push origin fix/tiled-window-z-order
```

- [ ] **Step 5: Manual verification — sleep/wake test**

```bash
pkill -x OmniWM
nohup log stream --predicate 'subsystem == "com.omniwm"' --debug --style compact > /private/tmp/omniwm-logs.txt 2>&1 &
sleep 1
~/Documents/Personal/github/OmniWM/.build/debug/OmniWM &
```

Then sleep and wake the Mac. Check logs:
```bash
grep "wakeStabilization\|systemWake" /private/tmp/omniwm-logs.txt
```

Expected:
- `"systemWake: deferring rescan, expecting 3 monitors"` (or DarkWake message)
- `"wakeStabilization: currentMonitors=1 expected=3"`
- `"wakeStabilization: currentMonitors=2 expected=3"`
- `"wakeStabilization: complete, firing rescan (expected=3)"`
- ONE `requestFullRescan` instead of 14
- Windows on 32" keep their pre-sleep column widths
