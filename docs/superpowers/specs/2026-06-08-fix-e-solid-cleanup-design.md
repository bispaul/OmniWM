# Fix E: SOLID Cleanup — Revised After Expert Review

## Context

Devil's advocate review identified that the original 3-item Fix E plan was too dangerous:

1. ~~Unify selectedNodeId ↔ focusedToken~~ — **CRITICAL RISK**: `selectedNodeId` is a layout anchor, not focus. Used by `summonWindowRight()`, `addWindow()` split placement, preselection. Unifying breaks cross-workspace operations.
2. ~~Replace cachedFrame with live AX~~ — **CRITICAL RISK**: `cachedFrame` is the animation baseline. `presentedFrame(at:)` offsets from it. Live frames would break animations.
3. ~~Centralize .pid reevaluation~~ — **HIGH RISK**: 4 call sites have different timing contexts. Shared 25ms debounce batches efficiently. Naive centralization loses context.

Build 84's fixes (sync-before-navigation, refreshCachedFrames) are the correct scoped patterns.

## Revised Scope

### Item 1: Phase 4 classifier fix (Bug #19 root cause)

**Problem**: `hasExplicitUserRule(forBundleId:)` overrides the classifier for ALL Chrome windows, including title-less internals. These get tracked → destroyed → .pid reevaluation storm.

**Fix**: Add `hasAdvancedUserRule(forBundleId:)` that only returns true if the matching user rule has specific matchers (title, subrole, axRole). BundleId-only rules do NOT override the classifier's rejection of Chromium internals.

**Files**: `WindowRuleEngine.swift` (add method), `AXEventHandler.swift` (change call site)

### Item 2: Context tags on reevaluation targets

**Problem**: `WindowRuleReevaluationTarget` has `.window(token)` and `.pid(pid)` but no context about WHY the reevaluation was triggered.

**Fix**: Add `ReevaluationTrigger` enum (`.creation`, `.removal`, `.titleChange`, `.destruction`) and pass it alongside targets. This documents intent without changing behavior. Enables future per-trigger filtering.

**Files**: `WindowRuleEngine.swift` (enum), `AXEventHandler.swift` (pass trigger)

## What We Explicitly Keep

- `selectedNodeId` separate from `focusedToken` — layout anchor ≠ focus
- `cachedFrame` as layout target — animation baseline must stay calculated
- Build 84's `refreshCachedFrames` before navigation — correctly scoped
- Build 84's `selectedNodeId` sync before swap/focus — bridges click-focus gap
- Distributed .pid reevaluation call sites — timing-specific, batched
