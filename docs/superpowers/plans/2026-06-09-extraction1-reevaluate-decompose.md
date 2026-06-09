# Extraction 1: Decompose reevaluateWindowRules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the 221-line `reevaluateWindowRules` monolith into two private helper methods + a lightweight struct, making the orchestration flow visible at a glance.

**Architecture:** No new files. Add `ResolvedReevaluationTargets` private struct + two private methods on WMController. The public method becomes a ~15-line orchestrator calling `resolveReevaluationTargets` (Phase 1) then `evaluateAndApplyDispositions` (Phase 2+3). Verbatim code motion — no behavioral change.

**Tech Stack:** Swift 6.3, `@MainActor`, async/await

**Design spec:** `docs/superpowers/specs/2026-06-09-extraction1-reevaluate-decompose-design.md`

---

### Task 1: Add ResolvedReevaluationTargets struct + extract Phase 1

**Files:**
- Modify: `Sources/OmniWM/Core/Controller/WMController.swift:2077-2298`

- [ ] **Step 1: Add the private struct before reevaluateWindowRules**

Insert before line 2077 (`@discardableResult func reevaluateWindowRules`):

```swift
// MARK: - Window Rule Reevaluation

private struct ResolvedReevaluationTargets {
    let tokensToReevaluate: Set<WindowToken>
    let liveWindowsByToken: [WindowToken: AXWindowRef]
    let resolvedAnyTarget: Bool
}
```

- [ ] **Step 2: Extract Phase 1 into resolveReevaluationTargets**

Add this private method after the struct (before `reevaluateWindowRules`):

```swift
private func resolveReevaluationTargets(
    _ targets: Set<WindowRuleReevaluationTarget>
) async -> ResolvedReevaluationTargets {
    var liveWindowsByToken: [WindowToken: AXWindowRef] = [:]
    var tokensToReevaluate: Set<WindowToken> = []
    var pidTargets: Set<pid_t> = []
    var resolvedAnyTarget = false

    for target in targets {
        switch target {
        case let .window(token):
            let existingEntry = workspaceManager.entry(for: token)
            if let axRef = resolveAXWindowRef(for: token) {
                resolvedAnyTarget = true
                tokensToReevaluate.insert(token)
                liveWindowsByToken[token] = axRef
            } else if existingEntry != nil {
                resolvedAnyTarget = true
                tokensToReevaluate.insert(token)
            }
        case let .pid(pid):
            pidTargets.insert(pid)
        }
    }

    for pid in pidTargets {
        let managedEntries = workspaceManager.entries(forPid: pid)
        if !managedEntries.isEmpty {
            resolvedAnyTarget = true
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            let windows = await axManager.windowsForApp(app)
            if !windows.isEmpty {
                resolvedAnyTarget = true
            }
            let isChromium = app.bundleIdentifier.map { WindowClassifier.chromiumBundleIds.contains($0) } ?? false
            for (axRef, _, windowId) in windows {
                let token = WindowToken(pid: pid, windowId: windowId)
                if isChromium, workspaceManager.entry(for: token) == nil {
                    let title = SkyLight.shared.getWindowTitle(UInt32(windowId))
                    if title == nil || title?.isEmpty == true {
                        continue
                    }
                }
                tokensToReevaluate.insert(token)
                liveWindowsByToken[token] = axRef
            }
        }

        for entry in managedEntries {
            tokensToReevaluate.insert(entry.token)
        }
    }

    return ResolvedReevaluationTargets(
        tokensToReevaluate: tokensToReevaluate,
        liveWindowsByToken: liveWindowsByToken,
        resolvedAnyTarget: resolvedAnyTarget
    )
}
```

- [ ] **Step 3: Extract Phase 2+3 into evaluateAndApplyDispositions**

Add this private method after `resolveReevaluationTargets`:

```swift
private func evaluateAndApplyDispositions(
    tokens: Set<WindowToken>,
    liveWindowsByToken: [WindowToken: AXWindowRef],
    resolvedAnyTarget: Bool,
    context: WindowRuleReevaluationContext
) -> WindowRuleReevaluationOutcome {
```

