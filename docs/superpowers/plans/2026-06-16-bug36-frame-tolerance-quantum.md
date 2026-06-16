# Bug #36: Axis-Aware Frame Tolerance + Size Quantum Learning

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate workspace switch blinks by adding axis-aware frame verification tolerance (Y/height 4px) and porting upstream's size quantum learning to prevent frame write retry loops.

**Architecture:** Fix 1 replaces uniform 1.0px tolerance with axis-aware (1px X/width, 4px Y/height) in frame write verification. Fix 2 adds per-window size quantum learning from upstream's `AXFrameApplicationLedger` — `learnSizeQuantum` + `frameWithinConvergence` inlined into AXManager.

**Tech Stack:** Swift 6.3, Apple Testing framework

**Spec:** `docs/superpowers/specs/2026-06-16-bug36-frame-tolerance-quantum-design.md`

---

### Task 1: Axis-aware frame verification tolerance

**Files:**
- Modify: `Sources/OmniWM/Core/Ax/AXWindow.swift:425`
- Modify: `Sources/OmniWM/Core/Ax/AXWindow.swift:124-125`

- [ ] **Step 1: Modify frame write verification (line 425)**

In `Sources/OmniWM/Core/Ax/AXWindow.swift`, find line 425:

```swift
            observedFrame.approximatelyEqual(to: frame, tolerance: 1.0) ? nil : .verificationMismatch
```

Replace with:

```swift
            observedFrame.axisAwareApproximatelyEqual(to: frame) ? nil : .verificationMismatch
```

- [ ] **Step 2: Modify confirmedFrame check (line 124-125)**

Find lines 124-125:

```swift
        if let observedFrame = writeResult.observedFrame,
           observedFrame.approximatelyEqual(to: targetFrame, tolerance: 1.0)
```

Replace with:

```swift
        if let observedFrame = writeResult.observedFrame,
           observedFrame.axisAwareApproximatelyEqual(to: targetFrame)
```

- [ ] **Step 3: Add axisAwareApproximatelyEqual extension**

In `Sources/OmniWM/Core/Support/CGGeometry+Extensions.swift`, add after the existing `approximatelyEqual` method:

```swift
    func axisAwareApproximatelyEqual(
        to other: CGRect,
        xyTolerance: CGFloat = 1.0,
        yhTolerance: CGFloat = 4.0
    ) -> Bool {
        abs(origin.x - other.origin.x) < xyTolerance
            && abs(origin.y - other.origin.y) < yhTolerance
            && abs(width - other.width) < xyTolerance
            && abs(height - other.height) < yhTolerance
    }
```

- [ ] **Step 4: Build**

Run: `cd ~/Documents/Personal/github/OmniWM && swift build -c debug 2>&1 | tail -3`

Expected: `Build complete!`

- [ ] **Step 5: Run tests**

Run: `swift test --filter "ViewportPipelineTests|ViewportGeometryTests" 2>&1 | tail -3`

Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add Sources/OmniWM/Core/Ax/AXWindow.swift Sources/OmniWM/Core/Support/CGGeometry+Extensions.swift
git commit -m "fix(#36): axis-aware frame verification — 4px Y/height tolerance

macOS AX API is advisory — apps can reject frame positions. External
displays consistently show 2-4px Y/height mismatches from working area
inset differences. The uniform 1.0px tolerance triggered verificationMismatch
on every frame write, causing visible blinks during workspace switches.

Split tolerance: 1px for X/width (apps respect), 4px for Y/height
(macOS quantization from outer gaps / menu bar insets).
"
```

---

### Task 2: Add FrameTolerance enum and size quantum infrastructure

**Files:**
- Modify: `Sources/OmniWM/Core/Support/CGGeometry+Extensions.swift`
- Modify: `Sources/OmniWM/Core/Ax/AXManager.swift`

- [ ] **Step 1: Add FrameTolerance enum**

In `Sources/OmniWM/Core/Support/CGGeometry+Extensions.swift`, add before the `CGRect` extension:

```swift
enum FrameTolerance {
    static let frameWrite: CGFloat = 1.0
    static let screenMatch: CGFloat = 2.0
}
```

- [ ] **Step 2: Add quantum dictionary and constant to AXManager**

In `Sources/OmniWM/Core/Ax/AXManager.swift`, find line 56 (`private var lastAppliedFrames`). Add after it:

```swift
    private var sizeQuantumByWindowId: [Int: CGSize] = [:]
    private static let maxLearnableSnapQuantum: CGFloat = 16
```

- [ ] **Step 3: Add learnSizeQuantum method**

Add as a private method in `AXManager` (after `shouldSuppressFrameChangeRelayout`):

```swift
    private func learnSizeQuantum(windowId: Int, target: CGRect, observed: CGRect) {
        let widthDelta = abs(observed.width - target.width)
        let heightDelta = abs(observed.height - target.height)
        let snapWidth = widthDelta > FrameTolerance.frameWrite && widthDelta <= Self.maxLearnableSnapQuantum
            ? widthDelta.rounded(.up) : 0
        let snapHeight = heightDelta > FrameTolerance.frameWrite && heightDelta <= Self.maxLearnableSnapQuantum
            ? heightDelta.rounded(.up) : 0
        guard snapWidth > 0 || snapHeight > 0 else { return }
        let existing = sizeQuantumByWindowId[windowId] ?? .zero
        sizeQuantumByWindowId[windowId] = CGSize(
            width: max(existing.width, snapWidth),
            height: max(existing.height, snapHeight)
        )
    }
