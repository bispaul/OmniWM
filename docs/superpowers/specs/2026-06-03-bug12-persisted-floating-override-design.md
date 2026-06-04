# Bug #12 Fix: Respect Explicit Rule Decisions in Persisted Hydration

## Problem

When Hiro restarts, `RestorePlanner.planPersistedHydration()` unconditionally applies the persisted `restoreToFloating` flag, overriding the window rule engine's explicit tiling decision. Windows with `layout = "tile"` in their app rule (Ghostty, Chrome) become floating on every restart.

The cycle is self-perpetuating: once a window is incorrectly saved as floating, `floatingGeometryUpdated` re-poisons the catalog on each restart, and the explicit rule is never consulted again.

## Root Cause

`planPersistedHydration()` line 271:
```swift
let targetMode: TrackedWindowMode = persistedEntry.restoreIntent.restoreToFloating ? .floating : input.metadata.mode
```

This ignores whether the rule engine explicitly decided the window should tile. The `metadata.mode` is already the current tracked mode (corrupted to `.floating`), not the rule engine's decision.

## Fix

Add `layoutDecisionKind` to `ManagedReplacementMetadata` so the rule engine's decision survives through the reconciliation pipeline. In `planPersistedHydration`, when `layoutDecisionKind == .explicitLayout`, ignore the persisted `restoreToFloating` flag and use the rule engine's decided mode.

### Changes

**1. `ManagedReplacementMetadata` (WindowModel.swift)**
Add field:
```swift
var layoutDecisionKind: WindowDecisionLayoutKind = .fallbackLayout
```
Default to `.fallbackLayout` for backward compatibility — existing metadata without the field behaves as before.

**2. `makeManagedReplacementMetadata()` (AXEventHandler.swift line 2503)**
Accept and pass through the `layoutDecisionKind` from the evaluation:
```swift
private func makeManagedReplacementMetadata(
    bundleId: String?,
    workspaceId: WorkspaceDescriptor.ID,
    mode: TrackedWindowMode,
    facts: WindowRuleFacts,
    layoutDecisionKind: WindowDecisionLayoutKind = .fallbackLayout
) -> ManagedReplacementMetadata {
    ManagedReplacementMetadata(
        ...existing fields...,
        layoutDecisionKind: layoutDecisionKind
    )
}
```

**3. Call sites of `makeManagedReplacementMetadata` in `prepareCreateCandidate()` (AXEventHandler.swift line 2180)**
Pass the evaluation's decision kind:
```swift
replacementMetadata: makeManagedReplacementMetadata(
    bundleId: resolvedBundleId,
    workspaceId: workspaceId,
    mode: trackedMode,
    facts: evaluation.facts,
    layoutDecisionKind: evaluation.decision.layoutDecisionKind
),
```

**4. `RestorePlanner.planPersistedHydration()` (RestorePlanner.swift line 271)**
Change the targetMode decision:
```swift
let targetMode: TrackedWindowMode
if input.metadata.layoutDecisionKind == .explicitLayout {
    targetMode = input.metadata.mode
} else {
    targetMode = persistedEntry.restoreIntent.restoreToFloating ? .floating : input.metadata.mode
}
```

When the rule engine explicitly decided the layout (via user rule or built-in rule), the persisted floating flag is ignored. For heuristic-decided windows (fallbackLayout), existing behavior is preserved.

### What This Does NOT Change

- The persisted catalog still saves `restoreToFloating: true` — but it's now ignored for explicitly-ruled windows
- The `floatingGeometryUpdated` event flow is untouched
- Heuristic-decided windows (no explicit rule) still respect the persisted flag
- The `mergingNonNilValues` function on metadata works naturally — `layoutDecisionKind` overlays correctly

### Tests

Add to `RestorePlannerTests.swift`:

**Test: explicit rule overrides persisted floating flag**
- Create metadata with `mode: .tiling, layoutDecisionKind: .explicitLayout`
- Create catalog entry with `restoreToFloating: true`
- Call `planPersistedHydration`
- Assert `targetMode == .tiling` (not `.floating`)

**Test: fallback layout respects persisted floating flag (existing behavior)**
- Create metadata with `mode: .tiling, layoutDecisionKind: .fallbackLayout`
- Create catalog entry with `restoreToFloating: true`
- Call `planPersistedHydration`
- Assert `targetMode == .floating` (existing behavior preserved)

## Verification

1. `swift build` compiles
2. `swift test --filter RestorePlanner` passes (existing + new tests)
3. Start log stream, restart Hiro, verify Ghostty shows:
   - `WindowRuleEngine: matchedUserRule ... layoutKind=explicitLayout`
   - `planPersistedHydration: matched ... targetMode=tiling` (not floating)
4. Ghostty and Chrome are tiled, not floating, after restart
