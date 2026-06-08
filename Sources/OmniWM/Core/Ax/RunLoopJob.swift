import Foundation
import os
import Synchronization

final class RunLoopJob: Sendable {
    private let _cancelled = Atomic<Bool>(false)
    private let _action = OSAllocatedUnfairLock<RunLoopAction?>(initialState: nil)
    var action: RunLoopAction? {
        get { _action.withLock { $0 } }
        set { _action.withLock { $0 = newValue } }
    }

    var isCancelled: Bool {
        _cancelled.load(ordering: .acquiring)
    }

    func cancel() {
        let (exchanged, _) = _cancelled.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        )
        if exchanged {
            action?.clearAction()
            action = nil
        }
    }

    func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}
