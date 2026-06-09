# Extraction 3: DisplayLinkManager — Design Spec

## Goal

Extract CADisplayLink lifecycle from LayoutRefreshController into a standalone DisplayLinkManager, removing NSObject inheritance from LRC.

## Why standalone class

- NSObject required for `@objc displayLinkFired` selector — moves to DLM
- Owns 2 state dictionaries (displayLinksByDisplay, refreshRateByDisplay)
- LRC drops NSObject + screen observer setup
- Expert panel validated thin boundary

## Boundary

**Moves to DisplayLinkManager:**
- `displayLinksByDisplay: [CGDirectDisplayID: CADisplayLink]`
- `refreshRateByDisplay: [CGDirectDisplayID: Double]`
- Screen change observer registration
- `getOrCreateDisplayLink(for:)` — NSScreen + CADisplayLink factory
- `displayLinkFired(_:)` — `@objc` selector, delegates to protocol
- `detectRefreshRates()` — CGDisplayCopyDisplayMode queries
- `handleScreenParametersChanged()` — calls detectRefreshRates
- `stopDisplayLinkIfIdle(for:)` — delegates idle check to protocol

**Stays on LayoutRefreshController:**
- `closingAnimationsByDisplay` — tickClosingAnimations calls AXWindowService.setFrame
- `dirtyWorkspaceIds` — drainDirtyWorkspaces calls enqueueRefresh
- All start/stop animation methods — need workspaceManager, motionPolicy, handlers
- `cleanupForMonitorDisconnect` — calls `displayLinkManager.removeDisplayLink` for the link part

## Design

```swift
@MainActor
protocol DisplayLinkManagerDelegate: AnyObject {
    func displayLinkDidFire(displayId: CGDirectDisplayID, targetTime: CFTimeInterval)
    func isDisplayLinkNeeded(for displayId: CGDirectDisplayID) -> Bool
}

@MainActor
final class DisplayLinkManager: NSObject {
    weak var delegate: DisplayLinkManagerDelegate?
    private var displayLinksByDisplay: [CGDirectDisplayID: CADisplayLink] = [:]
    private var refreshRateByDisplay: [CGDirectDisplayID: Double] = [:]
    private var screenChangeObserver: NSObjectProtocol?

    func setup()
    func teardown()
    func ensureRunning(for displayId: CGDirectDisplayID)
    func removeDisplayLink(for displayId: CGDirectDisplayID)
    func stopIfIdle(for displayId: CGDirectDisplayID)
    func refreshRate(for displayId: CGDirectDisplayID) -> Double
    var activeDisplayIds: Set<CGDirectDisplayID> { get }
}
```

LRC conformance:
```swift
extension LayoutRefreshController: DisplayLinkManagerDelegate {
    func displayLinkDidFire(displayId: CGDirectDisplayID, targetTime: CFTimeInterval) {
        niriHandler.tickScrollAnimation(targetTime: targetTime, displayId: displayId)
        dwindleHandler.tickDwindleAnimation(targetTime: targetTime, displayId: displayId)
        tickClosingAnimations(targetTime: targetTime, displayId: displayId)
        drainDirtyWorkspaces(displayId: displayId)
    }

    func isDisplayLinkNeeded(for displayId: CGDirectDisplayID) -> Bool {
        niriHandler.hasScrollAnimation(for: displayId)
        || dwindleHandler.hasDwindleAnimation(for: displayId)
        || !(layoutState.closingAnimationsByDisplay[displayId]?.isEmpty ?? true)
        || !layoutState.dirtyWorkspaceIds.isEmpty
    }
}
```

## What does NOT change
- No per-display drain scoping (deferred to Fix D)
- No animation ownership change
- Public API of LRC unchanged

## Estimated size
- DisplayLinkManager.swift: ~80 lines
- LRC delta: -80 lines removed, +20 delegate conformance = -60 net
- LRC drops NSObject superclass

## Risk: LOW
Thin boundary, mechanical move. NSObject moves to DLM. Delegate pattern is standard.
