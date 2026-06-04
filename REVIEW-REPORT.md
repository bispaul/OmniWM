# OmniWM/Hiro Comprehensive Code Review Report

## Overview

- **Codebase**: 144K lines of Swift, 314 files (240 source + 73 test + support)
- **Review agents**: 16
- **Raw findings**: 273
- **Unique findings after deduplication**: 131
- **Duplicates merged**: 142 findings collapsed into their primary instances

---

## Overall Health Assessment: Grade B-

**Strengths**: The codebase demonstrates strong engineering in several areas. The reconcile subsystem (event-sourced state machine with StateReducer, ActionPlan, ReconcileTrace, InvariantChecks) is excellent architecture. The per-app AX thread model with dedicated run loops prevents cross-process deadlocks -- a sophisticated and correct design. @MainActor isolation is consistently applied across the controller layer with proper weak-self captures in closures. The test suite is remarkably thorough at 24K+ lines with trace-based state machine verification. SkyLight private API integration is well-architected with required vs. optional symbol distinction and cross-version fallbacks.

**Weaknesses**: Five production crash paths exist in recoverable scenarios (fatalError/force-unwrap). Three use-after-free or dangling pointer risks exist in C callback bridges. Eight or more data race conditions stem from `nonisolated(unsafe)` misuse. Memory leaks occur in hot paths (CGS regions on every border redraw, CADisplayLink retain cycles). Three god objects exceed 3K lines each. Significant code triplication exists for floating geometry. Test hooks pollute the production API surface without `#if DEBUG` guards. Silent error swallowing via guard-let-return is pervasive with no diagnostic trail.

---

## TOP 10 Most Impactful Issues to Fix First

### 1. fatalError in WMController.defaultWorkspaceId -- production crash [3 reviewers]
- **Files**: WMController.swift:1195
- **Impact**: Crashes the entire WM when no workspace can be resolved during monitor hotplug, topology changes, or corrupt settings. A WM crash means all managed windows lose their layout.
- **Fix**: Replace fatalError with on-demand workspace creation or return Optional.

### 2. NSScreen.screens.first! force unwrap in QuakeTerminalController [3 reviewers]
- **Files**: QuakeTerminalController.swift:800
- **Impact**: Crashes during sleep/wake cycles, KVM switching, or clamshell transitions when macOS temporarily reports zero screens. Common user scenario.
- **Fix**: `NSScreen.main ?? NSScreen.screens.first ?? <fallback>` or return Optional.

### 3. CGS region objects leaked on every border redraw [2 reviewers]
- **Files**: SkyLight.swift:641-653, 670-682
- **Impact**: Leaked CF region objects accumulate over the entire WM session. Every border window creation and every resize leaks a region. Over hours of use this causes meaningful memory growth.
- **Fix**: Add `defer { cfRelease(region) }` after the guard-let in both createBorderWindow and setWindowShape.

### 4. HotkeyCenter deinit: Carbon event handler use-after-free [1 reviewer, critical]
- **Files**: Hotkeys.swift:288-293
- **Impact**: Carbon event handler holds an unretained pointer to self via Unmanaged.passUnretained. If HotkeyCenter is deallocated without stop() being called, the callback fires on a dangling pointer. Additionally, MainActor.assumeIsolated in deinit can crash if deinit runs off the main thread (not guaranteed in Swift 6).
- **Fix**: Add stop() or RemoveEventHandler in deinit. Remove MainActor.assumeIsolated from deinit; use only thread-safe operations.

### 5. QuakeTerminal Unmanaged.passUnretained use-after-free [1 reviewer, critical]
- **Files**: QuakeTerminalController.swift:104
- **Impact**: C callbacks from Ghostty dispatch asynchronously to main queue using an unretained pointer. If controller is deallocated before dispatched blocks execute, takeUnretainedValue dereferences a dangling pointer.
- **Fix**: Use passRetained with explicit release in cleanup, or use a weak-reference wrapper object as userdata.

### 6. CADisplayLink target:self retain cycles [1 reviewer, 2 locations]
- **Files**: LayoutRefreshController.swift:231, OverviewAnimator.swift:89
- **Impact**: CADisplayLink holds a strong reference to its target. Since the controller stores the display link, neither can be deallocated. OverviewAnimator has a deinit that calls stopDisplayLink, but deinit can never execute due to the cycle. LayoutRefreshController has no deinit at all.
- **Fix**: Use a weak-proxy NSObject as the display link target (standard Apple pattern).

