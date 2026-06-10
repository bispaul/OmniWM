import Foundation

enum FocusPolicyLeaseOwner: String, Equatable {
    case nativeMenu = "native_menu"
    case nativeAppSwitch = "native_app_switch"
    case ruleCreatedFloatingWindow = "rule_created_floating_window"
}

struct FocusPolicyLease: Equatable {
    let owner: FocusPolicyLeaseOwner
    let reason: String
    let suppressesFocusFollowsMouse: Bool
    let expiresAt: Date?
    let monitorId: Monitor.ID?
}

enum FocusPolicyRequest: Equatable {
    case focusFollowsMouse
    case managedAppActivation(source: ActivationEventSource)
}

struct FocusPolicyDecision: Equatable {
    let allowsFocusChange: Bool
    let reason: String?

    static let allow = FocusPolicyDecision(allowsFocusChange: true, reason: nil)

    static func deny(reason: String) -> FocusPolicyDecision {
        FocusPolicyDecision(allowsFocusChange: false, reason: reason)
    }
}

@MainActor
final class FocusPolicyEngine {
    private static let effectiveLeasePriority: [FocusPolicyLeaseOwner] = [
        .nativeMenu,
        .nativeAppSwitch,
        .ruleCreatedFloatingWindow
    ]

    private let nowProvider: () -> Date
    private var leasesByOwner: [FocusPolicyLeaseOwner: FocusPolicyLease] = [:]
    private var activeLeaseStorage: FocusPolicyLease?
    var activeLease: FocusPolicyLease? {
        pruneExpiredLeasesIfNeeded()
        return activeLeaseStorage
    }

    var onLeaseChanged: ((FocusPolicyLease?) -> Void)?

    init(nowProvider: @escaping () -> Date = Date.init) {
        self.nowProvider = nowProvider
    }

    func beginLease(
        owner: FocusPolicyLeaseOwner,
        reason: String,
        suppressesFocusFollowsMouse: Bool = true,
        duration: TimeInterval? = 0.35,
        monitorId: Monitor.ID? = nil
    ) {
        let expiresAt = duration.map { nowProvider().addingTimeInterval($0) }
        let lease = FocusPolicyLease(
            owner: owner,
            reason: reason,
            suppressesFocusFollowsMouse: suppressesFocusFollowsMouse,
            expiresAt: expiresAt,
            monitorId: monitorId
        )
        leasesByOwner[owner] = lease
        reconcileActiveLease(notify: true)
    }

    func endLease(owner: FocusPolicyLeaseOwner) {
        guard leasesByOwner.removeValue(forKey: owner) != nil else { return }
        reconcileActiveLease(notify: true)
    }

    func evaluate(_ request: FocusPolicyRequest, onMonitor monitorId: Monitor.ID? = nil) -> FocusPolicyDecision {
        pruneExpiredLeasesIfNeeded()

        switch request {
        case .focusFollowsMouse:
            guard let lease = suppressingFocusFollowsMouseLease(onMonitor: monitorId) else { return .allow }
            return .deny(reason: lease.reason)
        case let .managedAppActivation(source):
            if let menuLease = leasesByOwner[.nativeMenu], !source.isAuthoritative {
                return .deny(reason: menuLease.reason)
            }
            return .allow
        }
    }

    private func pruneExpiredLeasesIfNeeded() {
        let now = nowProvider()
        let expiredOwners = leasesByOwner.compactMap { owner, lease -> FocusPolicyLeaseOwner? in
            guard let expiresAt = lease.expiresAt, expiresAt <= now else {
                return nil
            }
            return owner
        }

        guard !expiredOwners.isEmpty else { return }
        for owner in expiredOwners {
            leasesByOwner.removeValue(forKey: owner)
        }
        reconcileActiveLease(notify: true)
    }

    private func reconcileActiveLease(notify: Bool) {
        let nextLease = effectiveLease()
        guard nextLease != activeLeaseStorage else { return }
        activeLeaseStorage = nextLease
        if notify {
            onLeaseChanged?(nextLease)
        }
    }

    private func effectiveLease() -> FocusPolicyLease? {
        for owner in Self.effectiveLeasePriority {
            if let lease = leasesByOwner[owner] {
                return lease
            }
        }
        return nil
    }

    /// Whether a non-nativeAppSwitch lease is currently suppressing focus-follows-mouse.
    /// Used by focus reconciliation to decide whether to sync macOS keyboard focus.
    /// The nativeAppSwitch lease is excluded because reconciliation IS the completion
    /// of a native app switch — it should not block itself.
    var hasNonAppSwitchFocusSuppression: Bool {
        pruneExpiredLeasesIfNeeded()
        for owner in Self.effectiveLeasePriority where owner != .nativeAppSwitch {
            if let lease = leasesByOwner[owner], lease.suppressesFocusFollowsMouse {
                return true
            }
        }
        return false
    }

    private func suppressingFocusFollowsMouseLease(onMonitor monitorId: Monitor.ID? = nil) -> FocusPolicyLease? {
        for owner in Self.effectiveLeasePriority {
            if let lease = leasesByOwner[owner], lease.suppressesFocusFollowsMouse {
                if let leaseMonitor = lease.monitorId, let queryMonitor = monitorId, leaseMonitor != queryMonitor {
                    continue
                }
                return lease
            }
        }
        return nil
    }
}
