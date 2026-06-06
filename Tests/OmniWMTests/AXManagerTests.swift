import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import Testing

private func axManagerTestWriteResult(
    targetFrame: CGRect,
    currentFrameHint: CGRect?,
    observedFrame: CGRect?,
    failureReason: AXFrameWriteFailureReason?
) -> AXFrameWriteResult {
    AXFrameWriteResult(
        targetFrame: targetFrame,
        observedFrame: observedFrame,
        writeOrder: AXWindowService.frameWriteOrder(
            currentFrame: currentFrameHint,
            targetFrame: targetFrame
        ),
        sizeError: .success,
        positionError: .success,
        failureReason: failureReason
    )
}

// MARK: - Accept-and-Adapt Tests (Phase 1)

@Test @MainActor func verificationMismatchAcceptsObservedFrame() {
    let manager = AXManager()
    let pid: pid_t = getpid()
    let windowId = 9903
    let targetFrame = CGRect(x: 100, y: 100, width: 500, height: 400)
    let observedFrame = CGRect(x: 100, y: 100, width: 600, height: 400)

    manager.frameApplyOverrideForTests = { requests in
        return requests.map { req in
            AXFrameApplyResult(
                requestId: req.requestId,
                pid: req.pid,
                windowId: req.windowId,
                targetFrame: req.frame,
                currentFrameHint: req.currentFrameHint,
                writeResult: AXFrameWriteResult(
                    targetFrame: req.frame,
                    observedFrame: observedFrame,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: .verificationMismatch
                )
            )
        }
    }

    manager.applyFramesParallel([(pid, windowId, targetFrame)])

    #expect(
        manager.lastAppliedFrame(for: windowId) == observedFrame,
        "verificationMismatch should accept observedFrame"
    )
    #expect(manager.recentFrameWriteFailure(for: windowId) == nil, "acceptance should clear failure state")
}

@Test @MainActor func verificationMismatchDoesNotRetry() {
    let manager = AXManager()
    let pid: pid_t = getpid()
    let windowId = 9901
    let frame = CGRect(x: 100, y: 100, width: 500, height: 400)

    var applyCallCount = 0
    manager.frameApplyOverrideForTests = { requests in
        applyCallCount += 1
        return requests.map { req in
            AXFrameApplyResult(
                requestId: req.requestId,
                pid: req.pid,
                windowId: req.windowId,
                targetFrame: req.frame,
                currentFrameHint: req.currentFrameHint,
                writeResult: AXFrameWriteResult(
                    targetFrame: req.frame,
                    observedFrame: CGRect(x: 100, y: 100, width: 600, height: 400),
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: .verificationMismatch
                )
            )
        }
    }

    manager.applyFramesParallel([(pid, windowId, frame)])
    #expect(applyCallCount == 1, "verificationMismatch should not trigger retry")
    manager.clearForceApplyFlagForTests(for: windowId)
}

@Test @MainActor func verificationMismatchFiresCallbackImmediately() {
    let manager = AXManager()
    let pid: pid_t = getpid()
    let windowId = 9904
    let targetFrame = CGRect(x: 100, y: 100, width: 500, height: 400)
    let observedFrame = CGRect(x: 100, y: 100, width: 600, height: 400)

    var callbackWindowIds: [Int] = []
    var callbackFrames: [CGRect] = []
    manager.onFrameAcceptedAtDifferentSize = { wid, frame in
        callbackWindowIds.append(wid)
        callbackFrames.append(frame)
    }

    manager.frameApplyOverrideForTests = { requests in
        return requests.map { req in
            AXFrameApplyResult(
                requestId: req.requestId,
                pid: req.pid,
                windowId: req.windowId,
                targetFrame: req.frame,
                currentFrameHint: req.currentFrameHint,
                writeResult: AXFrameWriteResult(
                    targetFrame: req.frame,
                    observedFrame: observedFrame,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: .verificationMismatch
                )
            )
        }
    }

    manager.applyFramesParallel([(pid, windowId, targetFrame)])
    #expect(callbackWindowIds == [windowId])
    #expect(callbackFrames.first == observedFrame)
}

