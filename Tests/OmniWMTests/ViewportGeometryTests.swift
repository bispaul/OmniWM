import Foundation
@testable import OmniWM
import QuartzCore
import Testing

private func makeViewportGestureContainers(
    widths: [CGFloat],
    modes: [SizingMode]? = nil
) -> [NiriContainer] {
    widths.enumerated().map { index, width in
        let container = NiriContainer()
        container.cachedWidth = width
        container.cachedHeight = width
        let window = NiriWindow(token: makeTestHandle(pid: pid_t(10_000 + index)).id)
        if let modes, modes.indices.contains(index) {
            window.sizingMode = modes[index]
        }
        container.appendChild(window)
        return container
    }
}

@Suite struct ViewportGeometryTests {
    @Test func visibleOffsetUsesModeAwareAreasForNormalMaximizedAndFullscreen() {
        let state = ViewportState()
        let workingArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let parentArea = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let gap: CGFloat = 10

        let normal = makeViewportGestureContainers(widths: [600], modes: [.normal])
        let maximized = makeViewportGestureContainers(widths: [600], modes: [.maximized])
        let fullscreen = makeViewportGestureContainers(widths: [600], modes: [.fullscreen])

        let normalOffset = state.computeVisibleOffset(
            containerIndex: 0,
            containers: normal,
            gap: gap,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .never,
            workingArea: workingArea,
            viewFrame: parentArea
        )
        let maximizedOffset = state.computeVisibleOffset(
            containerIndex: 0,
            containers: maximized,
            gap: gap,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .never,
            workingArea: workingArea,
            viewFrame: parentArea
        )
        let fullscreenOffset = state.computeVisibleOffset(
            containerIndex: 0,
            containers: fullscreen,
            gap: gap,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 700,
            centerMode: .never,
            workingArea: workingArea,
            viewFrame: parentArea
        )

        #expect(abs(normalOffset + gap) < 0.001)
        #expect(abs(maximizedOffset) < 0.001)
        #expect(abs(fullscreenOffset) < 0.001)
    }

    @Test func centeredOffsetUsesModeAwareAreaAndFullscreenAnchor() {
        let state = ViewportState()
        let workingArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let parentArea = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let gap: CGFloat = 10

        let normal = makeViewportGestureContainers(widths: [600], modes: [.normal])
        let maximized = makeViewportGestureContainers(widths: [600], modes: [.maximized])
        let fullscreen = makeViewportGestureContainers(widths: [600], modes: [.fullscreen])

        let normalOffset = state.computeCenteredOffset(
            containerIndex: 0,
            containers: normal,
            gap: gap,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: parentArea
        )
        let maximizedOffset = state.computeCenteredOffset(
            containerIndex: 0,
            containers: maximized,
            gap: gap,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: parentArea
        )
        let fullscreenOffset = state.computeCenteredOffset(
            containerIndex: 0,
            containers: fullscreen,
            gap: gap,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: parentArea
        )

        #expect(abs(normalOffset + 200) < 0.001)
        #expect(abs(maximizedOffset + 300) < 0.001)
        #expect(abs(fullscreenOffset) < 0.001)
    }

    @Test func centeredOffsetUsesWorkingAreaRelativeCoordinatesForInsetDock() {
        let state = ViewportState()
        let workingArea = CGRect(x: 100, y: 0, width: 1_000, height: 800)
        let parentArea = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let gap: CGFloat = 10

        let normal = makeViewportGestureContainers(widths: [600], modes: [.normal])
        let maximized = makeViewportGestureContainers(widths: [600], modes: [.maximized])

        let normalOffset = state.computeCenteredOffset(
            containerIndex: 0,
            containers: normal,
            gap: gap,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: parentArea
        )
        let maximizedOffset = state.computeCenteredOffset(
            containerIndex: 0,
            containers: maximized,
            gap: gap,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: parentArea
        )

        #expect(abs(normalOffset + 200) < 0.001)
        #expect(abs(maximizedOffset + 200) < 0.001)
    }

    @Test func fullWidthNormalColumnDoesNotInheritLeftDockInset() {
        let state = ViewportState()
        let workingArea = CGRect(x: 100, y: 0, width: 1_000, height: 800)
        let parentArea = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let normal = makeViewportGestureContainers(widths: [1_000], modes: [.normal])

        let offset = state.computeCenteredOffset(
            containerIndex: 0,
            containers: normal,
            gap: 10,
            viewportSpan: workingArea.width,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: parentArea
        )

        #expect(abs(offset) < 0.001)
    }

    @Test func updateGestureDoesNotClampOrAdvanceSelectionDuringSwipe() {
        var state = ViewportState()
        state.activeColumnIndex = 1
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)

        let steps = state.updateGesture(
            deltaPixels: 10_000,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 1200
        )

        #expect(steps == nil)
        #expect(state.selectionProgress == 0)

