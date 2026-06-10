import CoreGraphics
import Foundation
@testable import OmniWM
import Testing

private func makeRestorePlannerMetadata(
    bundleId: String? = "com.example.editor",
    workspaceId: WorkspaceDescriptor.ID = WorkspaceDescriptor.ID(),
    mode: TrackedWindowMode = .tiling,
    title: String? = "Document",
    frame: CGRect? = nil
) -> ManagedReplacementMetadata {
    ManagedReplacementMetadata(
        bundleId: bundleId,
        workspaceId: workspaceId,
        mode: mode,
        role: "AXWindow",
        subrole: "AXStandardWindow",
        title: title,
        windowLevel: 0,
        parentWindowId: nil,
        frame: frame
    )
}

private func makeRestorePlannerCatalogEntry(
    token: WindowToken,
    metadata: ManagedReplacementMetadata,
    workspaceName: String,
    monitor: Monitor,
    includeIdentity: Bool = true,
    floatingFrame: CGRect? = CGRect(x: 120, y: 140, width: 900, height: 600),
    restoreToFloating: Bool = true
) -> PersistedWindowRestoreEntry {
    PersistedWindowRestoreEntry(
        key: PersistedWindowRestoreKey(metadata: metadata)!,
        identity: includeIdentity ? PersistedWindowRestoreIdentity(token: token, metadata: metadata) : nil,
        restoreIntent: PersistedRestoreIntent(
            workspaceName: workspaceName,
            topologyProfile: TopologyProfile(monitors: [monitor]),
            preferredMonitor: DisplayFingerprint(monitor: monitor),
            floatingFrame: floatingFrame,
            normalizedFloatingOrigin: CGPoint(x: 0.1, y: 0.2),
            restoreToFloating: restoreToFloating,
            rescueEligible: true
        )
    )
}

struct RestorePlannerTests {
    @Test func hardIdentityHydrationWinsWhenSemanticKeyIsDuplicated() throws {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 700, name: "Main")
        let originalWorkspaceId = WorkspaceDescriptor.ID()
        let restoredWorkspaceId = WorkspaceDescriptor.ID()
        let metadata = makeRestorePlannerMetadata(workspaceId: originalWorkspaceId, title: "Shared")
        let firstToken = WindowToken(pid: 701, windowId: 11)
        let secondToken = WindowToken(pid: 702, windowId: 22)
        let firstEntry = makeRestorePlannerCatalogEntry(
            token: firstToken,
            metadata: metadata,
            workspaceName: "1",
            monitor: monitor
        )
        let secondEntry = makeRestorePlannerCatalogEntry(
            token: secondToken,
            metadata: metadata,
            workspaceName: "2",
            monitor: monitor
        )

