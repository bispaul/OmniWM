# CLAUDE.md — Hiro (OmniWM) Tiling Window Manager

## Project

Swift 6.3 macOS tiling WM. Fork at `bispaul/OmniWM`, clone at `~/Documents/Personal/github/OmniWM`.
**Upstream (BarutSRB/Hiro) released v0.4.9.7 (2026-06-10).** Fork is the primary codebase. GhosttyKit updated to v0.4.9.7. Upstream analysis: 4 adoptable ideas (AXFrameApplicationLedger, AX rekey, Hyper key, bezier motion). Memorygraph `64426c1b`.
Branch: `fix/scope-relayout-to-workspace`. Build 106. PID check: `pgrep -x OmniWM`.
**Build:** `make build-sign` (auto-signs with dev cert). `make sign` to re-sign existing binary.

### Architecture Status
Phase 1-5 + Fix A/B/C/E done. Fix D blocked. Flutter Phase 4.5 STOP. All 5 god node extractions done.
**5 SSOT invariants missing** (memorygraph `6ab03ce1`): ALL investigated, ALL upstream behavior.
**Hydration matching (SSOT #6)**: FIXED (build 98). Fallback metadata populated from evaluation.facts + AXWindowService.titlePreferFast. Hydration scoped to admission events only (0 noMatch spam). Two-restart migration — first restart saves enriched catalog, second restart restores window positions.
1. **Window identity**: FIXED (build 95). WorkspaceAssignmentManager with recently-removed cache (2s TTL, pid+bundleId key). Session-only — disk catalog reload deferred.
2. **Workspace assignment**: FIXED (build 95). Central `assignWindowToWorkspace()` gate with `WorkspaceAssignmentReason` enum. trackPreparedCreate refactored to use gate. Bug #23 fixed.
3. **Display coalescing**: FIXED (build 92). 300ms trailing-edge debounce in handleMonitorConfigurationChanged. 15 SLM tests pass.
4. **Admission dedup**: FIXED (build 91). Guard in trackPreparedCreate skips already-tracked windows. 165 tests pass.
5. **Focus reconciliation**: FIXED (build 95b+96). Hotkey-level only: reconcileFocusBeforeCommand compares border PID vs macOS frontmost PID before every command. Passive reconciliation (build 93) REMOVED in build 96 — caused focus feedback loop (50ms ping-pong, devil's advocate predicted it). macOS 14+ ignores activateIgnoringOtherApps so passive path can't work anyway.
Architecture ~30% toward clean.

## Constitution — MANDATORY Process Gates

### Before ANY Work

1. **Activate Serena**: `activate_project` on OmniWM, then read `mem:core`, `mem:task_completion`, `mem:conventions`
2. **Load memorygraph**: `search_memories` tags `["next-session"]` + `["hiro", "architecture-audit"]`
3. **Load memory MCP**: `open_nodes` for OmniWM entities — separate from memorygraph
4. **Load AGENTS.md**: `gh pr diff 320 --repo BarutSRB/Hiro` (not in repo — lives in upstream PR)
5. **Load dotfiles MEMORY.md feedback rules**: read `feedback_hiro_development_process.md`, `feedback_verify_process_at_every_phase.md`, `feedback_never_claim_done.md`
6. **Check Graphify graph**: `Sources/graphify-out/graph.json` — run `graphify update Sources/` if stale
7. **Self-check at every phase gate**: Verify this constitution is being followed. Don't wait for user to ask.

### Before ANY Bug Fix (GATE 0 — cannot be skipped)

1. **REPRODUCE the bug yourself** — not from memorygraph descriptions, not from code reading. Actually trigger the bug on the running binary. Capture evidence:
   - IPC state before/after (`omniwmctl query windows/workspaces`)
   - Log output showing the failure (`/usr/bin/log show --predicate 'subsystem == "com.omniwm"' --last 30s --info --debug`)
   - Screenshot if visual
   - If you CANNOT reproduce it, say so. Do NOT proceed to fix.
2. **`superpowers:systematic-debugging`** — Phase 1 (reproduce + gather evidence) MUST complete before Phase 3 (hypothesis). No skipping to hypothesis from memorygraph alone.
3. **Add diagnostic logging FIRST** — before ANY fix attempt, add `WMLog` traces to the suspected code path. Build, deploy, reproduce, read the logs. Understand the actual runtime flow before theorizing.
4. **Memorygraph/memory descriptions are HISTORICAL** — they describe what was true when written. The code may have changed. Verify against current code before acting on them.

### Before ANY Code Changes

1. **Compare against build 66 / upstream**: `git show upstream/main:<path>` for the specific code path. Understand what was working before Phase 1-5. Map regressions vs pre-existing gaps vs new behaviors.
2. **Holistic analysis**: Map ALL related bugs before fixing one. Don't patchwork — understand the pattern across bugs and design a coherent fix that aligns with Phase 1-5 + Fix A/B/C architecture.
3. **Graphify structural analysis**: `graphify explain/path/affected` on the subsystem BEFORE reading code. Structure first, then semantics. Use `--graph Sources/graphify-out/graph.json`.
4. **Load ALL architecture context FIRST**:
   - Serena: `mem:core`, `mem:controller`, `mem:conventions`, `mem:task_completion`
   - AGENTS.md: `gh pr diff 320 --repo BarutSRB/Hiro` — read the subsystem being modified
   - Memorygraph: Phase maps (1-5), architecture audit (`bafc9b77`), relevant bug IDs
   - Phase 3 viewport pipeline: memorygraph `15c55926` — critical for any layout/viewport work
5. **Expert subagents for analysis** — spawn architect/debugger/devil's-advocate Explore agents to analyze the code BEFORE proposing fixes. Don't do ad-hoc code reading alone.
6. **Brainstorming skill** — `superpowers:brainstorming` before any feature/fix. No exceptions.
7. **Writing plans skill** — `superpowers:writing-plans` for implementation plan with file paths and test steps.
8. **TDD** — `superpowers:test-driven-development`. Write failing test FIRST.
9. **Devil's advocate** — challenge every architectural decision BEFORE implementing. Use `mcp__sequential-thinking__sequentialthinking` for structured reasoning.
10. **Use skills to make decisions** — don't ask the user what to do next. Invoke the relevant skill and follow its process.

### After ANY Rebuild + Deploy
1. **Verify logs are flowing**: `/usr/bin/log show --predicate 'processIdentifier == <PID> AND subsystem == "com.omniwm"' --last 10s --info --debug` — must show output. If empty, the binary lost Accessibility permission (macOS revokes on unsigned binary change).
2. **Verify hotkeys work**: stream `category == "input"` while pressing a hotkey. If no events, re-add `.build/debug/OmniWM` to Accessibility via symlink method.
3. **Every `swift build` produces a new unsigned binary** — macOS may revoke CGEventTap permission. This is expected development friction, not a code bug.
4. **Restart SketchyBar watcher**: `.build/debug/omniwmctl watch --all --exec sketchybar --trigger omniwm_workspace_changed &` — the watch process dies on every Hiro restart.

### Before ANY Deployment to User's Desktop

1. **All tests pass** — `swift test --filter <relevant>` with specific count
2. **Format + lint clean** — `make format-check` + `make lint`
3. **Clean restart test** — kill running binary, start new one, IPC ping, 30s log stream. Don't inherit stale state.
4. **NEVER deploy a fix that modifies layout state (cachedWidth, size, viewport) without first testing on a CLEAN workspace** — stale state persists across restarts and corrupts the user's desktop.
5. **If the fix changes column widths or viewport state**: test on an empty workspace FIRST, then on the user's real workspaces.

### Before EVERY Commit (STOP and run this checklist)

1. `swift build -c debug` — compiles cleanly
2. `swift test --filter <relevant>` — tests pass with specific count
3. `make format-check` — 0 files need formatting (run `make format` if not)
4. `make lint` — 0 serious violations
5. **CodeRabbit**: invoke `coderabbit:code-review` skill on `git diff` BEFORE committing — not after
6. **Graphify**: `graphify update Sources/` — check for coupling regressions
7. **Architecture smell check**: does this change increase god node edges? Add new coupling? Check with `graphify explain <changed-symbol>`

### Before ANY Completion Claim (STOP and run this checklist)

**Quality gates:**
1. `make verify` — all checks pass (format + lint + build + test)
2. **CodeRabbit**: `coderabbit:code-review` skill — MUST be run, not skipped
3. **Graphify**: `graphify update Sources/` + `graphify explain <key-symbols>` — coupling check

**Skills that MUST be invoked (not just "tests written first"):**
4. `superpowers:test-driven-development` — invoke the skill, not just write tests
5. `superpowers:verification-before-completion` — invoke before ANY "done" claim
6. **Expert subagents**: architect/debugger/devil's-advocate review on the diff

**Runtime verification:**
7. Deploy: kill → rebuild → launch → IPC ping → 30s log stream
8. **Evidence**: test counts with numbers, exit codes, IPC results, log line counts. No "should work."

**Holistic review:**
9. Does this change align with Phase 1-5 + Fix A/B/C/D/E architecture?
10. Does it introduce architecture smells? (new god node coupling, SSOT violations, purity violations)
11. Does upstream handle this differently? Check `git show upstream/main:<path>` + upstream Graphify

**Persistence sync (ALL 9 systems — do in ONE pass, not when prompted):**
12. **CLAUDE.md**: update bug status, architecture, build number if changed
13. **Serena**: `write_memory` or `edit_memory` for `mem:core`/`mem:controller`/`mem:task_completion` if relevant
14. **Memorygraph**: `store_memory` with tags + `create_relationship` to linked entries
15. **Memory MCP**: `add_observations` to entities, `create_relations` for links
16. **Dotfiles MEMORY.md**: update index if new memory files created
17. **Dotfiles files**: update `project_omniwm_evaluation.md`, `project_omniwm_next_session.md`
18. **Graphify**: already updated in step 3
19. **Hooks**: update `.claude/settings.json` if new enforcement needed
20. **CodeRabbit**: already run in step 2

### After EVERY Finding or Decision (proactive, not when prompted)

Update ALL 9 systems in ONE pass:
1. **CLAUDE.md** — architecture, bug status, build number
2. **Serena** — `edit_memory` for `mem:core`/`mem:controller`/`mem:task_completion`/`mem:conventions`
3. **Memorygraph** — `store_memory` + `create_relationship` with tags and cross-links
4. **Memory MCP** — `create_entities` or `add_observations` + `create_relations`
5. **Dotfiles MEMORY.md** — update index
6. **Dotfiles files** — evaluation, next-session, architecture audit, feedback rules
7. **Graphify** — `graphify update Sources/` if code changed
8. **Hooks** — `.claude/settings.json` if new enforcement needed
9. **CodeRabbit** — note findings for review context

**Do NOT wait to be asked.** The whole point of 9 systems is proactive sync.

### Post-Release Artifact Linting

1. `swift build -c release` — release build compiles
2. `make format-check` + `make lint` on final artifact
3. Run binary + IPC ping
4. Log stream 30s for error-level spam
5. Graphify diff pre/post for coupling regressions

### For Sleep/Wake Testing

1. **Pre-sleep inventory**: Capture FULL baseline via IPC BEFORE sleep — `omniwmctl query windows`, `query workspaces`, `query displays`, `query focused-window`. Save window count, frames, workspace assignments, monitor mapping, focus state.
2. **Sleep**: User sleeps Mac
3. **Post-wake comparison**: Re-run all 4 queries, diff against baseline. Check: same window count, correct workspace assignments, correct display assignments, reasonable frames (not off-screen or wrong-monitor coordinates).
4. **Log analysis**: `/usr/bin/log show --predicate 'subsystem == "com.omniwm"' --last 2m --info --debug` — check for `willSleep`, `systemWake`, `executeFinalRestore`, any `Removing window` (should be zero), any error-level entries.

### Rules (Non-Negotiable)

- NEVER fix a bug you haven't reproduced yourself — memorygraph descriptions and code reading are NOT reproduction
- NEVER deploy layout/viewport fixes to user's desktop without clean workspace testing — stale state (cachedWidth, size) persists across restarts and corrupts windows
- Niri is a SCROLLING model — columns DON'T expand to fill the display. The viewport scrolls. normalizeColumnSizes is almost certainly wrong. applyOverspread centers without changing widths.
- Add diagnostic logging BEFORE fixing, not after the fix fails
- Expert panels can be unanimously wrong — ALWAYS deploy + count metrics (frame batches, relayout count) before AND after. If worse, revert immediately.
- NEVER claim "done" without measurable evidence
- NEVER call something a "2-line fix" — investigate fully before estimating
- IPC simulation ≠ keyboard verification (click-focus desync is invisible to IPC)
- Unit tests passing ≠ runtime correct (portrait coordinate inversion lesson)
- Devil's advocate BEFORE implementing architectural changes
- No reactive patches — save findings to memorygraph BEFORE patching
- Don't ask user to do things you can do yourself (log capture, IPC queries, process restart)
- Capture logs proactively after any user action — don't wait to be told
- Check ALL persistence systems (Serena + memorygraph + memory MCP + MEMORY.md + Graphify + AGENTS.md + CodeRabbit) at every phase gate — not just one or two
- Think holistically — map related bugs together before fixing individually

## Architecture (from Graphify audit + devil's advocate, 2026-06-08)

God nodes: WorkspaceManager (248 edges), WMController (203), AXEventHandler (169), LayoutRefreshController (160).

### Niri Column Width Model (NOT purely scrolling)
- `maxVisibleColumns` (default 2): initial width = `proportion(1.0 / N)`. With 2, columns start at 50%.
- `isFullWidth`: per-column flag → `proportion(1.0)`. Toggle via hotkey.
- `expandColumnToAvailableWidth`: USER command — fills available viewport space (NiriLayoutEngine+Sizing.swift:537).
- `singleWindowLayoutContext`: AUTOMATIC — 1 column + 1 window → fills screen with aspect ratio.
- `applyOverspread`: AUTOMATIC (Phase 3) — centers column group. Changes viewport offset ONLY, not widths.
- `normalizeColumnSizes`: ORPHANED (0 callers). Do NOT use — causes viewport chaos (lesson from 2026-06-09).
- Upstream Graphify: `~/.graphify/repos/BarutSRB/Hiro/Sources/graphify-out/graph.json`
`sessionState.focus` IS the single source of truth for focus — earlier claim of "7-location SSOT violation" was overturned by devil's advocate (different concerns, not duplicate state).
Niri architecture is cleaner than Dwindle (external ViewportState, parameterized orientation, isolated animation).
Fix D (viewport scoping) needs runtime evidence from bug reproduction before implementation.
Full audit (corrected): dotfiles `memory/project_omniwm_architecture_audit.md` + memorygraph `bafc9b77`.

### God Node Remediation (expert panel validated, 2026-06-09)
5 prioritized extractions. Plan: `.claude/plans/eager-moseying-matsumoto.md`. Memorygraph `595714f5`.
1. **reevaluateWindowRules decomposition** (WMController, private methods, LOW risk) — bug #19 positional fix
2. **RefreshQueueManager** (LRC, ~400 lines, LOW risk) — 25-case merge matrix, 0 test coverage
3. **DisplayLinkManager** (LRC, ~250 lines, MEDIUM risk) — bug #15 animation scoping
4. **ManagedReplacementCorrelator** (AXEventHandler, ~700 lines, MEDIUM-HIGH risk) — 20% reduction
5. **RefreshMergeMatrixTests** (test-only, ~300 lines) — Fix D safety net
**Not touched:** WorkspaceManager (all LOW), WMController forwarding (stable API), ForTests providers, LRC buildFullRefreshExecutionPlan.

### Status Dashboard (build 103, 2026-06-11) — SINGLE SOURCE OF TRUTH

**This table is the SSOT.** All other systems (Serena, memorygraph, Memory MCP, dotfiles) point here. Update this table FIRST, then sync outward.

#### Bugs

| # | Description | Status | Build | Next Action |
|---|------------|--------|-------|-------------|
| 6/22 | Chrome verificationMismatch | CLOSED | 92 | — |
| 19 | Chrome re-admission storm | CLOSED | 85 | — |
| 20 | Ghostty tab phantom columns | CLOSED | 81 | — |
| 21 | Dwindle wake wrong-monitor coords | CLOSED | 92 | — |
| 23 | Native fullscreen wrong workspace | CLOSED | 95 | — |
| 24 | Focus desync portrait Dwindle | CLOSED | 95b | — |
| 25 | Zoom startup tiling | CLOSED | 90 | — |
| 26 | Focus feedback loop | CLOSED | 96 | — |
| 30 | Cross-display transfer wrong frame | CLOSED | 100 | — |
| — | Ghost border during Chrome tabs | CLOSED | 101 | — |
| 7/27 | Column gap after moveToWorkspace | **FIXED** | 106 | Root cause: moveColumnToWorkspace missing activeColumnIndex adjustment + initializeNewColumnWidth. Fix: adjustActiveColumnIndex helper (DRY) + resetColumnWidth:Bool parameter (F7 pattern) + viewport clamp + applyOverspread on every pass. 9 commits, 53 tests. |
| 7/27/15 | Niri viewport gap (cross-monitor) | **FIXED** | 106 | Same fix as #7/27. Viewport clamping + column transfer pipeline consolidation. |
| 28 | WhatsApp floating→tiling on wake | **OPEN** | 101 | Need to test with WhatsApp in floating mode (was tiling in build 102 test) |
| 31 | Hidden window 1px edge peeking | BY DESIGN | — | `hiddenWindowEdgeRevealEpsilon=1.0` — upstream identical. Prevents macOS GC of off-screen windows. Cosmetic. |
| 29 | Column reorder on Retina after wake | CLOSED | 102 | Columns identical pre/post wake (signed binary, willSleep snapshot captured) |
| — | Portrait wake window loss | CLOSED | 102 | 0 removals, 10/10 windows survived, willSleep+snapshot fired |

#### Features (from upstream v0.4.9.7 analysis + fork work)

| # | Description | Status | Build | Source | Details |
|---|------------|--------|-------|--------|---------|
| F1 | AXFrameApplicationLedger | N/A | — | Upstream | Fork's AXManager already has `lastAppliedFrames` dedup + `shouldSuppressFrameChangeRelayout`. Full 525-line Ledger not needed (retry budgets, rekey, observers are over-engineering). Pre-existing, not fork work. |
| F2 | Ghost border guard | DONE | 101 | Runtime | isOwnedWindow in handleCGSWindowDestroyed |
| F3 | Invariant checks | DONE | 101 | Upstream Reconcile | duplicate_window_token, focused_destroyed, pending_dead |
| F4 | AX rekey for tabbing | N/A | — | Upstream | Fork already has `AXManager.rekeyWindowState` + `rekeyedWindowIdsByPreviousId` + `StateReducer.rekeyedFocusSession`. Pre-existing, not fork work. |
| F5 | Focus request tracking | **OPEN** | — | Upstream | Fork MISSING: `requestId: UInt64` on focus events (prevents stale confirmations) + `setFocusSession` helper. No blocking bug currently. |
| F6 | Dev signing | DONE | 101 | Fork infra | `make build-sign`, willSleep now fires |
| F7 | Frame coalescing | DONE | 102-103 | Fork + upstream | animate: Bool on ESV (build 102) + applyViewportPipeline animate:false (build 103). 85% AX write reduction. Click focus: 1-2 batches (was 17). Spec: `docs/superpowers/specs/2026-06-11-f7-frame-coalescing-design.md` |

| F8 | Upstream v0.4.9.7 carry-over | **OPEN** | — | Upstream | 9 commits pending evaluation: resize placeholders, bezier motion, semantic Hyper, hotkey simplification, tabbing prevention, runtime refresh consolidation. Need constitution-compliant review. |

Rejected: Semantic Hyper key (Karabiner handles it), Bezier motion (spring is correct for WM). **NOTE:** These rejections were for v0.4.9.6. v0.4.9.7 re-introduces some — need re-evaluation.

#### Fix Pipeline

| Fix | Description | Status | Build |
|-----|------------|--------|-------|
| Fix A | Atomic window transfer | DONE | 77 |
| Fix B | SkyLight guard scoping | DONE | 81 |
| Fix C | Wake restore (settle-then-correct) | DONE | 80 |
| Fix D L1 | Viewport centering | DONE | 100 |
| Fix D L2 | Frame observation feedback | CLOSED | 103 |
| Fix E | WindowLifecycleCoordinator | DONE | 86 |

#### SSOT Invariants

| # | Invariant | Status | Build |
|---|-----------|--------|-------|
| 1 | Window identity persistence | DONE | 95 |
| 2 | Single workspace assignment | DONE | 95-97 |
| 3 | Display event coalescing | DONE | 92 |
| 4 | Admission dedup | DONE | 91 |
| 5 | Focus reconciliation | DONE | 95b-96 |
| 6 | Hydration matching | DONE | 98 |

#### God Node Extractions

| # | Extraction | Status | Build |
|---|-----------|--------|-------|
| 1 | reevaluateWindowRules decomposition | DONE | 85 |
| 2 | RefreshQueueManager | DONE | 88 |
| 3 | DisplayLinkManager | DONE | 89 |
| 4 | ManagedReplacementCorrelator | DONE | 90-101 |
| 5 | RefreshMergeMatrixTests | Deferred | — |

#### Scattered Critical Pathways (Graphify audit, 2026-06-11)

| Method | Call Sites | Status |
|--------|-----------|--------|
| `requestImmediateRelayout` | 44 | **REAL RISK** — 29 `.layoutCommand` callers, missing animation policy param. F7 pipeline uses animate:false but directive→execution race possible. Needs fresh session analysis. |
| `focusWindow` | 23 | **REAL RISK** — 5 ungated callers bypass `reconcileFocusBeforeCommand`. Bar click + post-animation focus can race with managed focus. |
| `ensureSelectionVisible` | 28 | **F7 FIXED** — `animate: Bool` + typed wrappers |
| `startScrollAnimation` | 16 | **NEEDS AUDIT** — 4 start-condition paths, direct calls skip `hasPendingNiriAnimationWork()`. Related to requestImmediateRelayout. |
| `commitWorkspaceTransition` | 13 | **DA REOPENED** — empty affectedWorkspaces silently escalates to relayout-all (CPU footgun, no assertion). Upstream same pattern. |
| `moveColumnToWorkspace` | 3 | **FIXED** (build 106) — adjustActiveColumnIndex + resetColumnWidth parameter |
| `commitWorkspaceSelection` | 9 | **DA REOPENED** — hidden contract between nodeId/focusedToken params, no validation. Risk: focus/selection desync. |

Memorygraph `9e2d0a33`. F7 proved adding explicit policy parameters works (85% AX reduction).

#### Summary

| Category | Done | Open |
|----------|------|------|
| Bugs | 14 | 1 (Bug #28 floating mode wake) |
| Features | 3 done + 2 N/A | 2 (F5 focus request tracking, F8 upstream v0.4.9.7 eval) |
| Fixes | 6 | — |
| SSOT | 6/6 | — |
| Extractions | 4/5 | 1 deferred |
| Scattered pathways | 2 fixed (F7 + moveColumnToWorkspace) | 5 open: 2 real risks (requestImmediateRelayout 44, focusWindow 23) + 3 DA-reopened (commitWorkspaceTransition 13, viewport coupling 10+, commitWorkspaceSelection 9) |

## Cross-References

| System | What | How to access |
|--------|------|---------------|
| **Serena memories** | Source map, conventions, commands, task checklist | `read_memory mem:core/conventions/task_completion/suggested_commands/controller` |
| **Memorygraph MCP** | Architecture maps, bug tracker, lessons, audit | `search_memories` tags `["hiro"]`, key IDs in dotfiles MEMORY.md |
| **Memory MCP** | Knowledge graph entities (cross-ref system, CLAUDE.md entity) | `open_nodes`, `search_nodes` — separate from memorygraph |
| **Dotfiles MEMORY.md** | Index of all memory files | Auto-loaded at session start from `~/.claude/projects/.../memory/MEMORY.md` |
| **Graphify graph (fork)** | Code knowledge graph (8518 nodes) | `Sources/graphify-out/graph.json`, CLI: `graphify explain/path/affected` |
| **Graphify graph (upstream)** | Upstream comparison (8430 nodes) | `~/.graphify/repos/BarutSRB/Hiro/Sources/graphify-out/graph.json` |
| **AGENTS.md** | Upstream architecture guide | `gh pr diff 320 --repo BarutSRB/Hiro` (6 files across subdirs) |
| **Memory MCP** | Knowledge graph entities | `open_nodes` for Hiro-Niri-Column-Model, Bug7-Column-Gap-Status, OmniWM-CLAUDE-MD, OmniWM-Cross-Reference-System |
| **Feedback rules** | Behavioral rules from past failures | `feedback_*.md` files in dotfiles memory dir |
| **CodeRabbit** | Pre-merge code review | `coderabbit:code-review` skill |

## Build

```bash
# GhosttyKit required
gh release download v0.4.9.6 -R BarutSRB/Hiro -p "GhosttyKit.xcframework-*.zip" -D /tmp
unzip /tmp/GhosttyKit.xcframework-*.zip -d Frameworks/
swift build -c debug
```

## Logging

```bash
/usr/bin/log show --predicate 'subsystem == "com.omniwm"' --last 5m --style compact --info --debug
log stream --predicate 'subsystem == "com.omniwm"' --debug
```

Categories: ax, layout, focus, input, config, ipc, workspace. Always use `--info --debug` flags.

## Test Rules

- NEVER `swift test` without `--filter` on active desktop — SkyLight creates real border windows
- `*ForTests` closure injection pattern (227+ instances)
- `BorderWindow.Operations.noop` for test controllers
- `liveFrameProviderForTests` is an override, not a replacement