### 7. ScreenCoordinateSpace thread-unsafe cache [3 reviewers]
- **Files**: CGGeometry+Extensions.swift:67-69
- **Impact**: Three nonisolated(unsafe) static vars (cachedTransforms, cachedGlobalFrame, screenConfigurationToken) are read/written from MainActor and per-app AX threads simultaneously. Coordinate conversions are called constantly during frame writes. Torn reads or memory corruption during display reconfiguration.
- **Fix**: Protect with OSAllocatedUnfairLock or restrict all callers to @MainActor.

### 8. Dwindle division by zero with Fill Screen aspect ratio [2 reviewers, critical]
- **Files**: DwindleLayoutEngine.swift:736, DwindleLayoutHandler.swift:519
- **Impact**: Fill Screen returns CGSize(0,0). Division produces NaN which propagates into CGRect, corrupting layout or crashing CoreGraphics. The guard in effectiveSettings is bypassed by applyResolvedSettings.
- **Fix**: Guard in applyResolvedSettings for fill case, or clamp to non-zero in singleWindowRect.

### 9. RunLoopJob.action data race [2 reviewers]
- **Files**: RunLoopJob.swift:7, 13-19
- **Impact**: The `action` property is read/written from multiple threads (cancel from any thread, action execution from AX worker thread) without synchronization. The atomic `_cancelled` flag does not protect the subsequent action access. TSAN-detectable.
- **Fix**: Protect action access with OSAllocatedUnfairLock or store in an Atomic wrapper.

### 10. SkyLight.orderWindow fatalError on transaction failure [3 reviewers]
- **Files**: SkyLight.swift:323
- **Impact**: Calls fatalError during a recoverable scenario (WindowServer disruption during sleep/wake, space switching). Every other transaction-using method handles nil gracefully. Crashes WM during normal operation.
- **Fix**: Replace fatalError with guard-return and warning log, matching other methods.

---

## Deduplicated Findings by Category

### Category 1: Production Crash Risks (11 unique findings)

| # | Severity | Finding | Reviewers | Location |
|---|----------|---------|-----------|----------|
| 1 | critical | fatalError in defaultWorkspaceId reachable during monitor hotplug | 3 | WMController.swift:1195 |
| 2 | critical | NSScreen.screens.first! crashes when no screens available | 3 | QuakeTerminalController.swift:800 |
| 3 | critical | Dwindle Fill Screen aspect ratio produces NaN via division by zero | 2 | DwindleLayoutEngine.swift:736 |
| 4 | high | SkyLight.orderWindow fatalError on transaction failure | 3 | SkyLight.swift:323 |
| 5 | high | fatalError in lazy overviewController when weak controller is nil | 2 | WindowActionHandler.swift:64 |
| 6 | high | Int-to-Int32 narrowing crash for large window IDs | 1 | SkyLight.swift:293,533 |
| 7 | medium | try! NSRegularExpression on built-in PiP rules | 2 | WindowRuleEngine.swift:627 |
| 8 | medium | Division by zero in normalizeColumnSizes when totalSize is 0 | 1 | NiriLayoutEngine+ColumnOps.swift:225 |
| 9 | medium | Division by zero in splitRect with zero-dimension screens | 1 | DwindleLayoutEngine.swift:700 |
| 10 | medium | Division by avgColumnWidth in viewport transitions | 1 | ViewportState+ColumnTransitions.swift:216 |
| 11 | low | preconditionFailure in CLIParser for local invocations | 1 | CLIParser.swift:28 |

### Category 2: Memory Safety (Use-After-Free, Dangling Pointers) (4 unique findings)

| # | Severity | Finding | Reviewers | Location |
|---|----------|---------|-----------|----------|
| 1 | critical | HotkeyCenter deinit does not unregister Carbon event handler; dangling Unmanaged pointer | 1 | Hotkeys.swift:288 |
| 2 | critical | QuakeTerminal Unmanaged.passUnretained dangling pointer in C callbacks | 1 | QuakeTerminalController.swift:104 |
| 3 | high | MainActor.assumeIsolated in HotkeyCenter deinit crashes if deinit runs off main thread | 1 | Hotkeys.swift:289 |
| 4 | high | @testable import in production app target bypasses access control | 1 | OmniWMApp.swift:2 |

