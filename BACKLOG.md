# OmniWM/Hiro Fork — Unified Backlog

> Generated 2026-06-04. Sources: field bug tracker (17 bugs), expert code review (131 findings), scrolling WM research (MangoWM/Rift/Paneru).

## Legend

- **Source**: `BUG#N` = field bug, `REV` = code review, `RES` = research feature
- **Status**: open, partial, blocked
- **Confidence**: number of independent reviewers (for REV items)

---

## P0 — Critical (Production Crashes & Use-After-Free)

| # | Title | Source | File:Line | Description | Fix |
|---|-------|--------|-----------|-------------|-----|
| 1 | `fatalError` in `defaultWorkspaceId` | REV ×3 | WMController.swift:1195 | Crashes entire WM when no workspace can be resolved during monitor hotplug or corrupt settings | Replace with on-demand workspace creation or return Optional |
| 2 | `NSScreen.screens.first!` force unwrap | REV ×3 | QuakeTerminalController.swift:800 | Crashes during sleep/wake, KVM, clamshell when macOS reports zero screens | `NSScreen.main ?? NSScreen.screens.first ?? fallback` |
| 3 | HotkeyCenter dangling pointer — deinit doesn't unregister Carbon handler | REV ×1 | Hotkeys.swift:288 | `Unmanaged.passUnretained` callback fires on deallocated object. `MainActor.assumeIsolated` in deinit UB if off main thread | Add `RemoveEventHandler` in deinit; remove assumeIsolated |
| 4 | QuakeTerminal `Unmanaged.passUnretained` use-after-free | REV ×1 | QuakeTerminalController.swift:104 | C callbacks from Ghostty dispatch async using unretained pointer; if controller deallocated first → dangling | Use `passRetained` with explicit release, or weak wrapper |
| 5 | Dwindle Fill Screen → NaN via division by zero | REV ×2 | DwindleLayoutEngine.swift:736 | `CGSize(0,0)` produces NaN propagating into CGRect, corrupts layout or crashes CoreGraphics | Guard for fill case in `applyResolvedSettings`, clamp to non-zero |
| 6 | `SkyLight.orderWindow` fatalError on transaction failure | REV ×3 | SkyLight.swift:323 | Every other transaction method handles nil gracefully; this one crashes during sleep/wake | Replace with guard-return + warning log |

## P1 — High (Data Races, Memory Leaks, Correctness)

| # | Title | Source | File:Line | Description | Fix |
|---|-------|--------|-----------|-------------|-----|
| ~~7~~ | ~~CGS region leak on border redraw~~ **REVERTED — FINDING WAS WRONG** | REV ×2 | SkyLight.swift:641-682 | SkyLight's `newWindow()` and `setWindowShape()` TAKE OWNERSHIP of the region. Adding cfRelease was a double-free that crashed the app on startup. Code review finding #7 was incorrect — there is no leak. | N/A — original code was correct |
| 8 | CADisplayLink retain cycles (2 locations) | REV ×1 | LayoutRefreshController.swift:231, OverviewAnimator.swift:89 | `target:self` creates strong ref cycle; neither can deallocate | Weak-proxy NSObject as display link target |
| 9 | ScreenCoordinateSpace thread-unsafe cache | REV ×3 | CGGeometry+Extensions.swift:67-69 | 3 `nonisolated(unsafe)` statics read/written from MainActor + AX threads simultaneously | Protect with `OSAllocatedUnfairLock` or restrict to @MainActor |
| 10 | `RunLoopJob.action` data race | REV ×2 | RunLoopJob.swift:7 | `action` read/written from multiple threads without synchronization; atomic `_cancelled` doesn't protect | Protect with `OSAllocatedUnfairLock` |
| 11 | `nonisolated(unsafe)` MouseEventHandler/MouseWarpHandler singletons | REV ×2 | MouseEventHandler.swift:202, MouseWarpHandler.swift:37 | CGEventTap callbacks use `MainActor.assumeIsolated` but Apple doesn't guarantee main thread for all events | Dispatch to main thread explicitly |
| 12 | SecureInputMonitor CGEventTap reads @MainActor state from callback thread | REV ×3 | SecureInputMonitor.swift:40-58 | Thread-unsafe access to MainActor-isolated properties from C callback | Dispatch to main or use synchronization |
| 13 | `cleanupEmptyColumn` doesn't update `activeColumnIndex` | REV ×1 | NiriLayoutEngine+ColumnOps.swift:209-218 | After removing a column, activeColumnIndex may point to wrong or out-of-bounds column | Update index after removal |
| 14 | `normalizeRemainingColumnProportions` resets fixed-width columns | REV ×1 | NiriLayoutEngine+Windows.swift:686-710 | Normalization resets `cachedWidth` for columns that should have fixed widths | Skip columns with explicit fixed-width setting |
| 15 | NiriConstraintSolver pinning leaves windows at 1px | REV ×1 | NiriConstraintSolver.swift:100-121 | When constraints exceed available space, windows can be pinned to minimum 1px | Add minimum viable size floor |
| 16 | Cached column width mid-animation causes wrong positions | REV ×1 | NiriLayout.swift:164-175 | Layout reads cachedWidth during animation but animation hasn't updated it yet | Use animated width during animation, cached width otherwise |
| 17 | QuakeTerminal `surfaceClosed` identifies wrong surface | REV ×1 | QuakeTerminalController.swift:940-982 | Uses focused surface instead of the actually-closed surface | Track closed surface explicitly |
| 18 | Force cast `as! AXUIElement` on AX API values (6+ locations) | REV ×3 | MenuExtractor:20, WindowActionHandler:147, CommandPaletteController:185,696 | Apps can return unexpected types; force cast crashes | Use `as?` conditional cast |
| 19 | Force cast `as! AXValue` on frame/size values | REV ×2 | AXWindow.swift:343-344, 734, 742 | AX values can be nil or wrong type during app transitions | Use conditional cast with fallback |
| 20 | Blocking POSIX `read()` inside Swift Concurrency cooperative pool | REV ×1 | IPCConnection.swift:57-58 | Blocks cooperative thread; can starve other tasks | Move to DispatchIO or NIO |
| 21 | Int-to-Int32 narrowing for large window IDs | REV ×1 | SkyLight.swift:293,533 | Window IDs >2^31 would silently truncate | Use Int32 clamping with error handling |
| 22 | `@testable import` in production app target | REV ×1 | OmniWMApp.swift:2 | Bypasses access control in production binary | Move to test target only |