@Test @MainActor func verificationMismatchDisabledByFeatureFlag() {
    let manager = AXManager()
    manager.acceptAndAdaptEnabled = false
    let pid: pid_t = getpid()
    let windowId = 9905
    let targetFrame = CGRect(x: 100, y: 100, width: 500, height: 400)
    let observedFrame = CGRect(x: 100, y: 100, width: 600, height: 400)

    var callbackCount = 0
    manager.onFrameAcceptedAtDifferentSize = { _, _ in callbackCount += 1 }

    manager.frameApplyOverrideForTests = { requests in
        return requests.map { req in
            AXFrameApplyResult(
                requestId: req.requestId,
                pid: req.pid,
                windowId: req.windowId,
                targetFrame: req.frame,
                currentFrameHint: req.currentFrameHint,
                writeResult: AXFrameWriteResult(
                    targetFrame: req.frame,
                    observedFrame: observedFrame,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: .verificationMismatch
                )
            )
        }
    }

    manager.applyFramesParallel([(pid, windowId, targetFrame)])
    #expect(manager.lastAppliedFrame(for: windowId) == nil, "acceptance disabled — no lastAppliedFrame")
    #expect(callbackCount == 0, "acceptance disabled — no callback")
}

@Test @MainActor func verificationMismatchIgnoredWhenObservedFrameNil() {
    let manager = AXManager()
    let pid: pid_t = getpid()
    let windowId = 9906
    let targetFrame = CGRect(x: 100, y: 100, width: 500, height: 400)

    var callbackCount = 0
    manager.onFrameAcceptedAtDifferentSize = { _, _ in callbackCount += 1 }

    manager.frameApplyOverrideForTests = { requests in
        return requests.map { req in
            AXFrameApplyResult(
                requestId: req.requestId,
                pid: req.pid,
                windowId: req.windowId,
                targetFrame: req.frame,
                currentFrameHint: req.currentFrameHint,
                writeResult: AXFrameWriteResult(
                    targetFrame: req.frame,
                    observedFrame: nil,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: .verificationMismatch
                )
            )
        }
    }

    manager.applyFramesParallel([(pid, windowId, targetFrame)])
    #expect(manager.lastAppliedFrame(for: windowId) == nil, "nil observedFrame — no acceptance")
    #expect(callbackCount == 0)
}

@Test @MainActor func forceApplyBypassesCooldown() {
    let manager = AXManager()
    let pid: pid_t = getpid()
    let windowId = 9902
    let frame = CGRect(x: 100, y: 100, width: 500, height: 400)

    var applyCount = 0
    manager.frameApplyOverrideForTests = { requests in
        applyCount += requests.count
        return requests.map { req in
            AXFrameApplyResult(
                requestId: req.requestId,
                pid: req.pid,
                windowId: req.windowId,
                targetFrame: req.frame,
                currentFrameHint: req.currentFrameHint,
                writeResult: AXFrameWriteResult(
                    targetFrame: req.frame,
                    observedFrame: CGRect(x: 100, y: 100, width: 600, height: 400),
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: .verificationMismatch
                )
            )
        }
    }

    manager.applyFramesParallel([(pid, windowId, frame)])
    #expect(applyCount == 1)

    applyCount = 0
    manager.forceApplyNextFrame(for: windowId)
    manager.applyFramesParallel([(pid, windowId, frame)])
    #expect(applyCount == 1, "force-apply should bypass any suppression")
}

@Suite(.serialized) struct AXManagerTests {
    @Test func observedTargetFrameConfirmsApplyResultDespiteAttributeWriteFailure() {
        let targetFrame = CGRect(x: 120, y: 90, width: 640, height: 420)
        let result = AXFrameApplyResult(
            pid: 910,
            windowId: 910,
            targetFrame: targetFrame,
            currentFrameHint: nil,
            writeResult: axManagerTestWriteResult(
                targetFrame: targetFrame,
                currentFrameHint: nil,
                observedFrame: targetFrame,
                failureReason: .sizeWriteFailed(.attributeUnsupported)
            )
        )

        #expect(result.confirmedFrame == targetFrame)
    }

