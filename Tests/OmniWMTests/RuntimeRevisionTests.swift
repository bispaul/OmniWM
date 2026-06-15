@testable import OmniWM
import Testing

@Suite struct RuntimeRevisionTests {
    @Test func matchingRevisionsReturnTrue() {
        let rev = RuntimeRevision(runtime: 1, workspace: 2, layout: 3, focus: 4, fullscreen: 5)
        #expect(rev.matches(rev, domains: .layoutCommit))
    }

    @Test func mismatchedLayoutReturnsFalse() {
        let rev1 = RuntimeRevision(runtime: 1, workspace: 2, layout: 3, focus: 4, fullscreen: 5)
        let rev2 = RuntimeRevision(runtime: 1, workspace: 2, layout: 99, focus: 4, fullscreen: 5)
        #expect(!rev1.matches(rev2, domains: .layoutCommit))
    }

    @Test func mismatchedFocusIgnoredByLayoutCommit() {
        let rev1 = RuntimeRevision(runtime: 1, workspace: 2, layout: 3, focus: 4, fullscreen: 5)
        let rev2 = RuntimeRevision(runtime: 1, workspace: 2, layout: 3, focus: 99, fullscreen: 5)
        #expect(rev1.matches(rev2, domains: .layoutCommit))
    }

    @Test func focusCommitChecksFocusDomain() {
        let rev1 = RuntimeRevision(runtime: 1, workspace: 2, layout: 3, focus: 4, fullscreen: 5)
        let rev2 = RuntimeRevision(runtime: 1, workspace: 2, layout: 3, focus: 99, fullscreen: 5)
        #expect(!rev1.matches(rev2, domains: .focusCommit))
    }

    @Test @MainActor func applySessionPatchRejectsStaleRevision() {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()

        guard let workspaceId = controller.workspaceManager.monitors.first
            .flatMap({ controller.workspaceManager.activeWorkspaceOrFirst(on: $0.id)?.id })
        else {
            Issue.record("Missing workspace")
            return
        }

        let rev = controller.workspaceManager.runtimeRevision(for: workspaceId)

        controller.workspaceManager.invalidateLayoutRevision(for: [workspaceId])

        let applied = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: ViewportState(),
                runtimeRevision: rev
            )
        )
        #expect(!applied, "Stale patch should be rejected")
    }
}