Move lines 2143-2297 (the `var relayoutNeeded` through the `return WindowRuleReevaluationOutcome(...)`) VERBATIM into this method body. Close with `}`.

- [ ] **Step 4: Replace reevaluateWindowRules body with orchestrator**

Replace the entire body of `reevaluateWindowRules` (lines 2082-2297) with:

```swift
guard !targets.isEmpty else { return .none }

let resolved = await resolveReevaluationTargets(targets)

guard !resolved.tokensToReevaluate.isEmpty else {
    return WindowRuleReevaluationOutcome(
        resolvedAnyTarget: resolved.resolvedAnyTarget,
        evaluatedAnyWindow: false,
        relayoutNeeded: false
    )
}

return evaluateAndApplyDispositions(
    tokens: resolved.tokensToReevaluate,
    liveWindowsByToken: resolved.liveWindowsByToken,
    resolvedAnyTarget: resolved.resolvedAnyTarget,
    context: context
)
```

- [ ] **Step 5: Build**

Run: `swift build -c debug 2>&1 | tail -5`

Expected: Build succeeded. If compile errors, fix references to local variables that were renamed during extraction.

- [ ] **Step 6: Run related tests**

Run: `swift test --filter 'AXEventHandler|WindowLifecycleCoordinator|titleChanged' 2>&1 | grep -E '✔|✘|Test run' | tail -5`

Expected: All tests pass (167+ tests). No behavioral change.

- [ ] **Step 7: Format + lint**

Run: `make format-check 2>&1 | tail -3 && make lint 2>&1 | grep 'function_body_length' | grep -c 'reevaluateWindowRules'`

Expected: Format clean. `reevaluateWindowRules` no longer in function_body_length violations (was 221 lines, now ~15).

- [ ] **Step 8: CodeRabbit review BEFORE commit**

Dispatch `coderabbit:code-review` subagent on `git diff`.

- [ ] **Step 9: Commit**

```bash
git add Sources/OmniWM/Core/Controller/WMController.swift
git commit -m "refactor: decompose reevaluateWindowRules into private helper methods

Split 221-line monolith into 3 parts:
- resolveReevaluationTargets: Phase 1 target resolution (~57 lines)
- evaluateAndApplyDispositions: Phase 2+3 evaluate + mutate (~160 lines)
- ResolvedReevaluationTargets: lightweight data transfer struct

Main method is now ~15-line orchestrator. Chromium filter
encapsulated in resolveReevaluationTargets by method name.
No behavioral change — verbatim code motion.

Expert panel validated: no new type needed, private methods
sufficient. Phase 2 evaluate+mutate must stay interleaved
(read-after-write dependencies across tokens).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Verification + deploy + persistence sync

- [ ] **Step 1: Graphify update + verify**

Run: `graphify update Sources/ 2>&1 | tail -3 && graphify explain "reevaluateWindowRules" --graph Sources/graphify-out/graph.json 2>&1 | head -5`

Expected: Node still exists, same degree (no edge change — private methods don't show as separate nodes).

- [ ] **Step 2: Deploy + runtime verify**

Run: `pkill -x OmniWM; sleep 2; swift build -c debug && .build/debug/OmniWM & sleep 3 && pgrep -x OmniWM && .build/debug/omniwmctl ping`

Expected: PID exists, pong.

- [ ] **Step 3: 30s log stream**

Run: `/usr/bin/log stream --predicate 'subsystem == "com.omniwm"' --info --debug --style compact --timeout 30 2>/dev/null | grep -iE 'error|crash' | head -10; echo "---done"`

Expected: 0 errors.

- [ ] **Step 4: Update ALL 9 persistence systems**

Memorygraph, Serena, Memory MCP, CLAUDE.md, evaluation, next-session, MEMORY.md, Graphify (done), hooks (no change needed).
