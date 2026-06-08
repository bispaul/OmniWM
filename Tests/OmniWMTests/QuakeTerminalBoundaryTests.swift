import AppKit
import Foundation
@testable import OmniWM
import Testing

@Suite struct GhosttySurfaceSizingTests {
    @Test func normalizesFinitePointSizeWithCeilingRounding() throws {
        let metrics = try #require(GhosttySurfaceCellMetrics(cellWidthPx: 10, cellHeightPx: 20))
        let pixelSize = GhosttySurfacePixelSizeNormalizer.normalize(
            pointSize: CGSize(width: 320.2, height: 100.1),
            backingScale: 2,
            cellMetrics: metrics
        )

        #expect(pixelSize == GhosttySurfacePixelSize(widthPx: 641, heightPx: 201))
    }

    @Test func keepsSubpixelPositiveSizesAtOnePixel() {
        let pixelSize = GhosttySurfacePixelSizeNormalizer.normalize(
            pointSize: CGSize(width: 0.1, height: 0.2),
            backingScale: 2,
            cellMetrics: nil
        )

        #expect(pixelSize == GhosttySurfacePixelSize(widthPx: 1, heightPx: 1))
    }

    @Test func rejectsInvalidPointSizesAndBackingScales() {
        let invalidSizes = [
            CGSize(width: 0, height: 20),
            CGSize(width: -1, height: 20),
            CGSize(width: CGFloat.nan, height: 20),
            CGSize(width: 20, height: CGFloat.infinity)
        ]

        for size in invalidSizes {
            let pixelSize = GhosttySurfacePixelSizeNormalizer.normalize(
                pointSize: size,
                backingScale: 1,
                cellMetrics: nil
            )
            #expect(pixelSize == nil)
        }

        for scale in [CGFloat(0), CGFloat(-1), CGFloat.nan, CGFloat.infinity] {
            let pixelSize = GhosttySurfacePixelSizeNormalizer.normalize(
                pointSize: CGSize(width: 20, height: 20),
                backingScale: scale,
                cellMetrics: nil
            )
            #expect(pixelSize == nil)
        }
    }

    @Test func clampsToGhosttyGridLimitUsingCellMetrics() throws {
        let metrics = try #require(GhosttySurfaceCellMetrics(cellWidthPx: 8, cellHeightPx: 16))
        let pixelSize = GhosttySurfacePixelSizeNormalizer.normalize(
            pointSize: CGSize(width: 1_000_000, height: 2_000_000),
            backingScale: 1,
            cellMetrics: metrics
        )

        #expect(pixelSize == GhosttySurfacePixelSize(widthPx: 524_280, heightPx: 1_048_560))
    }

    @Test func clampsFinitePixelProductsAboveUInt32Max() throws {
        let metrics = try #require(GhosttySurfaceCellMetrics(cellWidthPx: 100_000, cellHeightPx: 100_000))
        let pixelSize = GhosttySurfacePixelSizeNormalizer.normalize(
            pointSize: CGSize(width: Double(UInt32.max) + 10, height: Double(UInt32.max) + 20),
            backingScale: 2,
            cellMetrics: metrics
        )

        #expect(pixelSize == GhosttySurfacePixelSize(widthPx: UInt32.max, heightPx: UInt32.max))
    }

    @Test func fallsBackToOnePixelCellsWhenMetricsAreUnavailable() {
        let pixelSize = GhosttySurfacePixelSizeNormalizer.normalize(
            pointSize: CGSize(width: 100_000, height: 100_000),
            backingScale: 1,
            cellMetrics: GhosttySurfaceCellMetrics(cellWidthPx: 0, cellHeightPx: 0)
        )

        #expect(pixelSize == GhosttySurfacePixelSize(widthPx: 65_535, heightPx: 65_535))
    }
}

@Suite struct QuakeTerminalGeometryPolicyTests {
    @Test func normalizesQuakePercentagesToSupportedBounds() {
        #expect(QuakeTerminalGeometryPolicy.normalizedDimensionPercent(5) == 10)
        #expect(QuakeTerminalGeometryPolicy.normalizedDimensionPercent(150) == 100)
        #expect(QuakeTerminalGeometryPolicy.normalizedDimensionPercent(Double.nan) == 50)
        #expect(QuakeTerminalGeometryPolicy.normalizedDimensionPercent(Double.infinity) == 50)
    }

