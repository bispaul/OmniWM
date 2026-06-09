import AppKit
import Foundation
import os

// MARK: - Delegate Protocol

@MainActor
protocol ManagedReplacementCorrelatorDelegate: AnyObject {
    // Actions (called during flush/replay)
    func correlatorRekeyReplacement(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        metadata: ManagedReplacementMetadata
    ) -> Bool
    func correlatorReplayCreate(_ create: ManagedReplacementCorrelator.PreparedCreate)
    func correlatorReplayDestroy(_ destroy: ManagedReplacementCorrelator.PreparedDestroy)
    func correlatorShouldSuppressDestroyReplay(windowId: UInt32) -> Bool

    // Queries (called during structural matching)
    func correlatorFallbackWorkspaceId() -> WorkspaceDescriptor.ID?
    func correlatorEntriesForPid(_ pid: pid_t) -> [WindowModel.Entry]
    func correlatorWindowInfo(windowId: UInt32) -> WindowServerInfo?
}

// MARK: - ManagedReplacementCorrelator

@MainActor
final class ManagedReplacementCorrelator {
    // MARK: - Internal Types

    struct ManagedReplacementTraceEvent: Equatable {
        enum Kind: Equatable {
            case enqueued(
                policy: String,
                createCount: Int,
                destroyCount: Int,
                holdCount: Int,
                deadlineReset: Bool
            )
            case flushed(
                policy: String,
                createCount: Int,
                destroyCount: Int,
                holdCount: Int,
                elapsedMillis: Int
            )
            case matched(policy: String, elapsedMillis: Int)
        }

        let timestamp: TimeInterval
        let pid: pid_t
        let workspaceId: WorkspaceDescriptor.ID
        let kind: Kind
    }

    struct PreparedCreate {
        let windowId: UInt32
        let token: WindowToken
        let axRef: AXWindowRef
        let ruleEffects: ManagedWindowRuleEffects
        let replacementMetadata: ManagedReplacementMetadata
        let hasStructuralReplacementWorkspaceMatch: Bool
        let requiresPostCreateLifecycleVerification: Bool

        var bundleId: String? {
            replacementMetadata.bundleId
        }

        var workspaceId: WorkspaceDescriptor.ID {
            replacementMetadata.workspaceId
        }

        var mode: TrackedWindowMode {
            replacementMetadata.mode
        }
    }

    struct PreparedDestroy {
        let token: WindowToken
        let replacementMetadata: ManagedReplacementMetadata

        var bundleId: String? {
            replacementMetadata.bundleId
        }

        var workspaceId: WorkspaceDescriptor.ID {
            replacementMetadata.workspaceId
        }

        var mode: TrackedWindowMode {
            replacementMetadata.mode
        }
    }

    // MARK: - Private Types

    private struct ManagedReplacementKey: Hashable {
        let pid: pid_t
        let workspaceId: WorkspaceDescriptor.ID
    }

    private enum ManagedReplacementCorrelationPolicy {
        case structural
    }

    private struct PendingManagedCreate {
        let sequence: UInt64
        let candidate: PreparedCreate
    }

    private struct PendingManagedDestroy {
        let sequence: UInt64
        let candidate: PreparedDestroy
    }

    private enum PendingManagedReplacementEvent {
        case create(PendingManagedCreate)
        case destroy(PendingManagedDestroy)

        var sequence: UInt64 {
            switch self {
            case let .create(create): create.sequence
            case let .destroy(destroy): destroy.sequence
            }
        }
    }

    private struct PendingManagedReplacementBurst {
        let policy: ManagedReplacementCorrelationPolicy
        let firstEventUptime: TimeInterval
        var creates: [PendingManagedCreate] = []
        var destroys: [PendingManagedDestroy] = []

        mutating func append(create: PendingManagedCreate) {
            guard !creates.contains(where: { $0.candidate.token == create.candidate.token }) else { return }
            creates.append(create)
        }

        mutating func append(destroy: PendingManagedDestroy) {
            guard !destroys.contains(where: { $0.candidate.token == destroy.candidate.token }) else { return }
            destroys.append(destroy)
        }

        var orderedEvents: [PendingManagedReplacementEvent] {
            let events = creates.map(PendingManagedReplacementEvent.create) + destroys
                .map(PendingManagedReplacementEvent.destroy)
            return events.sorted { $0.sequence < $1.sequence }
        }

        func orderedEvents(excludingSequences sequences: Set<UInt64>) -> [PendingManagedReplacementEvent] {
            orderedEvents.filter { !sequences.contains($0.sequence) }
        }
    }