        let plan = try #require(
            planner.planPersistedHydration(
                .init(
                    token: secondToken,
                    metadata: metadata,
                    catalog: PersistedWindowRestoreCatalog(entries: [firstEntry, secondEntry]),
                    consumedEntries: [],
                    monitors: [monitor],
                    workspaceIdForName: { name in
                        ["1": originalWorkspaceId, "2": restoredWorkspaceId][name]
                    }
                )
            )
        )

        #expect(plan.persistedEntry == secondEntry)
        #expect(plan.workspaceId == restoredWorkspaceId)
        #expect(plan.consumedEntry == PersistedWindowRestoreConsumptionKey(entry: secondEntry))
    }

    @Test func semanticHydrationReturnsNilWhenFallbackIsAmbiguous() {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 701, name: "Main")
        let workspaceId = WorkspaceDescriptor.ID()
        let metadata = makeRestorePlannerMetadata(workspaceId: workspaceId, title: "Shared")
        let firstEntry = makeRestorePlannerCatalogEntry(
            token: WindowToken(pid: 711, windowId: 11),
            metadata: metadata,
            workspaceName: "1",
            monitor: monitor,
            includeIdentity: false
        )
        let secondEntry = makeRestorePlannerCatalogEntry(
            token: WindowToken(pid: 712, windowId: 22),
            metadata: metadata,
            workspaceName: "1",
            monitor: monitor,
            includeIdentity: false
        )

        let plan = planner.planPersistedHydration(
            .init(
                token: WindowToken(pid: 713, windowId: 33),
                metadata: metadata,
                catalog: PersistedWindowRestoreCatalog(entries: [firstEntry, secondEntry]),
                consumedEntries: [],
                monitors: [monitor],
                workspaceIdForName: { _ in workspaceId }
            )
        )

        #expect(plan == nil)
    }

    @Test func consumedPersistedEntryBlocksReuseWithoutBlockingSameKeyIdentityMatch() throws {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 702, name: "Main")
        let workspaceId = WorkspaceDescriptor.ID()
        let metadata = makeRestorePlannerMetadata(workspaceId: workspaceId, title: "Shared")
        let firstToken = WindowToken(pid: 721, windowId: 11)
        let secondToken = WindowToken(pid: 722, windowId: 22)
        let firstEntry = makeRestorePlannerCatalogEntry(
            token: firstToken,
            metadata: metadata,
            workspaceName: "1",
            monitor: monitor
        )
        let secondEntry = makeRestorePlannerCatalogEntry(
            token: secondToken,
            metadata: metadata,
            workspaceName: "1",
            monitor: monitor
        )

        let reusedPlan = planner.planPersistedHydration(
            .init(
                token: firstToken,
                metadata: metadata,
                catalog: PersistedWindowRestoreCatalog(entries: [firstEntry, secondEntry]),
                consumedEntries: [PersistedWindowRestoreConsumptionKey(entry: firstEntry)],
                monitors: [monitor],
                workspaceIdForName: { _ in workspaceId }
            )
        )
        let secondPlan = try #require(
            planner.planPersistedHydration(
                .init(
                    token: secondToken,
                    metadata: metadata,
                    catalog: PersistedWindowRestoreCatalog(entries: [firstEntry, secondEntry]),
                    consumedEntries: [PersistedWindowRestoreConsumptionKey(entry: firstEntry)],
                    monitors: [monitor],
                    workspaceIdForName: { _ in workspaceId }
                )
            )
        )

        #expect(reusedPlan == nil)
        #expect(secondPlan.persistedEntry == secondEntry)
    }

    @Test func persistedHydrationReturnsNilWhenWorkspaceNameIsMissing() {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 703, name: "Main")
        let workspaceId = WorkspaceDescriptor.ID()
        let metadata = makeRestorePlannerMetadata(workspaceId: workspaceId, title: "Missing Workspace")
        let token = WindowToken(pid: 731, windowId: 31)
        let entry = makeRestorePlannerCatalogEntry(
            token: token,
            metadata: metadata,
            workspaceName: "2",
            monitor: monitor
        )

        let plan = planner.planPersistedHydration(
            .init(
                token: token,
                metadata: metadata,
                catalog: PersistedWindowRestoreCatalog(entries: [entry]),
                consumedEntries: [],
                monitors: [monitor],
                workspaceIdForName: { _ in nil }
            )
        )

        #expect(plan == nil)
    }

    @Test func softMatchSucceedsWhenMetadataHasRoleAndSubrole() throws {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 704, name: "Main")
        let savedWorkspaceId = WorkspaceDescriptor.ID()
        let catalogMetadata = makeRestorePlannerMetadata(
            bundleId: "com.mitchellh.ghostty",
            workspaceId: savedWorkspaceId,
            title: "~"
        )
        let catalogToken = WindowToken(pid: 100, windowId: 1)
        let entry = makeRestorePlannerCatalogEntry(
            token: catalogToken,
            metadata: catalogMetadata,
            workspaceName: "1",
            monitor: monitor
        )

        let admissionToken = WindowToken(pid: 200, windowId: 2)
        let admissionMetadata = makeRestorePlannerMetadata(
            bundleId: "com.mitchellh.ghostty",
            workspaceId: WorkspaceDescriptor.ID(),
            title: "~"
        )

        let plan = try #require(
            planner.planPersistedHydration(
                .init(
                    token: admissionToken,
                    metadata: admissionMetadata,
                    catalog: PersistedWindowRestoreCatalog(entries: [entry]),
                    consumedEntries: [],
                    monitors: [monitor],
                    workspaceIdForName: { name in
                        ["1": savedWorkspaceId][name]
                    }
                )
            )
        )

        #expect(plan.workspaceId == savedWorkspaceId)
    }

    @Test func softMatchFailsWhenMetadataHasNilRoleAndSubrole() {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 705, name: "Main")
        let workspaceId = WorkspaceDescriptor.ID()
        let catalogMetadata = makeRestorePlannerMetadata(
            bundleId: "com.mitchellh.ghostty",
            workspaceId: workspaceId,
            title: "~"
        )
        let catalogToken = WindowToken(pid: 101, windowId: 1)
        let entry = makeRestorePlannerCatalogEntry(
            token: catalogToken,
            metadata: catalogMetadata,
            workspaceName: "1",
            monitor: monitor
        )

        let admissionToken = WindowToken(pid: 201, windowId: 2)
        let admissionMetadata = ManagedReplacementMetadata(
            bundleId: "com.mitchellh.ghostty",
            workspaceId: WorkspaceDescriptor.ID(),
            mode: .tiling,
            role: nil,
            subrole: nil,
            title: nil,
            windowLevel: nil,
            parentWindowId: nil,
            frame: nil
        )

        let plan = planner.planPersistedHydration(
            .init(
                token: admissionToken,
                metadata: admissionMetadata,
                catalog: PersistedWindowRestoreCatalog(entries: [entry]),
                consumedEntries: [],
                monitors: [monitor],
                workspaceIdForName: { _ in workspaceId }
            )
        )

        #expect(plan == nil)
    }

    @Test func multiWindowTitleDisambiguationMatchesUniquelyByTitle() throws {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 706, name: "Main")
        let ws1Id = WorkspaceDescriptor.ID()
        let ws2Id = WorkspaceDescriptor.ID()

        let gmailMetadata = makeRestorePlannerMetadata(
            bundleId: "com.google.chrome",
            workspaceId: ws1Id,
            title: "Gmail"
        )
        let githubMetadata = makeRestorePlannerMetadata(
            bundleId: "com.google.chrome",
            workspaceId: ws2Id,
            title: "GitHub"
        )
        let gmailEntry = makeRestorePlannerCatalogEntry(
            token: WindowToken(pid: 102, windowId: 1),
            metadata: gmailMetadata,
            workspaceName: "1",
            monitor: monitor
        )
        let githubEntry = makeRestorePlannerCatalogEntry(
            token: WindowToken(pid: 102, windowId: 2),
            metadata: githubMetadata,
            workspaceName: "2",
            monitor: monitor
        )

        let admissionToken = WindowToken(pid: 300, windowId: 3)
        let admissionMetadata = makeRestorePlannerMetadata(
            bundleId: "com.google.chrome",
            workspaceId: WorkspaceDescriptor.ID(),
            title: "GitHub"
        )

        let plan = try #require(
            planner.planPersistedHydration(
                .init(
                    token: admissionToken,
                    metadata: admissionMetadata,
                    catalog: PersistedWindowRestoreCatalog(entries: [gmailEntry, githubEntry]),
                    consumedEntries: [],
                    monitors: [monitor],
                    workspaceIdForName: { name in
                        ["1": ws1Id, "2": ws2Id][name]
                    }
                )
            )
        )

        #expect(plan.workspaceId == ws2Id)
    }

    @Test func identicalTitlesCauseAmbiguousRejection() {
        let planner = RestorePlanner()
        let monitor = makeLayoutPlanTestMonitor(displayId: 707, name: "Main")
        let ws1Id = WorkspaceDescriptor.ID()
        let ws2Id = WorkspaceDescriptor.ID()

        let metadata1 = makeRestorePlannerMetadata(
            bundleId: "com.google.chrome",
            workspaceId: ws1Id,
            title: "New Tab"
        )
        let metadata2 = makeRestorePlannerMetadata(
            bundleId: "com.google.chrome",
            workspaceId: ws2Id,
            title: "New Tab"
        )
        let entry1 = makeRestorePlannerCatalogEntry(
            token: WindowToken(pid: 103, windowId: 1),
            metadata: metadata1,
            workspaceName: "1",
            monitor: monitor
        )
        let entry2 = makeRestorePlannerCatalogEntry(
            token: WindowToken(pid: 103, windowId: 2),
            metadata: metadata2,
            workspaceName: "2",
            monitor: monitor
        )

        let admissionToken = WindowToken(pid: 400, windowId: 3)
        let admissionMetadata = makeRestorePlannerMetadata(
            bundleId: "com.google.chrome",
            workspaceId: WorkspaceDescriptor.ID(),
            title: "New Tab"
        )

        let plan = planner.planPersistedHydration(
            .init(
                token: admissionToken,
                metadata: admissionMetadata,
                catalog: PersistedWindowRestoreCatalog(entries: [entry1, entry2]),
                consumedEntries: [],
                monitors: [monitor],
                workspaceIdForName: { name in
                    ["1": ws1Id, "2": ws2Id][name]
                }
            )
        )

        #expect(plan == nil)
    }
}