    @Test @MainActor func failedWriteRetriesOnceAndPromotesConfirmedFrameAfterSuccess() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager retry test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 910)
        let targetFrame = CGRect(x: 140, y: 88, width: 960, height: 620)

        var attemptCount = 0
        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += 1
            return requests.map { request in
                let writeResult = if attemptCount == 1 {
                    axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: .cacheMiss
                    )
                } else {
                    axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.frame,
                        failureReason: nil
                    )
                }

                return AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: writeResult
                )
            }
        }

        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        let observedTerminalResult = await waitForConditionForTests {
            observerResults.count == 1
        }

        #expect(attemptCount == 2)
        #expect(observedTerminalResult)
        #expect(observerResults.count == 1)
        #expect(observerResults.first?.confirmedFrame == targetFrame)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == targetFrame)
    }

    @Test @MainActor func terminalObserverFiresOnceAfterRetriesExhaustOnFailure() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager terminal failure test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 911)
        let targetFrame = CGRect(x: 200, y: 120, width: 840, height: 540)

        var attemptCount = 0
        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += 1
            return requests.map { request in
                let failureReason: AXFrameWriteFailureReason = if attemptCount == 1 {
                    .cacheMiss
                } else {
                    .verificationMismatch
                }
                return AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: failureReason
                    )
                )
            }
        }

        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        let observedTerminalResult = await waitForConditionForTests {
            observerResults.count == 1
        }

        #expect(observedTerminalResult)
        #expect(attemptCount == 2)
        #expect(observerResults.count == 1)
        #expect(observerResults.first?.writeResult.failureReason == .verificationMismatch)
        // observedFrame is nil (currentFrameHint is nil on retry), so accept-and-adapt skips
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(controller.axManager.recentFrameWriteFailure(for: token.windowId) == .verificationMismatch)
    }

    @Test @MainActor func terminalObserverCompletesImmediatelyWhenTargetFrameAlreadyCached() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager cached-frame observer test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 912)
        let targetFrame = CGRect(x: 160, y: 96, width: 900, height: 580)

        var attemptCount = 0
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += 1
            return requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.frame,
                        failureReason: nil
                    )
                )
            }
        }

        controller.axManager.applyFramesParallel([(token.pid, token.windowId, targetFrame)])

        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        #expect(attemptCount == 1)
        #expect(observerResults.count == 1)
        #expect(observerResults.first?.confirmedFrame == targetFrame)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == targetFrame)
    }

    @Test @MainActor func laterTrackedWriteDoesNotConsumeSupersededObserver() async throws {
        try await withAXFrameProviderIsolationForTests {
            let controller = makeLayoutPlanTestController()
            guard let monitor = controller.workspaceManager.monitors.first,
                  let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
            else {
                Issue.record("Missing monitor or active workspace for AXManager observer scoping test")
                return
            }

            let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 913)
            guard let entry = controller.workspaceManager.entry(for: token),
                  let context = await AppAXContext.makeForTests(processIdentifier: token.pid)
            else {
                Issue.record("Failed to create AX test context for AXManager observer scoping test")
                return
            }

            controller.axManager.frameApplyOverrideForTests = nil
            AppAXContext.contexts[token.pid] = context
            try await context.installWindowsForTests([entry.axRef])

            let firstFrame = CGRect(x: 180, y: 100, width: 880, height: 560)
            let secondFrame = CGRect(x: 260, y: 140, width: 760, height: 500)
            let startedFirstWrite = DispatchSemaphore(value: 0)
            let releaseFirstWrite = DispatchSemaphore(value: 0)
            let startedSecondWrite = DispatchSemaphore(value: 0)
            let releaseSecondWrite = DispatchSemaphore(value: 0)

            AXWindowService.setFrameResultProviderForTests = { _, frame, currentFrameHint in
                if frame == firstFrame {
                    startedFirstWrite.signal()
                    _ = releaseFirstWrite.wait(timeout: .now() + 1)
                } else if frame == secondFrame {
                    startedSecondWrite.signal()
                    _ = releaseSecondWrite.wait(timeout: .now() + 1)
                }

                return axManagerTestWriteResult(
                    targetFrame: frame,
                    currentFrameHint: currentFrameHint,
                    observedFrame: frame,
                    failureReason: nil
                )
            }
            defer {
                AXWindowService.setFrameResultProviderForTests = nil
                AppAXContext.contexts.removeValue(forKey: token.pid)
                context.destroy()
            }

            var firstObserverResults: [AXFrameApplyResult] = []
            var secondObserverResults: [AXFrameApplyResult] = []

            controller.axManager.applyFramesParallel(
                [(token.pid, token.windowId, firstFrame)],
                terminalObserver: { firstObserverResults.append($0) }
            )

            let sawFirstStart = await Task.detached {
                waitForSemaphoreForTests(startedFirstWrite, timeout: .now() + 1) == .success
            }.value
            #expect(sawFirstStart)

            controller.axManager.applyFramesParallel(
                [(token.pid, token.windowId, secondFrame)],
                terminalObserver: { secondObserverResults.append($0) }
            )

            releaseFirstWrite.signal()

            let sawSecondStart = await Task.detached {
                waitForSemaphoreForTests(startedSecondWrite, timeout: .now() + 1) == .success
            }.value
            #expect(sawSecondStart)

            releaseSecondWrite.signal()

            let observedSecondTerminalResult = await waitForConditionForTests {
                secondObserverResults.count == 1
            }

            #expect(observedSecondTerminalResult)
            #expect(firstObserverResults.isEmpty)
            #expect(secondObserverResults.count == 1)
            #expect(secondObserverResults.first?.targetFrame == secondFrame)
            #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == secondFrame)
        }
    }

    @Test @MainActor func removeWindowStateClearsFrameStateAndCancelsPendingObserver() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager removal cleanup test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 914)
        let targetFrame = CGRect(x: 220, y: 140, width: 760, height: 500)

        controller.axManager.frameApplyOverrideForTests = { _ in [] }
        defer { controller.axManager.frameApplyOverrideForTests = nil }

        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )
        controller.axManager.markWindowInactive(token.windowId)
        controller.axManager.forceApplyNextFrame(for: token.windowId)

        let before = controller.axManager.windowStateDebugSnapshot()
        #expect(before.pendingFrameWriteCount == 1)
        #expect(before.retryBudgetCount == 1)
        #expect(before.forceApplyWindowIdCount == 1)
        #expect(before.pendingFrameObserverCount == 1)
        #expect(before.observerRequestIdCount == 1)
        #expect(before.inactiveWorkspaceWindowIdCount == 1)

        controller.axManager.removeWindowState(pid: token.pid, windowId: token.windowId)

        #expect(observerResults.count == 1)
        #expect(observerResults.first?.writeResult.failureReason == .cancelled)

        let after = controller.axManager.windowStateDebugSnapshot()
        #expect(after.lastAppliedFrameCount == 0)
        #expect(after.pendingFrameWriteCount == 0)
        #expect(after.recentFrameWriteFailureCount == 0)
        #expect(after.retryBudgetCount == 0)
        #expect(after.forceApplyWindowIdCount == 0)
        #expect(after.pendingFrameObserverCount == 0)
        #expect(after.observerRequestIdCount == 0)
        #expect(after.rekeyedWindowIdCount == 0)
        #expect(after.inactiveWorkspaceWindowIdCount == 0)
    }

    @Test @MainActor func oldWindowRemovalKeepsRekeyMappingForLateFrameResult() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager rekey cleanup test")
            return
        }

        let oldToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 915)
        let newWindow = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 916)
        let targetFrame = CGRect(x: 240, y: 160, width: 720, height: 480)
        var didRekeyAndRemoveOldState = false

        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                if !didRekeyAndRemoveOldState {
                    didRekeyAndRemoveOldState = true
                    controller.axManager.rekeyWindowState(
                        pid: oldToken.pid,
                        oldWindowId: oldToken.windowId,
                        newWindow: newWindow
                    )
                    controller.axManager.removeWindowState(pid: oldToken.pid, windowId: oldToken.windowId)
                }
                return AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: oldToken.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.frame,
                        failureReason: nil
                    )
                )
            }
        }
        defer { controller.axManager.frameApplyOverrideForTests = nil }

        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.applyFramesParallel(
            [(oldToken.pid, oldToken.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        #expect(didRekeyAndRemoveOldState)
        #expect(observerResults.count == 1)
        #expect(observerResults.first?.windowId == newWindow.windowId)
        #expect(controller.axManager.lastAppliedFrame(for: newWindow.windowId) == targetFrame)
        #expect(controller.axManager.windowStateDebugSnapshot().rekeyedWindowIdCount == 0)
    }

    @Test @MainActor func oldWindowRemovalDropsRekeyMappingWhenOnlyForceApplyMoved() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager force apply rekey test")
            return
        }

        let oldToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 917)
        let newWindow = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 918)

        controller.axManager.forceApplyNextFrame(for: oldToken.windowId)
        controller.axManager.rekeyWindowState(pid: oldToken.pid, oldWindowId: oldToken.windowId, newWindow: newWindow)
        controller.axManager.removeWindowState(pid: oldToken.pid, windowId: oldToken.windowId)

        let snapshot = controller.axManager.windowStateDebugSnapshot()
        #expect(snapshot.rekeyedWindowIdCount == 0)
        #expect(snapshot.forceApplyWindowIdCount == 1)
    }

    // MARK: - Phase 1 Integration: Accept-and-Adapt → Column Width Update

    @Test @MainActor func acceptAndAdaptUpdatesNiriColumnWidth() async {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.niriEngine
        else {
            Issue.record("Missing monitor, workspace, or niri engine")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9930)
        let targetFrame = CGRect(x: 100, y: 100, width: 500, height: 400)
        let observedFrame = CGRect(x: 100, y: 100, width: 700, height: 400)

        // Run initial layout to populate niri engine columns
        let initialPlans = try? await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        if let plans = initialPlans {
            controller.layoutRefreshController.executeLayoutPlans(plans)
        }
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let node = engine.findNode(for: token),
              let column = engine.column(of: node)
        else {
            Issue.record("Window not in niri engine after initial layout")
            return
        }
        let originalWidth = column.cachedWidth

        // Wire callback (simulating ServiceLifecycleManager)
        controller.axManager.onFrameAcceptedAtDifferentSize = { windowId, frame in
            guard let entry = controller.workspaceManager.entry(forWindowId: windowId) else { return }
            let wsId = entry.workspaceId
            let tk = entry.token
            if let n = engine.findNode(for: tk),
               let col = engine.column(of: n)
            {
                col.cachedWidth = frame.width
            }
            controller.layoutRefreshController.markWorkspaceDirty(wsId)
        }

        // Switch to verificationMismatch override
        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { req in
                AXFrameApplyResult(
                    requestId: req.requestId,
                    pid: req.pid,
                    windowId: req.windowId,
                    targetFrame: req.frame,
                    currentFrameHint: req.currentFrameHint,
                    writeResult: AXFrameWriteResult(
                        targetFrame: req.frame,
                        observedFrame: observedFrame,
                        writeOrder: .sizeThenPosition,
                        sizeError: .success,
                        positionError: .success,
                        failureReason: .verificationMismatch
                    )
                )
            }
        }

        // Mismatch: callback fires immediately, column width updates
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, targetFrame)])

        #expect(
            abs(column.cachedWidth - 700) < 0.5,
            "column cachedWidth should be updated to 700, got \(column.cachedWidth)"
        )
        #expect(column.cachedWidth != originalWidth, "column width should have changed from \(originalWidth)")
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == observedFrame)
    }

    // MARK: - .appBusy Backoff Tests

    @Test @MainActor func appBusyGetsThreeRetries() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9920)
        let targetFrame = CGRect(x: 100, y: 100, width: 500, height: 400)

        var attemptCount = 0
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += 1
            return requests.map { req in
                AXFrameApplyResult(
                    requestId: req.requestId,
                    pid: req.pid,
                    windowId: req.windowId,
                    targetFrame: req.frame,
                    currentFrameHint: req.currentFrameHint,
                    writeResult: AXFrameWriteResult(
                        targetFrame: req.frame,
                        observedFrame: nil,
                        writeOrder: .sizeThenPosition,
                        sizeError: .cannotComplete,
                        positionError: .success,
                        failureReason: .appBusy
                    )
                )
            }
        }

        controller.axManager.applyFramesParallel([(token.pid, token.windowId, targetFrame)])

        let allRetriesFired = await waitForConditionForTests { attemptCount >= 4 }
        #expect(allRetriesFired, "appBusy should get initial + 3 retries, got \(attemptCount)")
        #expect(attemptCount == 4)
    }

    @Test @MainActor func appBusyRetriesSucceedOnLaterAttempt() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 9921)
        let targetFrame = CGRect(x: 100, y: 100, width: 500, height: 400)

        var attemptCount = 0
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += 1
            return requests.map { req in
                if attemptCount <= 2 {
                    return AXFrameApplyResult(
                        requestId: req.requestId,
                        pid: req.pid,
                        windowId: req.windowId,
                        targetFrame: req.frame,
                        currentFrameHint: req.currentFrameHint,
                        writeResult: AXFrameWriteResult(
                            targetFrame: req.frame,
                            observedFrame: nil,
                            writeOrder: .sizeThenPosition,
                            sizeError: .cannotComplete,
                            positionError: .success,
                            failureReason: .appBusy
                        )
                    )
                } else {
                    return AXFrameApplyResult(
                        requestId: req.requestId,
                        pid: req.pid,
                        windowId: req.windowId,
                        targetFrame: req.frame,
                        currentFrameHint: req.currentFrameHint,
                        writeResult: axManagerTestWriteResult(
                            targetFrame: req.frame,
                            currentFrameHint: req.currentFrameHint,
                            observedFrame: req.frame,
                            failureReason: nil
                        )
                    )
                }
            }
        }

        controller.axManager.applyFramesParallel([(token.pid, token.windowId, targetFrame)])

        let succeeded = await waitForConditionForTests {
            controller.axManager.lastAppliedFrame(for: token.windowId) != nil
        }
        #expect(succeeded, "appBusy retry should eventually succeed")
        #expect(attemptCount == 3, "2 failures + 1 success = 3 attempts")
        #expect(controller.axManager.recentFrameWriteFailure(for: token.windowId) == nil)
    }
}