### Category 3: Memory Leaks & Retain Cycles (9 unique findings)

| # | Severity | Finding | Reviewers | Location |
|---|----------|---------|-----------|----------|
| 1 | high | CGS region objects leaked in createBorderWindow and setWindowShape | 2 | SkyLight.swift:641-682 |
| 2 | high | CADisplayLink target:self retain cycle in LayoutRefreshController | 1 | LayoutRefreshController.swift:231 |
| 3 | high | CADisplayLink target:self retain cycle in OverviewAnimator | 1 | OverviewAnimator.swift:89 |
| 4 | medium | SleepPreventionManager singleton registers observers never removed | 2 | SleepPreventionManager.swift:70-82 |
| 5 | medium | Static pinnedElements holds AXUIElement refs indefinitely without eviction | 1 | AXWindow.swift:199 |
| 6 | medium | MouseEventHandler static weak _instance fragile lifecycle coupling | 2 | MouseEventHandler.swift:202 |
| 7 | medium | SecureInputMonitor static var sharedMonitor hidden strong reference | 1 | SecureInputMonitor.swift:14-18 |
| 8 | low | Static titleCache (512 entries) with no time-based cleanup of stale entries | 1 | AXWindow.swift:248 |
| 9 | low | OverviewController thumbnailCache cleared only on overview close | 1 | OverviewController.swift:78 |

### Category 4: Threading & Data Races (15 unique findings)

| # | Severity | Finding | Reviewers | Location |
|---|----------|---------|-----------|----------|
| 1 | high | ScreenCoordinateSpace cached transforms: nonisolated(unsafe) statics without synchronization | 3 | CGGeometry+Extensions.swift:67-69 |
| 2 | high | RunLoopJob.action nonisolated(unsafe) with unsynchronized read-write | 2 | RunLoopJob.swift:6-19 |
| 3 | high | SecureInputMonitor CGEventTap callback reads @MainActor state from callback thread | 3 | SecureInputMonitor.swift:40-58 |
| 4 | high | nonisolated(unsafe) MouseEventHandler/MouseWarpHandler _instance accessed from CGEventTap thread | 2 | MouseEventHandler.swift:202, MouseWarpHandler.swift:37 |
| 5 | high | AppDelegate nonisolated(unsafe) static var sharedBootstrap potential data race | 1 | AppDelegate.swift:13 |
| 6 | high | NiriLayoutEngine is a class without thread safety annotations | 2 | NiriLayoutEngine.swift:104 |
| 7 | medium | AccessibilityPermissionMonitor deinit accesses MainActor properties without guarantee | 1 | AccessibilityPermissionMonitor.swift:25-31 |
| 8 | medium | nonisolated(unsafe) test-only static closures on AXWindowService | 2 | AXWindow.swift:186-189 |
| 9 | medium | SleepPreventionManager notification selectors may fire off main actor | 1 | SleepPreventionManager.swift:85-91 |
| 10 | medium | MenuAnywhereController Sendable violation: NSMenu passed to background queue | 1 | MenuAnywhereController.swift:118 |
| 11 | medium | SecureInputMonitor.start() replaces sharedMonitor without stopping previous | 1 | SecureInputMonitor.swift:16-18 |
| 12 | medium | WindowModel lacks @MainActor annotation despite holding mutable state | 1 | WindowModel.swift:48 |
| 13 | medium | DisplayConfigurationObserver MainActor.assumeIsolated in nonisolated init | 1 | DisplayConfigurationObserver.swift:21-23 |
| 14 | low | BorderWindow nextStubWindowId nonisolated(unsafe) static without synchronization | 3 | BorderWindow.swift:19 |
| 15 | low | ThreadGuardedValue unsafelyUnwrapped in release builds: UB if accessed after destroy | 3 | ThreadGuardedValue.swift:29 |

### Category 5: Correctness Bugs (22 unique findings)