        guard let gesture = state.viewOffsetPixels.gestureRef else {
            Issue.record("Expected active gesture state")
            return
        }

        #expect(abs(gesture.currentViewOffset - 10_000) < 0.001)
    }

    @Test func updateGestureDoesNotClampGenericNonTrackpadGesture() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 10_000,
            timestamp: 1.0,
            isTrackpad: false,
            columns: columns,
            gap: 10,
            viewportWidth: 200
        )

        guard let gesture = state.viewOffsetPixels.gestureRef else {
            Issue.record("Expected active gesture state")
            return
        }

        #expect(abs(gesture.currentViewOffset - 10_000) < 0.001)
    }

    @Test func endGestureUsesNiriLargeColumnCorrection() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99

        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 1_000,
            timestamp: 1.0,
            isTrackpad: false,
            columns: columns,
            gap: 10,
            viewportWidth: 200
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 200,
            motion: .disabled,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 1)
        #expect(abs(Double(state.viewOffsetPixels.target())) < 0.001)
        #expect(state.viewOffsetToRestore == nil)
    }

    @Test func endGesturePreservesRestoreOffsetWhenColumnDoesNotChange() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 200,
            motion: .disabled,
            isTrackpad: false,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 0)
        #expect(state.viewOffsetToRestore == 99)
    }

    @Test func endGestureCanPreserveTrackpadOffsetWithoutSnapping() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 240,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 0)
        #expect(state.viewOffsetPixels.isGesture == false)
        #expect(state.viewOffsetPixels.isAnimating == false)
        #expect(abs(Double(state.viewOffsetPixels.target()) - 100) < 0.001)
        #expect(state.viewOffsetToRestore == 99)

        _ = state.beginGesture(isTrackpad: true, columns: columns)
        _ = state.updateGesture(
            deltaPixels: 120,
            timestamp: 2.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false,
            centerMode: .never
        )

        #expect(abs(Double(state.viewOffsetPixels.target()) - 150) < 0.001)
    }

    @Test func slowTrackpadGestureSnapsBackToCurrentColumn() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])

        _ = state.beginGesture(isTrackpad: true, columns: columns)
        _ = state.updateGesture(
            deltaPixels: 20,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )
        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .disabled,
            isTrackpad: true,
            centerMode: .never,
            timestamp: 1.5
        )

        #expect(state.activeColumnIndex == 0)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) + 10) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 10) < 0.001)
    }

    @Test func fastTrackpadGestureUsesProjectedMomentumForSnapTarget() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])

        _ = state.beginGesture(isTrackpad: true, columns: columns)
        _ = state.updateGesture(
            deltaPixels: 200,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )
        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .disabled,
            isTrackpad: true,
            centerMode: .never,
            timestamp: 1.016
        )

        #expect(state.activeColumnIndex == 2)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 430) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 190) < 0.001)
    }

    @Test func trackpadMomentumSnapAtStripEndNeverWrapsToFront() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300, 300, 300, 300])

        _ = state.beginGesture(isTrackpad: true, columns: columns)
        _ = state.updateGesture(
            deltaPixels: 2_000,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )
        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .disabled,
            isTrackpad: true,
            centerMode: .never,
            timestamp: 1.016
        )

        #expect(state.activeColumnIndex == 4)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 1_050) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 190) < 0.001)
    }

    @Test func preservedTrackpadOffsetKeepsHalfVisibleActiveColumn() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)
        state.viewOffsetPixels.gestureRef?.applyDelta(120)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 0)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 120) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) - 120) < 0.001)
        #expect(state.viewOffsetToRestore == 99)
    }

    @Test func preservedTrackpadOffsetRebasesToMostVisibleColumnWithoutMovingView() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)
        state.viewOffsetPixels.gestureRef?.applyDelta(220)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 1)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 220) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 90) < 0.001)
        #expect(state.viewOffsetToRestore == nil)
    }

    @Test func preservedTrackpadOffsetClampsAtStripEndWithoutWrappingToFront() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300, 300, 300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)
        state.viewOffsetPixels.gestureRef?.applyDelta(10_000)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 4)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 1_040) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 200) < 0.001)
    }

    @Test func endGesturePreservingTrackpadOffsetClampsPastContentBounds() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 10_000,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 200
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 200,
            motion: .disabled,
            isTrackpad: true,
            snapToColumn: false,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 1)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 410) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) - 100) < 0.001)
    }

    @Test func gestureIgnoresMismatchedInputSource() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 500,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 200
        )

        guard let gesture = state.viewOffsetPixels.gestureRef else {
            Issue.record("Expected gesture to remain active after mismatched update")
            return
        }
        #expect(gesture.currentViewOffset == 0)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 200,
            motion: .disabled,
            isTrackpad: true,
            centerMode: .never
        )

        #expect(state.viewOffsetPixels.isGesture)
    }

    @Test func endGestureUsesParentFrameRightStrutForSnapTarget() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [900, 900])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 2_000,
            timestamp: 1.0,
            isTrackpad: false,
            columns: columns,
            gap: 10,
            viewportWidth: 1_000
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 1_000,
            motion: .disabled,
            isTrackpad: false,
            centerMode: .never,
            workingArea: CGRect(x: 100, y: 0, width: 1_000, height: 800),
            viewFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )

        #expect(state.activeColumnIndex == 1)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 90) < 0.001)
    }

    @Test func updateGestureReturnsNilForZeroWidthSingleColumn() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [0])
        _ = state.beginGesture(isTrackpad: true, columns: columns)

        let steps = state.updateGesture(
            deltaPixels: 120,
            timestamp: 1.0,
            columns: columns,
            gap: 8,
            viewportWidth: 1_200
        )

        #expect(steps == nil)
        #expect(state.selectionProgress == 0)

        guard let gesture = state.viewOffsetPixels.gestureRef else {
            Issue.record("Expected gesture state to remain active for zero-width regression test")
            return
        }

        #expect(gesture.currentViewOffset.isFinite)
    }

    @Test func endGestureRetainsStableOffsetForInvalidGeometry() {
        struct Scenario {
            let label: String
            let columns: [NiriContainer]
        }

        let scenarios: [Scenario] = [
            .init(label: "empty columns", columns: []),
            .init(label: "zero-width column", columns: makeViewportGestureContainers(widths: [0]))
        ]

        for scenario in scenarios {
            var state = ViewportState()
            state.activeColumnIndex = 2
            state.viewOffsetPixels = .static(-32)
            state.selectionProgress = 17
            state.viewOffsetToRestore = 99
            state.activatePrevColumnOnRemoval = 42

            guard state.beginGesture(isTrackpad: false, columns: scenario.columns) else {
                #expect(scenario.columns.isEmpty, Comment(rawValue: scenario.label))
                #expect(state.viewOffsetPixels.isGesture == false, Comment(rawValue: scenario.label))
                continue
            }

            guard let gesture = state.viewOffsetPixels.gestureRef else {
                Issue.record("Expected gesture state for \(scenario.label)")
                continue
            }

            gesture.currentViewOffset = -123.5

            state.endGesture(
                columns: scenario.columns,
                gap: 8,
                viewportWidth: 1_200,
                motion: .enabled,
                centerMode: .onOverflow
            )

            #expect(state.activeColumnIndex == 2, Comment(rawValue: scenario.label))
            #expect(state.viewOffsetPixels.isGesture == false, Comment(rawValue: scenario.label))
            #expect(state.viewOffsetPixels.isAnimating == false, Comment(rawValue: scenario.label))
            #expect(abs(Double(state.viewOffsetPixels.target()) + 123.5) < 0.001, Comment(rawValue: scenario.label))
            #expect(state.selectionProgress == 0, Comment(rawValue: scenario.label))
            #expect(state.viewOffsetToRestore == nil, Comment(rawValue: scenario.label))
            #expect(state.activatePrevColumnOnRemoval == nil, Comment(rawValue: scenario.label))
        }
    }

    // MARK: - Overspread

    @Test func overspreadCentersColumnsWhenTotalWidthLessThanViewport() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300])
        let gap: CGFloat = 8
        let viewportWidth: CGFloat = 1_000

        // totalWidth = 300 + 8 + 300 = 608
        // excessSpace = 1000 - 608 = 392
        // targetOffset = -(392 / 2) = -196
        state.applyOverspread(
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth,
            animate: false
        )

        #expect(abs(Double(state.viewOffsetPixels.target()) + 196) < 0.001)
    }

    @Test func overspreadNoOpWhenTotalWidthExceedsViewport() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [500, 500, 500])
        let gap: CGFloat = 8
        let viewportWidth: CGFloat = 1_000

        // totalWidth = 500 + 8 + 500 + 8 + 500 = 1516 > 1000
        let result = state.applyOverspread(
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth,
            animate: false
        )

        #expect(result == false)
        #expect(abs(Double(state.viewOffsetPixels.target())) < 0.001)
    }

    @Test func overspreadReturnsTrueWhenColumnsCenter() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300])
        let gap: CGFloat = 8
        let viewportWidth: CGFloat = 1_000

        let result = state.applyOverspread(
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth,
            animate: false
        )

        #expect(result == true)
    }

    @Test func overspreadCentersWhenColumnsBarelyExceedViewportWithinGapTolerance() {
        var state = ViewportState()
        // 2 columns of 861 + 8 gap = 1730, viewport = 1728, excess = 2px (< gap)
        let columns = makeViewportGestureContainers(widths: [861, 861])
        let gap: CGFloat = 8
        let viewportWidth: CGFloat = 1_728

        // totalWidth = 861 + 8 + 861 = 1730
        // 1730 <= 1728 + 8 = 1736 → tolerance passes
        // excessSpace = 1728 - 1730 = -2
        // targetOffset = -(-2/2) = 1
        let result = state.applyOverspread(
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth,
            animate: false
        )

        #expect(result == true)
        #expect(abs(Double(state.viewOffsetPixels.target()) - 1) < 0.001)

        switch state.viewOffsetPixels {
        case .static:
            break
        default:
            Issue.record("Expected .static offset from non-animated overspread")
        }
    }

    @Test func overspreadReturnsFalseWhenColumnsExceedToleranceBoundary() {
        var state = ViewportState()
        // 3 columns of 600 + 2*8 gap = 1816, viewport = 1728
        // 1816 > 1728 + 8 = 1736 → tolerance fails
        let columns = makeViewportGestureContainers(widths: [600, 600, 600])
        let gap: CGFloat = 8
        let viewportWidth: CGFloat = 1_728

        let result = state.applyOverspread(
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth,
            animate: false
        )

        #expect(result == false)
        #expect(abs(Double(state.viewOffsetPixels.target())) < 0.001)
    }

    // MARK: - Viewport Clamping Tests

    @Test func clampViewportOffsetClampsOverscrolledOffset() {
        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(100) // past maxOffset=0
        let columns = makeViewportGestureContainers(widths: [1277, 1277, 1277])
        let result = state.clampViewportOffset(
            containers: columns, gap: 2, viewportSpan: 2560, sizeKeyPath: \.cachedWidth
        )
        #expect(result == true)
        #expect(state.stationary() == 0, "Should clamp to maxOffset=0")
    }

    @Test func clampViewportOffsetClampsUnderscrolledOffset() {
        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(-1500) // past minOffset
        let columns = makeViewportGestureContainers(widths: [1277, 1277, 1277])
        let result = state.clampViewportOffset(
            containers: columns, gap: 2, viewportSpan: 2560, sizeKeyPath: \.cachedWidth
        )
        #expect(result == true)
        let expected: CGFloat = 2560 - (1277 * 3 + 2 * 2) // -1275
        #expect(abs(state.stationary() - expected) < 1, "Should clamp to minOffset")
    }

    @Test func clampViewportOffsetSkipsWhenColumnsFit() {
        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)
        let columns = makeViewportGestureContainers(widths: [1277, 1277])
        let result = state.clampViewportOffset(
            containers: columns, gap: 2, viewportSpan: 2560, sizeKeyPath: \.cachedWidth
        )
        #expect(result == false, "Should skip when columns fit (minOffset >= maxOffset)")
    }

    @Test func clampViewportOffsetSkipsDuringAnimation() {
        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .spring(
            SpringAnimation(from: 100, to: 0, startTime: CACurrentMediaTime(), config: .default)
        )
        let columns = makeViewportGestureContainers(widths: [1277, 1277, 1277])
        let result = state.clampViewportOffset(
            containers: columns, gap: 2, viewportSpan: 2560, sizeKeyPath: \.cachedWidth
        )
        #expect(result == false, "Should skip during spring animation")
    }

    @Test func clampViewportOffsetSkipsEmptyWorkspace() {
        var state = ViewportState()
        state.viewOffsetPixels = .static(100)
        let result = state.clampViewportOffset(
            containers: [], gap: 2, viewportSpan: 2560, sizeKeyPath: \.cachedWidth
        )
        #expect(result == false, "Should skip for empty workspace")
    }

    @Test func clampViewportOffsetExactFitBoundary() {
        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)
        let columns = makeViewportGestureContainers(widths: [1278, 1278])
        let result = state.clampViewportOffset(
            containers: columns, gap: 2, viewportSpan: 2558, // 1278+2+1278 = 2558
            sizeKeyPath: \.cachedWidth
        )
        #expect(result == false, "Should skip when totalW == viewportSpan exactly")
    }

    @Test func clampViewportOffsetFloatPrecisionSafety() {
        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)
        let columns = makeViewportGestureContainers(widths: [1278.0005, 1278.0005])
        let result = state.clampViewportOffset(
            containers: columns, gap: 2, viewportSpan: 2558, sizeKeyPath: \.cachedWidth
        )
        #expect(result == false, "Sub-pixel difference should be within epsilon")
    }

    @Test func clampViewportOffsetRespectsPixelEpsilon() {
        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0.3) // 0.3px past maxOffset=0
        let columns = makeViewportGestureContainers(widths: [1277, 1277, 1277])
        let result = state.clampViewportOffset(
            containers: columns, gap: 2, viewportSpan: 2560, sizeKeyPath: \.cachedWidth, scale: 2.0
        )
        #expect(result == false, "0.3px within 0.5px epsilon → no clamp")
    }
}
