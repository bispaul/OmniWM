# Hiro Holistic Architecture Overhaul

**Date:** 2026-06-05 (revised after 3-expert review)
**Branch:** `fix/scope-relayout-to-workspace`
**Replaces:** All previous per-fix specs from this session
**Review:** Approved with changes by macOS platform architect, software architect, and devil's advocate

## Background

Hiro has 14 identified architectural gaps across 4 subsystem clusters. Research into 6 window managers (niri, yabai, Rectangle, Amethyst, MangoWM, AeroSpace) reveals that Hiro's core problems stem from 5 wrong architectural assumptions, not from missing features. Fixing the assumptions eliminates most bugs as side effects.

## 5 Architectural Principles

### Principle 1: Never Fight the App

**Current:** Write frame → verify → retry same frame → loop
**Target:** Write frame → accept observedFrame → update column width → relayout others

yabai explicitly says: "Attempting to check the window frame cache is not reliable." Rectangle writes once and accepts the result. Retrying semantic frame rejections (verificationMismatch) is architecturally wrong. AX transport errors (cannotComplete, timeout) should be retried with bounded backoff since the AXUIElement reference remains valid.

**Changes:**
- `shouldRetryFrameWrite()`: return `false` for `.verificationMismatch`. Keep retry for `.sizeWriteFailed`, `.staleElement`, `.cacheMiss`.
- **New failure reason:** Add `.appBusy` (mapped from `kAXErrorCannotComplete`) distinct from `.staleElement` (mapped from `.invalidUIElement` only). Retry `.appBusy` with exponential backoff (100ms/200ms/400ms, max 3 attempts).
- `handleFrameApplyResults()`: on verificationMismatch, accept `observedFrame` as `lastAppliedFrame`, call `onFrameAcceptedAtDifferentSize` callback
- `AXManager`: add `onFrameAcceptedAtDifferentSize: ((Int, CGRect) -> Void)?` callback
- Wire callback in WMController: update column `cachedWidth` from observed width, mark workspace dirty
- The `onFrameAcceptedAtDifferentSize` callback uses `requestRelayout` (coalesced), NOT `requestImmediateRelayout` — mismatch acceptance is app-initiated, not user-initiated
- Keep verification tolerance at 1.0px. If specific apps need larger tolerance, use `WindowCapabilityProfile` for per-app overrides rather than a global increase.

**Convergence Mechanism (revised after production testing, build 69):**

~~Settling gate and adaptation counter were removed.~~ Production testing with Chrome revealed that the settling gate (2 consecutive stable reads) and adaptation counter (3 changes in 500ms → permanent pin) were harmful in every scenario: Chrome's stable 4px height preference got pinned during startup, blocking all future adaptation permanently. Same-window oscillation cannot occur in Niri's scrolling layout because the accepted width becomes the column width — subsequent frame writes match what the app asked for. The `requestRelayout` coalescing (8ms debounce) provides sufficient dedup for rapid changes.

**What remains:**
1. **Minimum size floor:** `let acceptedWidth = max(observedFrame.width, effectiveMinimumWidth(for: windowToken))` before updating `cachedWidth`. Enforces existing `ResizePlaceholderState.minimumSize` and user-configured `minWidth` from app rules.
2. **Batch before reflow:** `handleFrameApplyResults` processes ALL results from a single `applyFramesParallel` batch before triggering any reflow. The callback fires per-result; `requestRelayout` coalescing merges them into one relayout.
3. **Space guard:** Before accepting, verify the window is not in `inactiveWorkspaceWindowIds`. If on another workspace, skip acceptance and preserve previous `cachedWidth`.
4. **Feature flag:** `acceptAndAdaptEnabled: Bool` (default true) for fallback to old retry behavior.

**Architectural lesson:** The convergence mechanism was designed from theory (what if apps oscillate?) rather than observation (what do apps actually do?). The 3-expert review validated against bug scenarios but not against normal startup and user-initiated operations. Future guards should be added only after observing the specific failure mode in production, not preemptively.

**Phase 1b (DONE):** Cooldown/suppression band-aids removed. Accept-and-adapt proven stable with Chrome, Ghostty, and Electron apps — zero mismatch loops, zero flutter in production. Feature flag `acceptAndAdaptEnabled: Bool` (default true) retained for rollback safety.

**Keeps:** Retry for actual AX errors (`.sizeWriteFailed`, `.appBusy`, `.cacheMiss`). Resize placeholder for `sizeWriteFailed`.

**Failure modes:** If `cachedWidth` update fails (workspace lookup nil, window removed during AX write), use last-known-good width. If `observedFrame` is nil, stop — don't accept, don't retry.

**Bugs eliminated:** #1 (frame write race), #11 (Chrome too small), #17 (verificationMismatch loops), #12 (convergence — immediate acceptance + coalesced relayout)

### Principle 2: Dirty Flag + Batched Reflow

**Current:** Each frame-change AX notification triggers an immediate relayout
**Target:** Frame-change notifications mark workspace dirty. Dirty workspaces reflow once per refresh cycle.

Amethyst discovered mouse and AX events are "in no way synchronized." Reacting to each individual event causes cascading reflows.