## P2 — Open Bugs (Field-Observed)

| # | Title | Source | Status | Description | Fix Path |
|---|-------|--------|--------|-------------|----------|
| 23 | Sleep/wake window migration + frame write storm (bugs #2 + #9) | BUG#2/#9 | partial | Windows migrate to wrong monitor on wake. Build 58 debouncing reduced storm (14→4 rescans) but core problem persists: rescan fires before 32" reconnects (160ms gap). **Confirmed still happening 2026-06-04 21:49:** Chrome windows admitted to 27" (displayId:2) instead of 32" (displayId:3), one Chrome filled left half with right half empty. Bug #9 was prematurely marked FIXED — corrected to PARTIALLY FIXED. | Delay rescan until ALL expected monitors reconnect, OR preserve column widths across re-admission, OR Rift's null-stale-display-state approach (#49) |
| 24 | Z-order not preserved after workspace transition | BUG#4 | open | Window stacking order lost during re-tile; last frame write wins top position | Track and restore z-order via `SkyLight.orderWindow` during relayout |
| 25 | Columns don't fill gap after minimize (partial) | BUG#7 | partial | Redistribution works for close but regressed for minimize — move/consume ops triggered unwanted normalization | Scope normalization to user-initiated close only; consider MangoWM overspread approach (see #41) |
| 26 | Focus right jumps to vertically stacked monitor | BUG#10 | open | Caps+L at rightmost column jumps to 32" above instead of stopping; may go through `focusMonitorNext` not `focusNeighbor` | Add debug logging to trace dispatch path; filter by monitor geometry direction |
| 27 | Restart sets tiled to floating (part 2 — heuristic windows) | BUG#12 | partial | Windows without explicit `layout = "tile"` rule still get poisoned via persisted catalog | Prevent `floatingGeometryUpdated` from re-saving `restoreToFloating=true` for tiled windows |
| 28 | `floatingGeometryUpdated` re-poisons catalog on toggle | BUG#16 | open | Caps+Space toggle fires `floatingGeometryUpdated(restoreToFloating: true)` before mode change, re-poisoning catalog | Don't emit restoreToFloating for windows being toggled back to tiling; clear poisoned entry on mode→tiling |
| 29 | `verificationMismatch` loops for WhatsApp | BUG#17 | open | Bug #1 fix (skippedSameFailedFrame) fails because each relayout produces slightly different target frame | Cooldown timer: suppress writes for windowId for 500ms after ANY verificationMismatch regardless of frame value |
| 30 | Test isolation — SkyLight creates visible borders during tests | BUG#3 | open | `swift test` creates real SkyLight border windows on desktop | Extract SkyLight singleton behind protocol for mocking |

## P2 — Medium Code Review Findings

| # | Title | Source | File:Line | Description | Fix |
|---|-------|--------|-----------|-------------|-----|
| 31 | Miniaturize handler: unstructured Task with 300ms sleep, no cancellation | REV ×1 | AXEventHandler.swift:1660 | Multiple tasks accumulate on rapid minimize/unminimize | Track pending task per window token; cancel on un-minimize |
| 32 | Per-window dictionaries grow without periodic pruning | REV ×1 | AXEventHandler.swift:304-307 | `stabilizationRetryCount`, `createdWindowRetryCountById` etc. accumulate stale entries | Prune on full rescan; remove entries for dead PIDs |
| 33 | CADisplayLink invalidated/recreated instead of paused | REV ×1 | LayoutRefreshController.swift:378-389 | Unnecessary kernel round-trips on every animation cycle | Use `isPaused` / add-remove from RunLoop |
| 34 | Refresh merge 40+ case state machine | REV ×2 | LayoutRefreshController.swift:1697-1890 | Combinatorial (existingKind × incomingKind) with duplicated logic | Refactor to priority-based merge with declarative rules |
| 35 | `SleepPreventionManager` singleton: observers never removed | REV ×2 | SleepPreventionManager.swift:70-82 | Registered NSWorkspace observers leak for app lifetime | Add `deinit` or explicit `stop()` |
| 36 | Static `pinnedElements` holds AXUIElement refs without eviction | REV ×1 | AXWindow.swift:199 | Refs to dead windows accumulate | Prune on full rescan or PID death |
| 37 | `NSApp.activate(ignoringOtherApps:)` deprecated in macOS 14+ (6 sites) | REV ×2 | Multiple UI files | API removed in future macOS | Replace with `NSApp.activate()` (modern API) |
| 38 | `ProcessSerialNumber` APIs deprecated since macOS 10.9 | REV ×1 | PrivateAPIs.swift:7-58 | Ancient Carbon APIs still in use | Replace with NSRunningApplication equivalents |
| 39 | `buildWindowSnapshots` queries AX constraints synchronously | REV ×1 | LayoutRefreshController.swift:534-596 | Blocking AX queries in layout hot path | Batch or cache constraint queries |
| 40 | TOML decode recovery catches all `keyNotFound`, hiding typos | REV ×1 | SettingsTOMLCodec.swift:14-23 | User typos in config silently ignored | Log unknown keys as warnings |

## P2 — Research Features (MangoWM / Rift / Paneru)

| # | Title | Source | Inspiration | Description | Benefit |
|---|-------|--------|-------------|-------------|---------|
| 41 | Overspread viewport mechanism | RES | MangoWM | When total column width < viewport, edge columns auto-fill remaining space via boolean toggle (`scroller_prefer_overspread`, default on) | Solves bug #25 (gap-filling) without algorithmic redistribution; viewport display concern, not column-width mutation |
| 42 | Independent per-column proportions (no resize cascade) | RES | MangoWM + Rift + Paneru | Each column stores its own proportion; resize only changes focused column, neighbors just reposition. MangoWM: `scroller_proportion` per node. Rift: clamped `column_width_ratio` (0.3–0.9) | Eliminates cascading relayout that triggers verificationMismatch on unrelated windows; reduces frame writes by ~70% on resize |
| 43 | Viewport priority hierarchy | RES | MangoWM | Explicit priority: overspread > focus_center > prefer_center. Higher must be disabled for lower to work | Replaces ad-hoc viewport conditionals with clean, user-configurable priority system |
| 44 | Snap strip + center selection separation | RES | Rift | Three distinct operations: `snap_strip` (snap to nearest column boundary, persistent), `center_selection` (temporary centering override, toggle), `alignment` (persistent L/C/R) | Cleaner architecture than mixing snapping/centering/alignment in same code paths |
| 45 | Focus navigation styles (niri vs anchored) | RES | Rift | Two modes: "niri" (reveal columns on demand based on nav direction) vs "anchored" (always align focused column per alignment setting) | User choice for viewport behavior during navigation; currently Hiro only has one mode |
| 46 | Sliver workaround for off-screen windows | RES | Paneru | Keep 5px visible sliver at screen edge for off-screen columns. macOS forcibly relocates fully off-screen windows — sliver prevents this | Eliminates verificationMismatch root cause for off-viewport windows; removes need for retry/backoff complexity |
| 47 | Clamped resize bounds | RES | Rift | Configurable min/max column width ratio (default 0.3–0.9). Resize clamped to bounds | Prevents extreme resize states that trigger app-level "too small to render" errors |
| 48 | No-resize-on-open policy | RES | Paneru | Adding a new window to strip never resizes existing windows | Prevents viewport disruption during window creation |
| 49 | Null stale display state early in screen-change handler | RES | Rift v0.4.1 | Null out workspace-display bindings before reassignment logic runs (PR #334) | Prevents cascading re-admission during DarkWake (addresses bug #23) |

## P3 — Low Priority & Nice-to-Have

| # | Title | Source | File:Line | Description |
|---|-------|--------|-----------|-------------|
| 50 | `nextSibling`/`prevSibling` O(n) linear scan | REV ×1 | NiriNode.swift:262-275 | Uses `firstIndex` for linked-list-style navigation |
| 51 | `monitorContaining`/`monitorForWorkspace` O(n) scans | REV ×1 | NiriLayoutEngine+Monitors.swift:158-174 | No reverse index for monitor→workspace lookup |
| 52 | `collectAllWindows` O(n) called for simple count queries | REV ×1 | DwindleLayoutEngine.swift:79-89 | Collects all windows just to count them |
| 53 | `ActionCatalog.spec(for:)` O(n) linear scan | REV ×1 | ActionCatalog.swift:54-56 | Called on every action dispatch |
| 54 | Ring buffers use `Array.removeFirst()` O(n) | REV ×2 | AXEventHandler.swift:584, ReconcileTrace.swift:43 | Should use Deque from swift-collections |
| 55 | `OverviewRenderer.truncateText` O(n²) | REV ×1 | OverviewRenderer.swift:466-480 | String truncation with repeated measurement |
| 56 | `CTFontCreateWithName` called every render frame | REV ×1 | OverviewRenderer.swift:203 | Should cache font object |
| 57 | Test hooks on production types without `#if DEBUG` (30+ properties) | REV ×2 | Multiple files | `*ForTests`, `*HookForTests` pollute production API |
| 58 | God objects: WMController (3.1K), WorkspaceManager (3.8K), AXEventHandler (3.6K) | REV ×2 | 3 files | Too many responsibilities per class |
| 59 | `clampedFloatingFrame` triplication | REV ×2 | WMController, WorkspaceManager, RestorePlanner | Same floating geometry math in 3 files |
| 60 | Duplicate `isFullscreen` / `isFullscreenAttributeSet` methods | REV ×1 | AXWindow.swift:454-494 | Two methods doing the same thing |
| 61 | Duplicate `cancelInteractiveResize` | REV ×1 | NiriLayoutEngine+ViewportCommands, +Sizing | Same method in two extensions |
| 62 | No shared `LayoutEngine` protocol | REV ×1 | NiriLayoutEngine, DwindleLayoutEngine | Two concrete implementations with no shared interface |
| 63 | `IPCModels.swift` 3K lines of manual Codable boilerplate | REV ×1 | IPCModels.swift | Could use code generation |
| 64 | Command palette search: no debouncing | REV ×1 | CommandPaletteController.swift:458-567 | Filters on every keystroke |
| 65 | CommandPaletteModePicker hardcoded dark-theme colors | REV ×1 | CommandPaletteController.swift:1380-1436 | Doesn't respect system appearance |
| 66 | Silent error swallowing pervasive (empty catch, guard-return) | REV ×2 | Cross-cutting | Only 6 custom error types across 84K lines |
| 67 | Static singletons blocking testability (SkyLight, OwnedWindowRegistry, etc.) | REV ×2 | Multiple files | Need protocol extraction for testing |
| 68 | Overview `.screenSaver` window level may block security prompts | REV ×1 | OverviewWindow.swift:37 | Could interfere with system dialogs |
| 69 | `BorderWindow.nextStubWindowId` nonisolated(unsafe) static | REV ×3 | BorderWindow.swift:19 | Low-risk but technically a data race |
| 70 | Unnecessary `@available(macOS 12.0, *)` checks (min target is 15.0) | REV ×1 | Monitor.swift:23 | Dead code |

---

## Summary

| Priority | Count | Breakdown |
|----------|-------|-----------|
| P0 Critical | 6 | 6 REV (crashes + use-after-free) |
| P1 High | 16 | 16 REV (data races, memory, correctness) |
| P2 Bugs | 8 | 8 BUG (field-observed, partial/open) |
| P2 Code | 10 | 10 REV (medium findings) |
| P2 Features | 9 | 9 RES (MangoWM/Rift/Paneru ideas) |
| P3 Low | 21 | 19 REV + 2 systemic |
| **Total** | **70** | |

### Quick Wins (< 1 hour each)
- #1 fatalError → Optional (5 min)
- #2 force unwrap → optional chain (5 min)
- #6 fatalError → guard-return (5 min)
- #7 CGS region leak → defer CFRelease (10 min)
- #21 Int32 narrowing → clamped (10 min)
- #22 @testable → test target (5 min)
- #37 deprecated activate → modern API (15 min)
- #70 dead availability checks → remove (5 min)

### High-Impact Features (from research)
- #42 Independent proportions — biggest architectural win, eliminates resize cascade
- #46 Sliver workaround — eliminates verificationMismatch for off-viewport windows
- #41 Overspread — clean solution for gap-filling (bug #25)
- #49 Null stale display state — addresses sleep/wake migration (bug #23)
