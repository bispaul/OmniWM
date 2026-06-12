import Foundation
@testable import OmniWM
import Testing

@Suite @MainActor struct MoveColumnToWorkspaceTests {
    @Test func adjustActiveColumnIndexShiftsWhenRemovedBeforeActive() {
        var state = ViewportState()
        state.activeColumnIndex = 2
        NiriLayoutEngine.adjustActiveColumnIndex(&state, afterRemovalAt: 1, newColumnCount: 3)
        #expect(state.activeColumnIndex == 1, "Should shift left when column removed before active")
    }

    @Test func adjustActiveColumnIndexUnchangedWhenRemovedAfterActive() {
        var state = ViewportState()
        state.activeColumnIndex = 0
        NiriLayoutEngine.adjustActiveColumnIndex(&state, afterRemovalAt: 2, newColumnCount: 3)
        #expect(state.activeColumnIndex == 0, "Should stay when column removed after active")
    }

    @Test func adjustActiveColumnIndexClampsWhenActiveExceedsCount() {
        var state = ViewportState()
        state.activeColumnIndex = 3
        NiriLayoutEngine.adjustActiveColumnIndex(&state, afterRemovalAt: 3, newColumnCount: 3)
        #expect(state.activeColumnIndex == 2, "Should clamp to newCount - 1")
    }

    @Test func adjustActiveColumnIndexZeroWhenAllColumnsRemoved() {
        var state = ViewportState()
        state.activeColumnIndex = 2
        NiriLayoutEngine.adjustActiveColumnIndex(&state, afterRemovalAt: 0, newColumnCount: 0)
        #expect(state.activeColumnIndex == 0, "Should be 0 when no columns remain")
    }
}
