# Extraction 1: Decompose reevaluateWindowRules — Design Spec

## Goal

Split the 221-line `WMController.reevaluateWindowRules` into private helper methods to fix the SwiftLint function_body_length violation and prepare the code for Fix D viewport-scoped changes.

## Why NOT a new type

Expert panel (architect + coder + devil's advocate) unanimously recommended against `WindowRuleEvaluationPipeline`:
- Phase 2 has real read-after-write dependencies across tokens (sibling workspace, parent tracking) — cannot split evaluate/mutate
- Phase 1 (57 lines) doesn't justify a new type with 4 injected dependencies
- Private methods achieve the same readability benefit without ceremony

## Design

### New private struct (data transfer only)

```swift
private struct ResolvedReevaluationTargets {
    let tokensToReevaluate: Set<WindowToken>
    let liveWindowsByToken: [WindowToken: AXWindowRef]
    let resolvedAnyTarget: Bool
}
```

### New private methods

**Phase 1 — Target resolution (read-only, async):**
```swift
private func resolveReevaluationTargets(
    _ targets: Set<WindowRuleReevaluationTarget>
) async -> ResolvedReevaluationTargets
```
Contains lines 2084-2141. Chromium filter encapsulated here.

**Phase 2+3 — Evaluate and apply (mutation, interleaved):**
```swift
private func evaluateAndApplyDispositions(
    tokens: Set<WindowToken>,
    liveWindowsByToken: [WindowToken: AXWindowRef],
    resolvedAnyTarget: Bool,
    context: WindowRuleReevaluationContext
) -> WindowRuleReevaluationOutcome
```
Contains lines 2143-2297. Verbatim move — no restructuring of the per-token loop.

### Orchestrator (main method, ~15 lines)

```swift
func reevaluateWindowRules(
    for targets: Set<WindowRuleReevaluationTarget>,
    context: WindowRuleReevaluationContext = .automatic
) async -> WindowRuleReevaluationOutcome {
    guard !targets.isEmpty else { return .none }
    let resolved = await resolveReevaluationTargets(targets)
    guard !resolved.tokensToReevaluate.isEmpty else {
        return WindowRuleReevaluationOutcome(
            resolvedAnyTarget: resolved.resolvedAnyTarget,
            evaluatedAnyWindow: false, relayoutNeeded: false
        )
    }
    return evaluateAndApplyDispositions(
        tokens: resolved.tokensToReevaluate,
        liveWindowsByToken: resolved.liveWindowsByToken,
        resolvedAnyTarget: resolved.resolvedAnyTarget,
        context: context
    )
}
```

## What does NOT change

- No new file, no new class/coordinator
- Per-token evaluation order (sorted by pid+windowId) preserved exactly
- Interleaved evaluate+mutate per token preserved exactly
- All callers unchanged (same public API)
- Chromium filter logic unchanged (just encapsulated in named method)

## Testing

- Existing integration tests via `reevaluateWindowRules` callers — no behavioral change
- `make verify` — all checks pass
- CodeRabbit review BEFORE commit

## Risk: LOW

Mechanical code motion. No semantic change. Phase 2 moved verbatim.