**Changes:**
- `AXEventHandler.handleFrameChanged()`: instead of `requestRelayout()`, call `markWorkspaceDirty(wsId)` on LayoutRefreshController
- LayoutRefreshController: add `dirtyWorkspaceIds: Set<WorkspaceDescriptor.ID>`. On next refresh cycle, reflow all dirty workspaces at once.
- **Hiro-initiated vs app-initiated boundary:** Hiro-initiated actions (Hiro hotkey bindings, Hiro gesture recognizer, Hiro interactive move/resize) remain IMMEDIATE via `requestImmediateRelayout`. User actions on applications (clicking app UI, resizing via app controls, using app menus) are observed by Hiro as app-initiated AX events and follow the batched path.
- **Batch interval:** Dirty workspaces reflow on the next CADisplayLink tick (~16ms at 60Hz). Multiple AX notifications arriving within the same run loop iteration are coalesced into a single dirty-mark. Near-zero-latency dedup without visible delay.

**Failure modes:** If dirty flag is set for a workspace that gets destroyed before next refresh, validate workspace exists before reflow (skip deleted workspaces).

**Bugs eliminated:** #10 (admission dedup — multiple admissions become one dirty+reflow), #14 (event ordering — order doesn't matter when batched), cascading relayout loops

### Principle 3: Viewport as First-Class Camera

**Current:** Ad-hoc viewport positioning mixed into each operation
**Target:** Viewport is a camera with anchor preservation + policy stack applied after layout computation

niri invariant: **"the focused window must not move visually"** when non-focused columns change.
Priority hierarchy (from MangoWM): **overspread > centerFocused > fit**

**Changes:**

**Step 0 — Anchor Preservation (pre-condition, not a policy):** Before applying the policy stack, compute delta between focused column's new position and old position. Adjust viewport offset by this delta to maintain visual anchor. This ensures niri's invariant (focused window does not move visually) regardless of which policy runs afterward. The existing `preserveViewportAnchor` in `focusNeighbor` is formalized as this step.

**Policy Stack (applied ONCE after each layout computation during reflow):**
- `.overspread`: When ALL columns fit (totalWidth < viewportWidth), center the column group. Highest priority.
- `.centerFocused`: Respects `centerFocusedColumn` setting (.never, .always, .onOverflow). Medium priority.
- `.fit`: Minimal scroll to keep focused column visible. Default/lowest priority.

- Remove `applyOverspreadIfNeeded` calls from individual operations (toggleFullscreen, cycleSize, etc.)
- The viewport pipeline (Step 0 + policy stack) runs in LayoutRefreshController after frame computation, before frame application

**Failure modes:** If viewport state is inconsistent (no columns), skip policy application.

**Bugs eliminated:** #1 (overspread), #3 (snap/center/alignment — separated as policies), #6 (viewport gap — fit policy ensures focused column visible)

### Principle 4: Classify Before Admitting

**Current:** Every AX window enters WorkspaceManager, filtered after admission
**Target:** Classification pipeline runs BEFORE window enters state

Classification checks (in order):
1. Is it our own window? → reject
2. Role/subrole check (from AX attributes) → dialog, popup → float or reject
3. Dialog heuristic: no fullscreen button → float (AeroSpace pattern, with terminal app exceptions)
4. For Chrome: filter internal renderer windows — these have no `kCGWindowName` in `CGWindowListCopyWindowInfo` and high window IDs. The existing `fullRescanEnumerationSnapshot` already filters by layer==0 and alpha>0; add name-based filtering.
5. User app rules → ALWAYS override any classification
6. Default: admit as tiling

**Escape hatch:** If a user rule says "tile" but the window fails AX position/size writes 3 times consecutively, auto-demote to floating with a user-visible log warning.

**Note on Ghostty tabs:** Ghostty tabs are handled normally — Ghostty is a standard app with one AX window per tab group. The Caps+H/L navigating through tabs issue was a side effect in a previous build, not an architectural problem. No special tab detection needed.

**Changes:**
- Add `WindowClassifier` that runs in `prepareCreateCandidate()` before `WindowRuleEngine`
- Check AX attributes for role, subrole, dialog indicators
- Check `CGWindowListCopyWindowInfo` for `kCGWindowName`, `kCGWindowLayer` to filter Chrome internal windows
- User rules ALWAYS override classification

**Failure modes:** If AX attribute queries fail during classification (role/subrole unavailable), classify as floating (safe default — a window whose role cannot be determined is likely a dialog or transient window).

**Bugs eliminated:** #11 (window classification), #19 (Chrome internal windows)

### Principle 5: State Reconciliation on Topology Events

**Current:** 7 state stores that can silently diverge:
1. WorkspaceManager workspace-display bindings
2. LayoutRefreshController workspace state
3. AXManager window-PID mappings
4. NiriLayoutHandler column trees
5. ViewportState per-workspace offsets
6. FocusPolicyEngine focus leases
7. RestorePlanner persisted catalog

**Target:** Topology events (monitor connect/disconnect, sleep/wake) trigger full atomic state reconciliation.