    private struct MatchedManagedReplacementPair {
        let destroy: PendingManagedDestroy
        let create: PendingManagedCreate

        var excludedSequences: Set<UInt64> {
            [destroy.sequence, create.sequence]
        }
    }

    private struct StructuralReplacementMatch {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
    }

    // MARK: - Constants

    private static let graceDelay: Duration = .milliseconds(150)
    private static let traceLimit = 128
    private static let traceLoggingEnabled =
        ProcessInfo.processInfo.environment["OMNIWM_DEBUG_MANAGED_REPLACEMENT"] == "1"

    // MARK: - State

    weak var delegate: ManagedReplacementCorrelatorDelegate?
    private var pendingBursts: [ManagedReplacementKey: PendingManagedReplacementBurst] = [:]
    private var pendingTasks: [ManagedReplacementKey: Task<Void, Never>] = [:]
    private var nextSequence: UInt64 = 0
    private var trace: [ManagedReplacementTraceEvent] = []

    // MARK: - ForTests Hooks

    var timeSourceForTests: (() -> TimeInterval)?

    // MARK: - Public API

    func shouldDelayCreate(_ candidate: PreparedCreate) -> Bool {
        guard correlationPolicy(for: candidate.replacementMetadata) != nil else {
            return false
        }

        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        if pendingBursts[key] != nil {
            return true
        }

        return candidate.hasStructuralReplacementWorkspaceMatch
    }

    func shouldDelayDestroy(_ candidate: PreparedDestroy) -> Bool {
        correlationPolicy(for: candidate.replacementMetadata) != nil
    }

    func enqueueCreate(_ candidate: PreparedCreate) {
        guard let policy = correlationPolicy(for: candidate.replacementMetadata) else { return }
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        let isNewBurst = pendingBursts[key] == nil
        var burst = pendingBursts[key] ?? PendingManagedReplacementBurst(
            policy: policy,
            firstEventUptime: currentUptime()
        )
        let pendingCreate = PendingManagedCreate(sequence: nextEventSequence(), candidate: candidate)
        burst.append(create: pendingCreate)
        pendingBursts[key] = burst
        let resetExistingDeadline = isNewBurst
        recordTrace(
            key: key,
            kind: .enqueued(
                policy: policyName(policy),
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                deadlineReset: resetExistingDeadline
            )
        )
        scheduleFlush(
            for: key,
            policy: policy,
            resetExistingDeadline: resetExistingDeadline
        )
    }

    func enqueueDestroy(_ candidate: PreparedDestroy) {
        guard let policy = correlationPolicy(for: candidate.replacementMetadata) else { return }
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        let isNewBurst = pendingBursts[key] == nil
        var burst = pendingBursts[key] ?? PendingManagedReplacementBurst(
            policy: policy,
            firstEventUptime: currentUptime()
        )
        let pendingDestroy = PendingManagedDestroy(sequence: nextEventSequence(), candidate: candidate)
        burst.append(destroy: pendingDestroy)
        pendingBursts[key] = burst
        let resetExistingDeadline = isNewBurst
        recordTrace(
            key: key,
            kind: .enqueued(
                policy: policyName(policy),
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                deadlineReset: resetExistingDeadline
            )
        )
        scheduleFlush(
            for: key,
            policy: policy,
            resetExistingDeadline: resetExistingDeadline
        )
    }

