# CLAUDE.md — Hiro (OmniWM) Tiling Window Manager

## Project

Swift 6.3 macOS tiling WM. Fork at `bispaul/OmniWM`, clone at `~/Documents/Personal/github/OmniWM`.
Branch: `fix/scope-relayout-to-workspace`. Build 90. PID check: `pgrep -x OmniWM`.

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

### Bug Status (build 87, 2026-06-09)
- **Bug #7** (column gap after moveToWorkspace): OPEN — cannot reproduce. Phase 3 pipeline handles viewport shift (diagnostic proof). normalizeColumnSizes is dead code (0 callers). Memorygraph `340b4ffd`.
- **Bug #6/22** (Chrome verificationMismatch retry loop): OPEN — cannot reproduce in normal operation. 0 mismatches in 42 frame writes (30min sample). Original 13-retry loop was amplified by bug #19 re-admission storm (now fixed). Wake-only: 4 events in 15s, self-resolving. Expert panel design ready if resurfaces. Memorygraph `e4ad0d6b`.
- **Bug #19** (Chrome re-admission storm): FIXED (build 85). 0 .pid reevaluation triggers in 8h. Was the amplifier for bugs #6/#7.
- **Bug #21** (Dwindle wake wrong-monitor coordinates): OPEN — pre-existing. Memorygraph `dd0141b7`.
- **Bug #20** (Ghostty tab phantom columns): OPEN — needs design. Memorygraph `a816fa8e`.
- **Flutter during moveToWorkspace**: REPRODUCED. 7 frame write batches / 200ms. cancelActiveTask removal kept (build 88, prevents torn frames). lastAppliedFrames fix REVERTED (amplified 7→17). Deep architectural issue — display link ticks + frame suppression + SkyLight moves. Needs Extraction 3 + Fix D. Pre-existing upstream. Memorygraph `91ce7d92`.
- **Portrait display window loss after sleep/wake**: REPRODUCED (build 88). WS 6 Chrome+Slack removed during wake, not recovered on restart. willSleep may not fire for debug binary (BackgroundOnly). Memorygraph `33b4d04f`.
- **Evidence**: 8h log analysis (memorygraph `a2964876`). 42 frame writes / 0 mismatches in normal operation. Wake: 4 mismatches, self-resolving.

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
