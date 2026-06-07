# SUPERSEDED — This spec described the gate-based settle-then-correct approach.
# Abandoned after 8 tests showed it violated Phase 1's accept-and-adapt principle.
# See final design below.

# Fix C: Sleep/Wake Restore — Final Design (2026-06-07)

## Bug
#2: Windows migrate to wrong monitor/workspace after sleep/wake.

## Scope
Restore the user's pre-sleep desktop state:
- Windows on correct workspace + display
- Active workspace per monitor
- Niri column order and widths
- Dwindle split positions
- Focused window
- Floating window geometry

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
5. **Final restore (15s or 18s)**: authoritative workspace assignment + active workspace per monitor + Niri placement remap + viewport/focus + floating frames.
6. **DarkWake**: 30s timeout, no display events -> cancel.

## Matching Cascade (for recycled window IDs)
1. Exact token (pid + windowId)
2. PID + title match
3. PID + frame size match (within 50px)
4. PID + same workspace
5. PID + first available

matchedTokens set prevents double-matching.

## Phase Impact
None. Phase 1-5 + AB unaffected. Phase 5a restored to original ~100ms scope.

## Remaining Work
- Column order within workspaces (both Niri and Dwindle)
- Focus restoration after finalization rescan
- Dwindle split position snapshot (no equivalent to Niri placements)

## Test Results (test 16)
- 10/10 windows tracked
- 10/10 correct workspace + display
- Active workspaces restored
- Progressive restore: ticks corrected 3 windows, finalization rescan re-discovered 10 missing