| # | Severity | Finding | Reviewers | Location |
|---|----------|---------|-----------|----------|
| 1 | high | cleanupEmptyColumn does not update activeColumnIndex after removing a column | 1 | NiriLayoutEngine+ColumnOps.swift:209-218 |
| 2 | high | normalizeRemainingColumnProportions resets cachedWidth for fixed-width columns | 1 | NiriLayoutEngine+Windows.swift:686-710 |
| 3 | high | NiriConstraintSolver pinning loop may leave windows at 1px when constraints exceed space | 1 | NiriConstraintSolver.swift:100-121 |
| 4 | high | Cached column width used mid-animation causes incorrect position calculations | 1 | NiriLayout.swift:164-175 |
| 5 | high | workspaceBarLabelFontSize hardcoded to 12, ignoring user config | 1 | SettingsStore.swift:550 |
| 6 | high | QuakeTerminal surfaceClosed identifies wrong surface (uses focused, not closed) | 1 | QuakeTerminalController.swift:940-982 |
| 7 | medium | Persisted restore catalog silently drops windows with duplicate/nil titles | 1 | WorkspaceManager.swift:72 |
| 8 | medium | consumeOrExpelWindow uses stale column list after structural changes | 1 | NiriLayoutEngine+ColumnOps.swift:468-589 |
| 9 | medium | insertWindowByMove can reference stale targetIdx after detach | 1 | NiriLayoutEngine+InteractiveMove.swift:239-304 |
| 10 | medium | removeWindow resets ALL column cachedWidths interfering with animations | 1 | NiriLayoutEngine+Windows.swift:160-170 |
| 11 | medium | resolvePresetSpan produces negative values for small available space | 1 | NiriLayout.swift:893-907 |
| 12 | medium | resolveWindowSpans uses wrong preset array for vertical orientation widths | 1 | NiriLayout.swift:852-862 |
| 13 | medium | IPC focusWindowInColumn accepts zero index despite one-based documentation | 1 | IPCCommandRouter.swift:27-29 |
| 14 | medium | moveColumnToIndex inconsistent index base vs focusColumn | 1 | IPCCommandRouter.swift:119-123 |
| 15 | medium | QuakeTerminal center position initialOrigin wrong on non-primary screens | 1 | QuakeTerminalPosition.swift:85-88 |
| 16 | medium | OverviewController overviewInsertPositionToNiri silently inverts direction | 1 | OverviewController.swift:1053 |
| 17 | medium | MonitorOrientationSettings.id is computed/unstable, causing SwiftUI diffing issues | 1 | MonitorOrientationSettings.swift:4-6 |
| 18 | medium | kAXTrustedCheckOptionPrompt: takeRetainedValue on framework constant | 2 | AXTrustedPrompt.swift:4 |
| 19 | medium | AXObserverCreate return not checked; nil observer used silently | 1 | AppAXContext.swift:184-188 |
| 20 | medium | AXObserverAddNotification for miniaturized ignores return value | 1 | AppAXContext.swift:308-310 |
| 21 | medium | OverviewState selectedWindow/hoveredWindow skip bounds checking | 1 | OverviewState.swift:283-293 |
| 22 | low | expelWindowFromColumn animation Y displacement off by gaps amount | 1 | NiriLayoutEngine+ColumnOps.swift:714 |

### Category 6: Force Unwraps & Unsafe Casts (8 unique findings)

| # | Severity | Finding | Reviewers | Location |
|---|----------|---------|-----------|----------|
| 1 | high | Force cast as! AXUIElement on AX API values (6+ locations) | 3 | MenuExtractor:20, MenuAnywhereController:73, WindowActionHandler:147, CommandPaletteController:185,696 |
| 2 | high | Force cast as! AXValue on frame/size values from AX API | 2 | AXWindow.swift:343-344, 734, 742 |
| 3 | medium | Force unwrap .first! in WorkspaceBarDataSource Dictionary grouping | 2 | WorkspaceBarDataSource.swift:235 |
| 4 | medium | Force unwraps newLeft!/newRight! in SplitNode.removing() | 1 | SplitNode.swift:84 |
| 5 | medium | unsafeDowncast in CommandPaletteController (2 locations) | 1 | CommandPaletteController.swift:185, 696 |
| 6 | low | Force unwrap backgroundLayer!/trackingArea! in StatusBarMenu views | 1 | StatusBarMenu.swift:752 |
| 7 | low | Force unwrap trackingArea! immediately after assignment in OverviewWindow | 1 | OverviewWindow.swift:173 |
| 8 | low | Force unwrap on dlopen for CoreFoundation without readable error | 1 | SkyLight.swift:11 |

### Category 7: API Misuse & Deprecations (7 unique findings)