**Changes:**
- On sleep: save expected monitor UUIDs.
- On wake: **Progressive topology matching:**
  1. Start polling at 500ms intervals
  2. On each tick, check if `NSScreen.screens` matches the expected set
  3. Reconcile when all monitors are present OR after a 15s hard timeout
  4. On `didChangeScreenParametersNotification` during the wait, re-check immediately
  This handles both fast reconnections (USB-C direct, 1-2s) and slow ones (Thunderbolt dock, 8-10s).
- **Reconciliation atomicity:** Do NOT null state eagerly. Build the new assignment plan alongside old state, then perform an atomic swap (old → new) in a single synchronous MainActor step after monitors are confirmed. No intermediate torn-down state observable by event handlers.
- **Reconciliation guard:** Introduce `isReconciling: Bool` on WorkspaceManager. Event handlers (handleFrameChanged, handleWindowCreated, handleAppActivated) early-return during reconciliation.
- RestorePlanner: rule engine decisions override persisted catalog (fixes catalog poisoning)
- Focus lease: scope `nativeAppSwitch` lease to the monitor where the window's frame is actually located

**Failure modes:** If monitors never appear after 15s timeout, proceed with available monitors and reassign orphaned workspaces to primary display. If App Nap deactivates an app during fullRescan, check `NSRunningApplication.isActive` before removing windows — preserve entries for recently-active napped apps (within 60s).

**Bugs eliminated:** #5 (sleep/wake wrong monitor), #6 (scoped focus lease), #8 (catalog poisoning), #13 (state reconciliation)

## Dwindle Layout Considerations

- **Principle 1:** Applies to Dwindle but updates **split ratios** instead of column `cachedWidth`. The convergence mechanism applies identically (split ratio oscillation is the Dwindle analog of cachedWidth oscillation).
- **Principle 2:** Applies identically — dirty flag is layout-engine-agnostic.
- **Principle 3:** Does NOT apply to Dwindle. Dwindle fills the entire screen by design — no scrolling viewport, no viewport camera, no policy stack. Dwindle windows always have their position fully determined by the binary split tree.
- **Principle 4:** Applies identically.
- **Principle 5:** Applies identically.

## Implementation Order

| Phase | Principle | Scope | Dependencies | Notes |
|---|---|---|---|---|
| **Phase 1** | Never Fight the App | AXManager, NiriLayoutHandler, DwindleLayoutHandler | None | **DONE (build 72).** Accept-and-adapt with immediate callback. Width-change guard prevents position/height loops. |
| **Phase 1b** | Remove cooldowns | AXManager, AXEventHandler | Phase 1 proven stable | **DONE (build 72).** Cooldowns removed — accept-and-adapt handles all cases. |
| **Phase 2** | Dirty + Reflow | AXEventHandler, LayoutRefreshController | Phase 1 | **DONE.** App-initiated AX events mark workspaces dirty; drain on CADisplayLink tick coalesces to single reflow. |
| **Phase 3** | Viewport Camera | ViewportState, NiriLayoutHandler | Phase 1 required, Phase 2 recommended | Viewport policies are pure functions of layout state. |
| **Phase 4** | Classify Before Admit | AXEventHandler, WindowRuleEngine | Independent, after core pipeline stable | |
| **Phase 5** | State Reconciliation | WorkspaceManager, ServiceLifecycleManager, FocusPolicyEngine | All other phases | Reconciles the full state atomically. |

Each phase produces a working, testable system. Tests can be written per-phase.

## What Gets Reverted (from this session)

- `applyOverspreadIfNeeded` calls from individual toggle/resize operations (moved to viewport policy stack in Phase 3)
- Cooldown/suppression code — **removed in Phase 1b** (accept-and-adapt proven stable)
- Settling gate + adaptation counter + permanent pinning — **removed** (over-engineered, harmful in production)

## What Stays (from this session)

- Scoped relayout (affectedWorkspaceIds) — correct, independent of these principles
- Tiered visibility (sliver) — correct for off-viewport columns
- focusNeighbor preserveViewportAnchor — formalized as Step 0 of viewport pipeline
- Overspread method on ViewportState — will be called from viewport policy stack
- Logging + privacy annotations — essential for debugging
- Scoping tests — still valid

## Platform Compatibility

- **Stage Manager:** On startup, detect via `defaults read com.apple.WindowManager GloballyEnabled`. If active, log a warning and operate in floating-only mode. Stage Manager is unsupported for tiling.
- **enhancedUserInterface:** Check and temporarily disable this AX property before frame writes for apps that set it (Rectangle pattern). Re-enable after write.

## Success Criteria

**Architectural Guarantees (design makes these impossible):**
- Zero verificationMismatch retry loops
- Chrome internal windows not admitted
- No cascading relayout from app-initiated frame changes

**Behavioral Improvements (design makes these unlikely but dependent on app behavior):**
- No window shifting after toggle operations
- Chrome/Ghostty render at preferred size without fighting
- Sleep/wake restores windows to correct monitors
- Cross-monitor app activation doesn't steal focus
- Viewport gaps filled when all columns fit
- All existing tests pass + new tests per phase
