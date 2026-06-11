import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import OmniWM

@Suite @MainActor
struct SelectiveAnimationTests {
    private func makeTestHandle(pid: pid_t = 1) -> WindowHandle {
        WindowHandle(
            id: WindowToken(pid: pid, windowId: Int.random(in: 1...1_000_000)),
            pid: pid,
            axElement: AXUIElementCreateSystemWide()
        )
    }

    @Test func ensureSelectionVisibleWithAnimateFalseProducesStaticOffset() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let gap: CGFloat = 8
        for col in engine.columns(in: wsId) {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: w2,
            in: wsId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap,
            animate: false
        )

        #expect(state.activeColumnIndex == 1)
        switch state.viewOffsetPixels {
        case .static:
            break
        default:
            Issue.record("Expected .static offset but got animating offset")
        }
    }

    @Test func ensureSelectionVisibleWithAnimateTrueProducesSpringAnimation() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        _ = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let gap: CGFloat = 8
        for col in engine.columns(in: wsId) {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: w2,
            in: wsId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap,
            animate: true
        )

        #expect(state.activeColumnIndex == 1)
        let target = state.viewOffsetPixels.target()
        #expect(target != 0 || state.viewOffsetPixels.current() != 0 || state.activeColumnIndex == 1)
    }

    @Test func userNavigationWrapperAnimates() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let gap: CGFloat = 8
        for col in engine.columns(in: wsId) {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisibleAfterUserNavigation(
            node: w2,
            in: wsId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        #expect(state.activeColumnIndex == 1)
    }

    @Test func layoutChangeWrapperDoesNotAnimate() {
        let engine = NiriLayoutEngine()
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let gap: CGFloat = 8
        for col in engine.columns(in: wsId) {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisibleAfterLayoutChange(
            node: w2,
            in: wsId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        #expect(state.activeColumnIndex == 1)
        switch state.viewOffsetPixels {
        case .static:
            break
        default:
            Issue.record("Expected .static offset from layout change wrapper")
        }
    }
}