| # | Severity | Finding | Reviewers | Location |
|---|----------|---------|-----------|----------|
| 1 | high | ProcessSerialNumber APIs deprecated since macOS 10.9 | 1 | PrivateAPIs.swift:7-58 |
| 2 | medium | NSApp.activate(ignoringOtherApps:) deprecated in macOS 14+ (6+ call sites) | 2 | AppRulesWindowController, UpdateWindowController, SettingsWindowController, etc. |
| 3 | medium | Unnecessary Task wrapper in MainActor-isolated AXManager.cleanup() | 1 | AXManager.swift:305-309 |
| 4 | medium | Overview window level .screenSaver may block security prompts | 1 | OverviewWindow.swift:37 |
| 5 | medium | Missing screen recording entitlement documentation for CGWindowListCopyWindowInfo | 1 | Entitlements |
| 6 | low | Unnecessary macOS 12.0 availability checks given min target is 15.0 | 1 | Monitor.swift:23 |
| 7 | low | makeKeyWindow constructs raw event bytes with undocumented magic offsets | 1 | PrivateAPIs.swift:33-52 |

### Category 8: Architecture & Design Debt (16 unique findings)

| # | Severity | Finding | Reviewers | Location |
|---|----------|---------|-----------|----------|
| 1 | high | WMController god object: 3.1K lines, 30+ fields, 15 handlers | 2 | WMController.swift |
| 2 | high | clampedFloatingFrame triplication across WMController, WorkspaceManager, RestorePlanner | 2 | 3 files |
| 3 | high | No shared LayoutEngine protocol despite two concrete implementations | 1 | NiriLayoutEngine, DwindleLayoutEngine |
| 4 | medium | WorkspaceManager god class: 3.8K lines combining 8+ responsibilities | 2 | WorkspaceManager.swift |
| 5 | medium | AXEventHandler 3.6K lines -- largest file in controller layer | 1 | AXEventHandler.swift |
| 6 | medium | 15 handlers all hold weak var controller creating circular dependency web | 1 | All handler files |
| 7 | medium | AXEventHandler 13 mutable closure-based injection points | 1 | AXEventHandler.swift:293-326 |
| 8 | medium | Refresh merge matrix: 40+ case switch statement | 2 | LayoutRefreshController.swift:1697-1890 |
| 9 | medium | SkyLight singleton prevents unit testing of all SkyLight-dependent paths | 1 | SkyLight.swift:17 |
| 10 | medium | Layout layer directly calls SkyLight.shared (layer violation) | 1 | TabbedColumnOverlay.swift:540 |
| 11 | medium | Duplicate cancelInteractiveResize in ViewportCommands and Sizing extensions | 1 | NiriLayoutEngine+ViewportCommands.swift, +Sizing.swift |
| 12 | medium | Duplicate isFullscreen and isFullscreenAttributeSet methods | 1 | AXWindow.swift:454-494 |
| 13 | medium | IPCModels.swift 3K lines of manual Codable boilerplate | 1 | IPCModels.swift |
| 14 | low | CommandHandler: 180-line flat switch with no grouping | 1 | CommandHandler.swift:34-217 |
| 15 | low | Silent error swallowing pervasive (empty catch blocks, guard-let-return) | 2 | AXManager.swift:322, LayoutRefreshController.swift:872 |
| 16 | low | Error handling minimal: only 6 custom error types across 84K lines | 1 | Cross-cutting |

### Category 9: Performance (10 unique findings)

| # | Severity | Finding | Reviewers | Location |
|---|----------|---------|-----------|----------|
| 1 | medium | Display links invalidated and recreated instead of paused | 1 | LayoutRefreshController.swift:378-389 |
| 2 | medium | buildWindowSnapshots queries AX size constraints synchronously | 1 | LayoutRefreshController.swift:534-596 |
| 3 | medium | nextSibling/prevSibling O(n) linear scan via firstIndex | 1 | NiriNode.swift:262-275 |
| 4 | medium | monitorContaining/monitorForWorkspace O(n) scans; no reverse index | 1 | NiriLayoutEngine+Monitors.swift:158-174 |
| 5 | medium | OverviewRenderer truncateText O(n^2) for long titles | 1 | OverviewRenderer.swift:466-480 |
| 6 | medium | CTFontCreateWithName called every render frame instead of cached | 1 | OverviewRenderer.swift:203 |
| 7 | medium | collectAllWindows O(n) called repeatedly for simple membership/count queries | 1 | DwindleLayoutEngine.swift:79-89 |
| 8 | medium | ActionCatalog.spec(for:) O(n) linear scan on every call | 1 | ActionCatalog.swift:54-56 |
| 9 | medium | Ring buffers use Array.removeFirst O(n) instead of Deque | 2 | AXEventHandler.swift:584, ReconcileTrace.swift:43 |
| 10 | low | resolveWindowSpans called for tabbed columns even when only one visible | 1 | NiriLayout.swift:724 |