    func structuralReplacementWorkspaceIdForCreate(
        token: WindowToken,
        bundleId: String?,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> WorkspaceDescriptor.ID? {
        structuralReplacementMatch(
            token: token,
            bundleId: bundleId,
            mode: mode,
            facts: facts
        )?.workspaceId
    }

    @discardableResult
    func rekeyIfNeeded(
        token: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        bundleId: String?,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> Bool {
        guard let match = structuralReplacementMatch(
            token: token,
            bundleId: bundleId,
            mode: mode,
            facts: facts
        ) else {
            return false
        }

        let metadata = makeManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: match.workspaceId,
            mode: mode,
            facts: facts
        )
        return delegate?.correlatorRekeyReplacement(
            from: match.token,
            to: token,
            windowId: windowId,
            axRef: axRef,
            metadata: metadata
        ) ?? false
    }

    func reset() {
        for (_, task) in pendingTasks {
            task.cancel()
        }
        pendingTasks.removeAll()
        pendingBursts.removeAll()
        nextSequence = 0
    }

    func flushForTests() {
        let keys = pendingBursts.keys.sorted {
            ($0.pid, $0.workspaceId.uuidString) < ($1.pid, $1.workspaceId.uuidString)
        }
        for key in keys {
            pendingTasks.removeValue(forKey: key)?.cancel()
            flushBurst(for: key)
        }
    }

    func traceSnapshotForTests() -> [ManagedReplacementTraceEvent] {
        trace
    }

    func clearTrace() {
        trace.removeAll(keepingCapacity: true)
    }

    // MARK: - Metadata Building (internal for AXEventHandler use)

    func makeManagedReplacementMetadata(
        bundleId: String?,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: workspaceId,
            mode: mode,
            role: facts.ax.role,
            subrole: facts.ax.subrole,
            title: facts.ax.title,
            windowLevel: facts.windowServer?.level,
            parentWindowId: normalizedParentWindowId(facts.windowServer?.parentId),
            frame: facts.windowServer?.frame,
            transientWindowServerEvidence: facts.windowServer?.hasTransientSurfaceEvidence ?? false,
            degradedWindowServerChildEvidence: facts.degradedWindowServerChildEvidence
        )
    }

    func cachedManagedReplacementMetadata(
        for entry: WindowModel.Entry,
        fallbackBundleId: String?
    ) -> ManagedReplacementMetadata {
        var metadata = entry.managedReplacementMetadata ?? ManagedReplacementMetadata(
            bundleId: fallbackBundleId,
            workspaceId: entry.workspaceId,
            mode: entry.mode,
            role: nil,
            subrole: nil,
            title: nil,
            windowLevel: nil,
            parentWindowId: nil,
            frame: nil
        )
        metadata.bundleId = metadata.bundleId ?? fallbackBundleId
        metadata.workspaceId = entry.workspaceId
        metadata.mode = entry.mode
        return metadata
    }

    func overlayWindowServerInfo(
        _ windowInfo: WindowServerInfo?,
        onto metadata: ManagedReplacementMetadata
    ) -> ManagedReplacementMetadata {
        guard let windowInfo else { return metadata }
        var metadata = metadata
        metadata.title = windowInfo.title ?? metadata.title
        metadata.windowLevel = windowInfo.level
        metadata.parentWindowId = normalizedParentWindowId(windowInfo.parentId) ?? metadata.parentWindowId
        if !windowInfo.frame.isNull, !windowInfo.frame.isEmpty {
            metadata.frame = windowInfo.frame
        }
        return metadata
    }

    func managedReplacementNeedsLiveAXFacts(
        _ metadata: ManagedReplacementMetadata
    ) -> Bool {
        guard metadata.role != nil, metadata.subrole != nil else {
            return true
        }
        return !hasStructuralAnchor(metadata)
    }

    // MARK: - Lifecycle (private)

