# Bug #36 Fix: Axis-Aware Frame Tolerance + Size Quantum Learning

## Problem

Workspace switch transitions show visible blinks from verificationMismatch
retry loops. macOS AX API is advisory — apps can reject frame positions.
Every frame write on the 32" display targets Y=1119 but apps accept Y=1115
or Y=1117 (2-4px mismatch). The layout engine recomputes Y=1119 on each
pass, creating an infinite oscillation. Linux WMs don't have this — they
have authority over window positions. macOS WMs must tolerate it.

## Fix 1: Axis-Aware Frame Verification Tolerance

**File:** `Sources/OmniWM/Core/Ax/AXWindow.swift`

Current verification uses uniform 1.0px tolerance for all four axes.
Y/height mismatches from macOS quantization are typically 2-4px.

Replace `approximatelyEqual(to:tolerance:)` call in frame verification
with axis-aware check:
- X tolerance: 1.0px (apps respect horizontal positioning)
- Y tolerance: 4.0px (macOS Y quantization from working area insets)
- Width tolerance: 1.0px (apps respect width)  
- Height tolerance: 4.0px (height follows Y — outer gap inset difference)

This breaks the retry cycle: a 2px Y mismatch no longer triggers
verificationMismatch, so accept-and-adapt doesn't fire, no dirty reflow,
no re-targeting.

## Fix 2: Port Upstream's Size Quantum Learning

**File:** `Sources/OmniWM/Core/Ax/AXManager.swift`

Port upstream's `learnSizeQuantum` and `frameWithinConvergence` to prevent
SIZE retry loops (e.g., Terminal character-cell snapping where width snaps
to 8px increments). The fork replaced upstream's AXFrameApplicationLedger
with inline accept-and-adapt but lost quantum learning.

### Minimal port (no new classes):

1. Add `sizeQuantumByWindowId: [Int: CGSize]` dictionary
2. Add `learnSizeQuantum(windowId:target:observed:)` — learns per-window
   snap quantum from width/height deltas. Max learnable: 16px. Only grows.
3. Add `frameWithinConvergence(cached:target:windowId:)` — position within
   1.0px, size within max(1.0, quantum). Used in frame write skip check.
4. Call `learnSizeQuantum` in accept-and-adapt block after accepting
5. Replace `approximatelyEqual(to:tolerance: 0.5)` in `enqueueFrameApplications`
   skip check with `frameWithinConvergence`
6. Clean up quantum on window removal, rekey on window ID change

### What NOT to port:
- `AXFrameTerminalRefusal` — fork's accept-and-adapt is better (immediate)
- `adoptObservedSizeAfterTerminalFrameRefusal` — fork already adapts
- `assumedAppliedWindowIds` — fork doesn't need re-verification
- Separate ledger class — inline approach matches fork's architecture

## Files Changed

1. `Sources/OmniWM/Core/Ax/AXWindow.swift` — axis-aware verification (~5 lines)
2. `Sources/OmniWM/Core/Ax/AXManager.swift` — quantum dict + 2 methods + wiring (~40 lines)

## Test Plan

1. Existing tests must pass (ViewportPipelineTests, ViewportGeometryTests)
2. New test: frame verification with Y mismatch within 4px → no verificationMismatch
3. New test: learnSizeQuantum learns width delta, frameWithinConvergence skips
4. New test: quantum cleared on window removal
5. Runtime: deploy, workspace switch × 3, count verificationMismatch in logs (target: 0)

## Evidence

- Memorygraph: `5afef9c1` (Bug #36 root cause)
- Expert panel: architect validated axis-aware tolerance, per-display Y NOT needed
- Upstream: `AXFrameApplicationLedger` quantum mechanism analyzed
- Research: yabai #235 confirms no macOS WM has a clean position solution