```

- [ ] **Step 4: Add frameWithinConvergence method**

Add as a private method right after `learnSizeQuantum`:

```swift
    private func frameWithinConvergence(cached: CGRect, target: CGRect, windowId: Int) -> Bool {
        guard let quantum = sizeQuantumByWindowId[windowId] else {
            return cached.approximatelyEqual(to: target, tolerance: FrameTolerance.frameWrite)
        }
        guard abs(cached.minX - target.minX) < FrameTolerance.frameWrite,
              abs(cached.minY - target.minY) < FrameTolerance.frameWrite
        else {
            return false
        }
        return abs(cached.width - target.width) <= max(FrameTolerance.frameWrite, quantum.width)
            && abs(cached.height - target.height) <= max(FrameTolerance.frameWrite, quantum.height)
    }
```

- [ ] **Step 5: Build**

Run: `swift build -c debug 2>&1 | tail -3`

Expected: `Build complete!` (methods added but not yet wired)

- [ ] **Step 6: Commit**

```bash
git add Sources/OmniWM/Core/Support/CGGeometry+Extensions.swift Sources/OmniWM/Core/Ax/AXManager.swift
git commit -m "feat(#36): add FrameTolerance enum + size quantum infrastructure

Port upstream's learnSizeQuantum and frameWithinConvergence methods
inline into AXManager. Not yet wired — next commit connects them.
FrameTolerance enum replaces hardcoded tolerance values.
"
```

---

### Task 3: Wire quantum learning into accept-and-adapt + convergence check

**Files:**
- Modify: `Sources/OmniWM/Core/Ax/AXManager.swift`

- [ ] **Step 1: Call learnSizeQuantum in accept-and-adapt block**

Find line 724 in AXManager.swift:

```swift
                    lastAppliedFrames[resolvedWindowId] = observedFrame
```

Add immediately after:

```swift
                    learnSizeQuantum(windowId: resolvedWindowId, target: resolvedResult.targetFrame, observed: observedFrame)
```

- [ ] **Step 2: Replace convergence check in enqueueFrameApplications**

Find lines 476-478:

```swift
                } else if let cached = cachedFrame,
                          cached.approximatelyEqual(to: frame, tolerance: 0.5),
                          !hasRecentFailure
```

Replace with:

```swift
                } else if let cached = cachedFrame,
                          frameWithinConvergence(cached: cached, target: frame, windowId: windowId),
                          !hasRecentFailure
```

- [ ] **Step 3: Clean up quantum on window removal**

Find `removeWindowState` (line 254). Find line 281:

```swift
        lastAppliedFrames.removeValue(forKey: windowId)
```

Add immediately after:

```swift
        sizeQuantumByWindowId.removeValue(forKey: windowId)
```

- [ ] **Step 4: Rekey quantum on window ID change**

Find `rekeyWindowState` (line 196). Find lines 211-212:

```swift
        if let frame = lastAppliedFrames.removeValue(forKey: oldWindowId) {
            lastAppliedFrames[newWindowId] = frame
```

Add immediately after this block:

```swift
        if let quantum = sizeQuantumByWindowId.removeValue(forKey: oldWindowId) {
            sizeQuantumByWindowId[newWindowId] = quantum
        }
```

- [ ] **Step 5: Clear quantum on confirmed frame write**

Find line 703-706 (in the confirmed frame success branch):

```swift
            if let confirmedFrame = resolvedResult.confirmedFrame {
                lastAppliedFrames[resolvedWindowId] = confirmedFrame
                recentFrameWriteFailures.removeValue(forKey: resolvedWindowId)
                retryBudgetByWindowId.removeValue(forKey: resolvedWindowId)
```

Add after `retryBudgetByWindowId.removeValue`:

```swift
                sizeQuantumByWindowId.removeValue(forKey: resolvedWindowId)
```

- [ ] **Step 6: Build and test**

Run: `swift build -c debug 2>&1 | tail -3 && swift test --filter "ViewportPipelineTests|ViewportGeometryTests|NiriLayoutEngineTests" 2>&1 | tail -3`

Expected: Build clean, all tests pass

- [ ] **Step 7: Commit**

```bash
git add Sources/OmniWM/Core/Ax/AXManager.swift
git commit -m "fix(#36): wire quantum learning into accept-and-adapt + convergence

learnSizeQuantum called on every verificationMismatch acceptance —
learns per-window snap quantum (e.g., Terminal character-cell grid).
frameWithinConvergence replaces flat 0.5px tolerance in frame write
skip check — uses learned quantum for width/height, 1.0px for position.
Quantum cleared on confirmed write, window removal, and rekey.
"
```

---

### Task 4: Format, lint, full verification + runtime test

**Files:**
- No new files

- [ ] **Step 1: Format check**

Run: `make format-check 2>&1 | tail -1`

If not clean: `make format`

- [ ] **Step 2: Lint**

Run: `make lint 2>&1 | grep serious`

Expected: 0 serious

- [ ] **Step 3: Full test suite**

Run: `swift test --filter "ViewportPipelineTests|ViewportGeometryTests|NiriLayoutEngineTests|AtomicWindowTransferTests" 2>&1 | tail -3`

Expected: All pass

- [ ] **Step 4: Deploy + runtime test**

```bash
make build-sign
kill $(pgrep -x OmniWM); sleep 1; .build/debug/OmniWM &
sleep 3; .build/debug/omniwmctl ping
```

Then test:
1. Navigate right, workspace switch × 3
2. Check logs: `/usr/bin/log show --predicate 'processIdentifier == <PID> AND subsystem == "com.omniwm"' --last 30s --info --debug --style compact | grep -c verificationMismatch`
3. Target: 0 verificationMismatch on 32" display

- [ ] **Step 5: Commit Graphify + docs**

```bash
graphify update Sources/
git add Sources/graphify-out/ CLAUDE.md
git commit -m "chore: update Graphify + CLAUDE.md after Bug #36 fix"
```
