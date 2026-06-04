# Bug #14 Fix: Cap Window Stabilization Retry Limit

## Problem

Chrome internal renderer windows trigger ~99 `candidateFailed` events per session. Each window is retried via `scheduleCreatedWindowRetryIfNeeded` (capped at 5) and `scheduleWindowStabilizationRetryIfNeeded` (uncapped). The 17 retries per window come from multiple CGS event re-firings (same windowId created/destroyed rapidly) plus the create retry path, not from a stabilization loop. Still, the stabilization retry has no cap — a defensive fix.

## Fix

Add a retry counter to `scheduleWindowStabilizationRetryIfNeeded`. After 3 attempts, stop scheduling. Clean up counters on window destroy and app termination.

### Changes in `AXEventHandler.swift`:

**1. Add property** (after `pendingWindowStabilizationTasks`):
```swift
private var stabilizationRetryCount: [WindowToken: Int] = [:]
private static let maxStabilizationRetries = 3
```

**2. Modify `scheduleWindowStabilizationRetryIfNeeded`** — add retry cap:
```swift
private func scheduleWindowStabilizationRetryIfNeeded(
    token: WindowToken,
    decision: WindowDecision
) {
    guard decision.disposition == .undecided,
          decision.deferredReason != nil
    else { return }

    let count = (stabilizationRetryCount[token] ?? 0) + 1
    guard count <= Self.maxStabilizationRetries else {
        WMLog.ax.debug("stabilizationRetry: exhausted token=\(String(describing: token), privacy: .public) attempts=\(count - 1, privacy: .public)")
        stabilizationRetryCount.removeValue(forKey: token)
        return
    }
    stabilizationRetryCount[token] = count

    pendingWindowStabilizationTasks[token]?.cancel()
    pendingWindowStabilizationTasks[token] = Task { @MainActor [weak self] in
        try? await Task.sleep(for: Self.stabilizationRetryDelay)
        guard !Task.isCancelled, let self, let controller = self.controller else { return }
        self.pendingWindowStabilizationTasks.removeValue(forKey: token)
        _ = await controller.reevaluateWindowRules(for: [.window(token)])
    }
}
```

**3. Clear on successful admission** — in `trackPreparedCreate`, after `addWindow`:
```swift
stabilizationRetryCount.removeValue(forKey: candidate.token)
```

**4. Clear on window destroy** — in `handleWindowDestroyed` (where full WindowToken is resolved, not in `handleCGSWindowDestroyed`):
```swift
if let resolvedToken {
    stabilizationRetryCount.removeValue(forKey: resolvedToken)
}
```

**5. Clear on app termination** — in `cleanupFocusStateForTerminatedApp`, filter by PID:
```swift
stabilizationRetryCount = stabilizationRetryCount.filter { $0.key.pid != pid }
```

### Files to Modify

| File | Change |
|------|--------|
| `Sources/OmniWM/Core/Controller/AXEventHandler.swift` | Add retry count, modify stabilization retry, clear on admit/destroy/terminate |

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Window attributes available on 2nd retry | Admitted normally, count cleared |
| Window destroyed before retries exhaust | Count cleaned up in handleWindowDestroyed |
| App terminates | All counts for that PID filtered out |
| Same windowId reused by different app | Keyed by WindowToken (includes PID), no collision |

## Verification

1. `swift build` compiles
2. Restart Hiro, check: `grep "stabilizationRetry: exhausted" /private/tmp/omniwm-logs.txt`
3. Should see exhausted messages for Chrome internal windows capped at 3 attempts