    private func scheduleFlush(
        for key: ManagedReplacementKey,
        policy: ManagedReplacementCorrelationPolicy,
        resetExistingDeadline: Bool
    ) {
        if resetExistingDeadline {
            pendingTasks.removeValue(forKey: key)?.cancel()
        } else if pendingTasks[key] != nil {
            return
        }

        let delay = graceDelay(for: policy)
        pendingTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flushBurst(for: key)
        }
    }

    private func flushBurst(for key: ManagedReplacementKey) {
        // Re-entrancy safe: burst is removed from pendingBursts BEFORE replay
        pendingTasks.removeValue(forKey: key)?.cancel()
        guard let burst = pendingBursts.removeValue(forKey: key) else { return }
        let elapsedMillis = max(
            0,
            Int(((currentUptime() - burst.firstEventUptime) * 1000).rounded())
        )
        recordTrace(
            key: key,
            kind: .flushed(
                policy: policyName(burst.policy),
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                elapsedMillis: elapsedMillis
            )
        )

        if let pair = matchedPair(in: burst) {
            if completeManagedReplacement(destroy: pair.destroy, create: pair.create) {
                recordTrace(
                    key: key,
                    kind: .matched(
                        policy: policyName(burst.policy),
                        elapsedMillis: elapsedMillis
                    )
                )
                replayEvents(
                    burst.orderedEvents(excludingSequences: pair.excludedSequences)
                )
            } else {
                replayEvents(burst.orderedEvents)
            }
            return
        }

        replayEvents(burst.orderedEvents)
    }

    @discardableResult
    private func completeManagedReplacement(
        destroy: PendingManagedDestroy,
        create: PendingManagedCreate
    ) -> Bool {
        delegate?.correlatorRekeyReplacement(
            from: destroy.candidate.token,
            to: create.candidate.token,
            windowId: create.candidate.windowId,
            axRef: create.candidate.axRef,
            metadata: create.candidate.replacementMetadata
        ) ?? false
    }

    private func replayEvents(_ events: [PendingManagedReplacementEvent]) {
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            switch event {
            case let .create(create):
                delegate?.correlatorReplayCreate(create.candidate)
            case let .destroy(destroy):
                let windowId = UInt32(destroy.candidate.token.windowId)
                if delegate?.correlatorShouldSuppressDestroyReplay(windowId: windowId) == true {
                    WMLog.ax.info(
                        "Deferred destroy suppressed (wake/reconfig, still in window server): windowId=\(windowId, privacy: .public)"
                    )
                    continue
                }
                delegate?.correlatorReplayDestroy(destroy.candidate)
            }
        }
    }

    private func nextEventSequence() -> UInt64 {
        defer { nextSequence += 1 }
        return nextSequence
    }

    // MARK: - Matching (private, pure)

    private func matchedPair(
        in burst: PendingManagedReplacementBurst
    ) -> MatchedManagedReplacementPair? {
        var matchedPair: MatchedManagedReplacementPair?

        for destroy in burst.destroys {
            for create in burst.creates {
                guard destroy.candidate.token != create.candidate.token,
                      metadataMatches(
                          oldToken: destroy.candidate.token,
                          old: destroy.candidate.replacementMetadata,
                          new: create.candidate.replacementMetadata,
                          newFacts: nil
                      )
                else {
                    continue
                }

                if matchedPair != nil {
                    return nil
                }
                matchedPair = MatchedManagedReplacementPair(destroy: destroy, create: create)
            }
        }

        return matchedPair
    }

    private func structuralReplacementMatch(
        token: WindowToken,
        bundleId: String?,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> StructuralReplacementMatch? {
        guard let fallbackWorkspaceId = delegate?.correlatorFallbackWorkspaceId() else {
            return nil
        }

        let baseMetadata = makeManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: fallbackWorkspaceId,
            mode: mode,
            facts: facts
        )
        guard correlationPolicy(for: baseMetadata) != nil else { return nil }

        var match: StructuralReplacementMatch?
        func recordMatch(token: WindowToken, workspaceId: WorkspaceDescriptor.ID) -> Bool {
            if match != nil {
                return false
            }
            match = StructuralReplacementMatch(token: token, workspaceId: workspaceId)
            return true
        }

        func matches(_ oldMetadata: ManagedReplacementMetadata, oldToken: WindowToken) -> Bool {
            var newMetadata = baseMetadata
            newMetadata.workspaceId = oldMetadata.workspaceId
            return metadataMatches(
                oldToken: oldToken,
                old: oldMetadata,
                new: newMetadata,
                newFacts: facts
            )
        }

        for burst in pendingBursts.values {
            for destroy in burst.destroys where destroy.candidate.token.pid == token.pid {
                let metadata = destroy.candidate.replacementMetadata
                if matches(metadata, oldToken: destroy.candidate.token),
                   !recordMatch(token: destroy.candidate.token, workspaceId: metadata.workspaceId)
                {
                    return nil
                }
            }
        }

        guard let entries = delegate?.correlatorEntriesForPid(token.pid) else { return match }
        for entry in entries where entry.token != token {
            let cachedMetadata = cachedManagedReplacementMetadata(
                for: entry,
                fallbackBundleId: bundleId
            )
            if matches(cachedMetadata, oldToken: entry.token),
               !recordMatch(token: entry.token, workspaceId: cachedMetadata.workspaceId)
            {
                return nil
            }
            if match?.token == entry.token {
                continue
            }
            let liveMetadata = overlayWindowServerInfo(
                UInt32(exactly: entry.windowId).flatMap { delegate?.correlatorWindowInfo(windowId: $0) },
                onto: cachedMetadata
            )
            if liveMetadata != cachedMetadata,
               matches(liveMetadata, oldToken: entry.token),
               !recordMatch(token: entry.token, workspaceId: liveMetadata.workspaceId)
            {
                return nil
            }
        }

        return match
    }

    private func correlationPolicy(
        for metadata: ManagedReplacementMetadata
    ) -> ManagedReplacementCorrelationPolicy? {
        guard metadata.role != nil,
              metadata.subrole != nil,
              hasStructuralAnchor(metadata)
        else { return nil }
        return .structural
    }

    private func metadataMatches(
        oldToken: WindowToken,
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata,
        newFacts: WindowRuleFacts?
    ) -> Bool {
        if isDirectFloatingChild(oldToken: oldToken, new: new, newFacts: newFacts) {
            return false
        }

        guard correlationPolicy(for: old) != nil,
              correlationPolicy(for: new) != nil,
              bundleIdsMatch(old.bundleId, new.bundleId),
              old.workspaceId == new.workspaceId,
              old.role == new.role,
              old.subrole == new.subrole,
              windowLevelsMatch(old.windowLevel, new.windowLevel)
        else {
            return false
        }

        return structuralAnchorsMatch(oldToken: oldToken, old: old, new: new)
    }

    private func isDirectFloatingChild(
        oldToken: WindowToken,
        new: ManagedReplacementMetadata,
        newFacts: WindowRuleFacts?
    ) -> Bool {
        guard new.mode == .floating,
              let oldWindowId = UInt32(exactly: oldToken.windowId),
              new.parentWindowId == oldWindowId
        else {
            return false
        }

        if hasAXChildEvidence(new) {
            return true
        }

        if new.degradedWindowServerChildEvidence {
            return true
        }

        return newFacts?.degradedWindowServerChildEvidence == true
    }

    private func hasAXChildEvidence(_ metadata: ManagedReplacementMetadata) -> Bool {
        if metadata.role == kAXSheetRole as String {
            return true
        }

        guard let subrole = metadata.subrole else {
            return false
        }

        return subrole == kAXDialogSubrole as String
            || subrole == kAXSystemDialogSubrole as String
            || subrole != kAXStandardWindowSubrole as String
    }

    private func hasStructuralAnchor(
        _ metadata: ManagedReplacementMetadata
    ) -> Bool {
        metadata.parentWindowId != nil || metadata.frame != nil
    }

    private func bundleIdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs?.lowercased(), rhs?.lowercased()) {
        case let (lhs?, rhs?):
            return lhs == rhs
        default:
            return true
        }
    }

    private func windowLevelsMatch(_ lhs: Int32?, _ rhs: Int32?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }

    private func structuralAnchorsMatch(
        oldToken: WindowToken,
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata
    ) -> Bool {
        let framesClose = framesAreClose(old.frame, new.frame)
        let hasFrameEvidence = old.frame != nil && new.frame != nil

        switch (old.parentWindowId, new.parentWindowId) {
        case let (oldParentWindowId?, newParentWindowId?) where oldParentWindowId == newParentWindowId:
            return hasFrameEvidence ? framesClose : true
        case let (_, newParentWindowId?) where UInt32(exactly: oldToken.windowId) == newParentWindowId:
            return framesClose
        case (_?, _?):
            return false
        default:
            return framesClose
        }
    }

    private func framesAreClose(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        guard let lhs, let rhs else { return false }

        return abs(lhs.midX - rhs.midX) <= 96
            && abs(lhs.midY - rhs.midY) <= 96
            && abs(lhs.width - rhs.width) <= 64
            && abs(lhs.height - rhs.height) <= 64
    }

    // MARK: - Helpers (private)

    private func normalizedParentWindowId(_ parentWindowId: UInt32?) -> UInt32? {
        guard let parentWindowId, parentWindowId != 0 else { return nil }
        return parentWindowId
    }

    private func currentUptime() -> TimeInterval {
        timeSourceForTests?() ?? ProcessInfo.processInfo.systemUptime
    }

    private func policyName(_ policy: ManagedReplacementCorrelationPolicy) -> String {
        switch policy {
        case .structural:
            "structural"
        }
    }

    private func graceDelay(for policy: ManagedReplacementCorrelationPolicy) -> Duration {
        switch policy {
        case .structural:
            Self.graceDelay
        }
    }

    private func recordTrace(
        key: ManagedReplacementKey,
        kind: ManagedReplacementTraceEvent.Kind
    ) {
        let event = ManagedReplacementTraceEvent(
            timestamp: currentUptime(),
            pid: key.pid,
            workspaceId: key.workspaceId,
            kind: kind
        )
        if trace.count == Self.traceLimit {
            trace.removeFirst()
        }
        trace.append(event)

        if Self.traceLoggingEnabled {
            fputs(
                "[ManagedReplacement] pid=\(key.pid) workspace=\(key.workspaceId.uuidString) kind=\(String(describing: kind))\n",
                stderr
            )
        }
    }
}
