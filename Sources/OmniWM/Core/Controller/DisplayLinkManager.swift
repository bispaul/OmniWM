import AppKit
import CoreGraphics
import QuartzCore

@MainActor
protocol DisplayLinkManagerDelegate: AnyObject {
    func displayLinkDidFire(displayId: CGDirectDisplayID, targetTime: CFTimeInterval)
    func isDisplayLinkNeeded(for displayId: CGDirectDisplayID) -> Bool
}

/// Owns the CADisplayLink lifecycle: creation, invalidation, screen-change
/// observation, and refresh-rate detection. Delegates per-frame work back
/// to ``DisplayLinkManagerDelegate``.
@MainActor
final class DisplayLinkManager: NSObject {
    weak var delegate: DisplayLinkManagerDelegate?
    private var displayLinksByDisplay: [CGDirectDisplayID: CADisplayLink] = [:]
    private(set) var refreshRateByDisplay: [CGDirectDisplayID: Double] = [:]
    private var screenChangeObserver: NSObjectProtocol?

    // MARK: - Setup / Teardown

    func setup() {
        detectRefreshRates()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenParametersChanged()
            }
        }
    }

    func teardown() {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
        for (_, link) in displayLinksByDisplay {
            link.invalidate()
        }
        displayLinksByDisplay.removeAll()
    }

    // MARK: - Display Link Lifecycle

    func getOrCreateDisplayLink(for displayId: CGDirectDisplayID) -> CADisplayLink? {
        if let existing = displayLinksByDisplay[displayId] {
            return existing
        }

        guard let screen = NSScreen.screens.first(where: { $0.displayId == displayId }) else {
            return nil
        }
        WMLog.layout.debug("Display link created")
        let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        displayLinksByDisplay[displayId] = link
        return link
    }

    func removeDisplayLink(for displayId: CGDirectDisplayID) {
        if let link = displayLinksByDisplay.removeValue(forKey: displayId) {
            WMLog.layout.debug("Display link invalidated")
            link.invalidate()
        }
    }

    func stopDisplayLinkIfIdle(for displayId: CGDirectDisplayID) {
        if delegate?.isDisplayLinkNeeded(for: displayId) == false {
            if let link = displayLinksByDisplay.removeValue(forKey: displayId) {
                link.invalidate()
            }
        }
    }

    // MARK: - Refresh Rates

    func refreshRate(for displayId: CGDirectDisplayID) -> Double {
        refreshRateByDisplay[displayId] ?? 60.0
    }

    // MARK: - Query

    var activeDisplayIds: Set<CGDirectDisplayID> {
        Set(displayLinksByDisplay.keys)
    }

    /// Returns a display ID that currently has an active link, or falls back
    /// to the main screen. Useful for test helpers that need *any* valid ID.
    var anyActiveDisplayId: CGDirectDisplayID? {
        displayLinksByDisplay.keys.first ?? NSScreen.main?.displayId
    }

    // MARK: - Reset (for tests / full state wipe)

    func resetAll() {
        for (_, link) in displayLinksByDisplay {
            link.invalidate()
        }
        displayLinksByDisplay.removeAll()
    }

    // MARK: - Private

    private func detectRefreshRates() {
        refreshRateByDisplay.removeAll()
        for screen in NSScreen.screens {
            guard let displayId = screen.displayId else { continue }
            if let mode = CGDisplayCopyDisplayMode(displayId) {
                let rate = mode.refreshRate > 0 ? mode.refreshRate : 60.0
                refreshRateByDisplay[displayId] = rate
            } else {
                refreshRateByDisplay[displayId] = 60.0
            }
        }
    }

    private func handleScreenParametersChanged() {
        detectRefreshRates()
    }

    @objc private func displayLinkFired(_ displayLink: CADisplayLink) {
        guard let displayId = displayLinksByDisplay.first(where: { $0.value === displayLink })?.key
        else { return }

        delegate?.displayLinkDidFire(displayId: displayId, targetTime: displayLink.targetTimestamp)
    }
}