### Category 10: IPC & CLI (5 unique findings)

| # | Severity | Finding | Reviewers | Location |
|---|----------|---------|-----------|----------|
| 1 | high | Blocking POSIX read() inside Swift Concurrency cooperative thread pool | 1 | IPCConnection.swift:57-58 |
| 2 | medium | No read buffer size limit in CLI client (asymmetric with server's 64KB) | 1 | IPCClient.swift:181-203 |
| 3 | medium | IPCServer.stop() races async cleanup with synchronous socket teardown | 1 | IPCServer.swift:99-123 |
| 4 | low | CLI connection close in defer uses fire-and-forget Task | 1 | CLIRuntime.swift:86-92 |
| 5 | low | IPCEventBroker silently drops events with .bufferingNewest(1) | 1 | IPCEventBroker.swift:56 |

### Category 11: UI Issues (7 unique findings)

| # | Severity | Finding | Reviewers | Location |
|---|----------|---------|-----------|----------|
| 1 | medium | Command palette menu loading runs synchronously on main thread | 1 | CommandPaletteController.swift:699-737 |
| 2 | medium | Command palette search filtering with no debouncing | 1 | CommandPaletteController.swift:458-567 |
| 3 | medium | CommandPaletteModePicker hardcoded dark-theme colors | 1 | CommandPaletteController.swift:1380-1436 |
| 4 | medium | NSMenu custom views lack intrinsicContentSize override | 1 | StatusBarMenu.swift:488-537 |
| 5 | medium | WorkspaceBar WindowIconView uses .sheet instead of .popover from floating panel | 1 | WorkspaceBarView.swift:543 |
| 6 | medium | Sponsor avatars loaded from bundle on every SwiftUI body evaluation | 1 | SponsorsView.swift:393 |
| 7 | medium | CleanShot recording overlay detection hardcoded magic window level 103 | 1 | WindowRuleEngine.swift:471 |

### Category 12: Configuration (3 unique findings)

| # | Severity | Finding | Reviewers | Location |
|---|----------|---------|-----------|----------|
| 1 | medium | TOML decode recovery catches all keyNotFound, hiding typos silently | 1 | SettingsTOMLCodec.swift:14-23 |
| 2 | medium | Wake stabilization timeout 30 seconds is excessive | 1 | ServiceLifecycleManager.swift:189 |
| 3 | medium | No debouncing of topology changes; DarkWake causes workspace thrashing | 1 | WorkspaceManager.swift:2163 |

### Category 13: Test Suite Issues (14 unique findings)

| # | Severity | Finding | Reviewers | Location |
|---|----------|---------|-----------|----------|
| 1 | high | fallbackFastFrameForTests calls live SkyLight singleton during tests | 1 | TestSharedStateSupport.swift:146 |
| 2 | high | resetSharedControllerStateForTests modifies real UI singletons | 1 | TestSharedStateSupport.swift:154 |
| 3 | high | IPC tests create real Unix sockets without guaranteed cleanup on crash | 1 | IPCServerTests.swift:144 |
| 4 | high | Polling waitUntil uses Task.yield without real delay, risking busy-loop | 1 | RefreshRoutingTests.swift:333-344 |
| 5 | medium | AXEventHandlerTests NOT marked .serialized despite mutating global singletons | 1 | AXEventHandlerTests.swift:305 |
| 6 | medium | NiriLayoutEngineTests NOT marked .serialized despite shared state mutations | 1 | NiriLayoutEngineTests.swift:351 |
| 7 | medium | makeTestHandle uses random window IDs that could theoretically collide | 1 | NiriLayoutEngineTests.swift:8-14 |
| 8 | medium | Hardcoded sleep in test creates fragile timing dependency | 1 | RefreshRoutingTests.swift:4230 |
| 9 | medium | SettingsFileWatcher tests use Task.sleep for negative assertions | 1 | SettingsStoreTests.swift:1802 |
| 10 | medium | Missing test coverage for error/failure paths in refresh routing | 1 | RefreshRoutingTests.swift |
| 11 | medium | No tests for deep Dwindle tree operations, zero-area screens, Fill Screen | 1 | DwindleLayoutEngineTests.swift |
| 12 | low | 680 lines of helpers before first test case in RefreshRoutingTests | 1 | RefreshRoutingTests.swift |
| 13 | low | fatalError in test fixtures prevents graceful failure reporting | 1 | MouseEventHandlerTests.swift:137 |
| 14 | info | No concurrency stress tests or snapshot/golden-file layout tests exist | 2 | Test suite |

---

## Systemic Patterns

### Pattern 1: `nonisolated(unsafe)` as a concurrency escape hatch (15+ instances)
Used throughout the codebase to bypass Swift strict concurrency checking. While some uses are justified (C callback bridges), many suppress legitimate compiler warnings without providing actual synchronization. Most dangerous in ScreenCoordinateSpace, RunLoopJob, and the CGEventTap callback patterns.

### Pattern 2: Force operations on system API return values (20+ instances)
Force unwraps (`!`), force casts (`as!`), and `unsafeDowncast` are used on values returned from Accessibility, SkyLight, and AppKit APIs. These APIs can return unexpected types from uncooperative apps, during state transitions, or when processes terminate mid-query. All should use conditional casts/unwraps.

### Pattern 3: Test hooks on production types without conditional compilation (30+ properties)
Properties like `*ForTests`, `*HookForTests`, and mutable closure callbacks exist directly on production types with no `#if DEBUG` guard. This pollutes the production API surface, adds runtime overhead (nil checks in hot paths), and risks accidental misuse.

### Pattern 4: Silent error swallowing via guard-let-return (pervasive)
The vast majority of error handling follows `guard let x else { return }` with no logging or diagnostic trail. When operations fail silently, users experience stuck windows or incorrect layouts with no way to diagnose the issue. Only 6 custom error types exist across 84K lines.

### Pattern 5: God objects (3 instances, 10K+ combined lines)
WMController (3.1K), WorkspaceManager (3.8K), and AXEventHandler (3.6K) concentrate too many responsibilities. All handlers depend on WMController via weak back-references, creating implicit dependencies on the entire WM surface area rather than narrow protocol interfaces.

### Pattern 6: Code duplication across subsystem boundaries (4+ instances)
Floating geometry math (clampedFloatingFrame, floatingOrigin, normalizeFloatingOrigin) is copied across 3 files. Fullscreen attribute checking is duplicated. cancelInteractiveResize is duplicated. monitorSortKey is duplicated. These create real risk of behavioral divergence.

### Pattern 7: Ring buffers using Array.removeFirst() O(n) (3+ instances)
Trace buffers in AXEventHandler, ReconcileTrace, and similar use plain Arrays as ring buffers with removeFirst() which is O(n). Should use Deque from swift-collections or circular buffer implementations.

### Pattern 8: Static singletons hindering testability (5+ instances)
SkyLight.shared, OwnedWindowRegistry.shared, SecureInputMonitor.sharedMonitor, and similar singletons make unit testing impossible without global mutation. The BorderWindow.Operations closure-injection pattern exists but is not applied consistently.

---

## Summary Statistics

| Severity | Count |
|----------|-------|
| Critical | 6 |
| High | 35 |
| Medium | 62 |
| Low | 22 |
| Info | 6 |
| **Total unique** | **131** |

| Category | Count |
|----------|-------|
| Production Crash Risks | 11 |
| Memory Safety (UAF/dangling) | 4 |
| Memory Leaks & Retain Cycles | 9 |
| Threading & Data Races | 15 |
| Correctness Bugs | 22 |
| Force Unwraps & Unsafe Casts | 8 |
| API Misuse & Deprecations | 7 |
| Architecture & Design Debt | 16 |
| Performance | 10 |
| IPC & CLI | 5 |
| UI Issues | 7 |
| Configuration | 3 |
| Test Suite Issues | 14 |

**Multi-reviewer findings** (higher confidence): 23 findings were independently discovered by 2+ reviewers. The highest-confidence findings (3 reviewers each): fatalError in defaultWorkspaceId, NSScreen.screens.first! crash, ScreenCoordinateSpace thread safety, SkyLight.orderWindow fatalError, SecureInputMonitor thread safety, and ThreadGuardedValue release-build UB.