    @Test func rejectsImpossibleCustomFrames() {
        let valid = CGRect(x: 10, y: 20, width: 600, height: 300)

        #expect(QuakeTerminalGeometryPolicy.normalizedCustomFrame(valid) == valid)
        #expect(QuakeTerminalGeometryPolicy.normalizedCustomFrame(
            CGRect(x: 0, y: 0, width: 199, height: 300)
        ) == nil)
        #expect(QuakeTerminalGeometryPolicy.normalizedCustomFrame(
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 300)
        ) == nil)
        #expect(QuakeTerminalGeometryPolicy.normalizedCustomFrame(
            CGRect(x: 0, y: 0, width: 1_000_000, height: 300)
        ) == nil)
    }
}

@Suite @MainActor struct QuakeTerminalFocusedWindowResolverTests {
    @Test func focusedWindowFallbackConvertsWindowServerBoundsBeforeResolvingMonitor() {
        let primary = Monitor(
            id: Monitor.ID(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            hasNotch: false,
            name: "Primary"
        )
        let secondary = Monitor(
            id: Monitor.ID(displayId: 2),
            displayId: 2,
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
            hasNotch: false,
            name: "Secondary"
        )
        let windowList: [[String: Any]] = [
            [
                kCGWindowOwnerPID as String: Int32(99),
                kCGWindowLayer as String: 0,
                kCGWindowBounds as String: [
                    "X": 1200,
                    "Y": 100,
                    "Width": 400,
                    "Height": 300
                ]
            ]
        ]

        let displayId = QuakeTerminalController.focusedWindowDisplayId(
            monitors: [primary, secondary],
            windowList: windowList,
            ownPID: 42,
            toAppKitRect: { rect in
                CGRect(x: rect.minX, y: 200, width: rect.width, height: rect.height)
            }
        )

        #expect(displayId == secondary.displayId)
    }

    @Test func focusedWindowFallbackSkipsOwnProcessAndSmallWindows() {
        let monitor = Monitor(
            id: Monitor.ID(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            hasNotch: false,
            name: "Display"
        )
        let windowList: [[String: Any]] = [
            [
                kCGWindowOwnerPID as String: Int32(42),
                kCGWindowLayer as String: 0,
                kCGWindowBounds as String: [
                    "X": 100,
                    "Y": 100,
                    "Width": 500,
                    "Height": 300
                ]
            ],
            [
                kCGWindowOwnerPID as String: Int32(99),
                kCGWindowLayer as String: 0,
                kCGWindowBounds as String: [
                    "X": 100,
                    "Y": 100,
                    "Width": 40,
                    "Height": 300
                ]
            ]
        ]

        let displayId = QuakeTerminalController.focusedWindowDisplayId(
            monitors: [monitor],
            windowList: windowList,
            ownPID: 42,
            toAppKitRect: { $0 }
        )

        #expect(displayId == nil)
    }

    @Test func focusedWindowFallbackRejectsOutOfRangeNumericFields() {
        let monitor = Monitor(
            id: Monitor.ID(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            hasNotch: false,
            name: "Display"
        )
        let windowList: [[String: Any]] = [
            [
                kCGWindowOwnerPID as String: NSNumber(value: Int64(Int32.max) + 1),
                kCGWindowLayer as String: 0,
                kCGWindowBounds as String: [
                    "X": 100,
                    "Y": 100,
                    "Width": 500,
                    "Height": 300
                ]
            ],
            [
                kCGWindowOwnerPID as String: Int32(99),
                kCGWindowLayer as String: NSNumber(value: Int64(UInt32.max) + 1),
                kCGWindowBounds as String: [
                    "X": 100,
                    "Y": 100,
                    "Width": 500,
                    "Height": 300
                ]
            ]
        ]

        let displayId = QuakeTerminalController.focusedWindowDisplayId(
            monitors: [monitor],
            windowList: windowList,
            ownPID: 42,
            toAppKitRect: { $0 }
        )

        #expect(displayId == nil)
    }

    @Test func focusedWindowFallbackRejectsNonFiniteBounds() {
        let monitor = Monitor(
            id: Monitor.ID(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            hasNotch: false,
            name: "Display"
        )
        let windowList: [[String: Any]] = [
            [
                kCGWindowOwnerPID as String: Int32(99),
                kCGWindowLayer as String: 0,
                kCGWindowBounds as String: [
                    "X": 100,
                    "Y": 100,
                    "Width": NSNumber(value: Double.infinity),
                    "Height": 300
                ]
            ]
        ]

        let displayId = QuakeTerminalController.focusedWindowDisplayId(
            monitors: [monitor],
            windowList: windowList,
            ownPID: 42,
            toAppKitRect: { $0 }
        )

        #expect(displayId == nil)
    }
}
