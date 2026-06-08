import Carbon
@testable import OmniWM
import Testing

@Suite struct ActionCatalogTests {
    @Test func defaultBindingsMirrorActionCatalog() {
        let specs = ActionCatalog.allSpecs()
        let bindings = HotkeyBindingRegistry.defaults()

        #expect(bindings.map(\.id) == specs.map(\.id))
        #expect(bindings.count == specs.count)
    }

    @Test func workspaceSwitchDefaultsUseSemanticHyper() throws {
        let switchWorkspace = try #require(
            HotkeyBindingRegistry.defaults().first { $0.id == "switchWorkspace.1" }
        )
        let moveToWorkspace = try #require(
            HotkeyBindingRegistry.defaults().first { $0.id == "moveToWorkspace.1" }
        )

        #expect(
            switchWorkspace.binding == .chord(KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: 0, usesHyper: true))
        )
        #expect(
            moveToWorkspace.binding == .chord(
                KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(shiftKey), usesHyper: true)
            )
        )
    }

    @Test func hotkeyVisibilitySeparatesNormalAdvancedAndHiddenActions() throws {
        let normal = try #require(ActionCatalog.spec(for: "move.left"))
        let advanced = try #require(ActionCatalog.spec(for: "moveWindowDownOrToWorkspaceDown"))
        let hidden = try #require(ActionCatalog.spec(for: "consumeOrExpelWindowLeft"))

        #expect(normal.visibility == .normal)
        #expect(advanced.visibility == .advanced)
        #expect(hidden.visibility == .hidden)
        #expect(ActionCatalog.visibility(for: "moveWindowUp") == .hidden)
        #expect(ActionCatalog.visibility(for: "focusWindowInColumn.1") == .advanced)
        #expect(ActionCatalog.visibility(for: "resizeGrow.left") == .advanced)
        #expect(ActionCatalog.visibility(for: "centerColumn") == .advanced)
    }

    @Test func previousWorkspaceActionsHaveDistinctDisplayNames() throws {
        let previous = try #require(ActionCatalog.spec(for: "switchWorkspace.previous"))
        let lastActive = try #require(ActionCatalog.spec(for: "workspaceBackAndForth"))

        #expect(previous.title == "Switch to Previous Workspace")
        #expect(lastActive.title == "Switch to Last Active Workspace")
        #expect(previous.title != lastActive.title)
    }

    @Test func searchMatchesKeywordsAndIpcMetadata() throws {
        let binding = try #require(
            HotkeyBindingRegistry.defaults().first { $0.id == "toggleWorkspaceBarVisibility" }
        )

        #expect(ActionCatalog.matchesSearch("workspace bar", binding: binding))
        #expect(ActionCatalog.matchesSearch("toggle-workspace-bar", binding: binding))
    }

    @Test func vimNavigationPresetKeepsExpectedSequenceSurface() {
        let mappings = HotkeyPreset.vimNavigation()

        #expect(mappings.map { "\($0.id)=\($0.trigger.humanReadableString)" } == [
            "focus.left=Leader, H",
            "move.left=Leader, Shift+H",
            "focus.down=Leader, J",
            "move.down=Leader, Shift+J",
            "focus.up=Leader, K",
            "move.up=Leader, Shift+K",
            "focus.right=Leader, L",
            "move.right=Leader, Shift+L",
            "switchWorkspace.0=Leader, 1",
            "moveToWorkspace.0=Leader, Shift+1",
            "switchWorkspace.1=Leader, 2",
            "moveToWorkspace.1=Leader, Shift+2",
            "switchWorkspace.2=Leader, 3",
            "moveToWorkspace.2=Leader, Shift+3",
            "switchWorkspace.3=Leader, 4",
            "moveToWorkspace.3=Leader, Shift+4",
            "switchWorkspace.4=Leader, 5",
            "moveToWorkspace.4=Leader, Shift+5",
            "switchWorkspace.5=Leader, 6",
            "moveToWorkspace.5=Leader, Shift+6",
            "switchWorkspace.6=Leader, 7",
            "moveToWorkspace.6=Leader, Shift+7",
            "switchWorkspace.7=Leader, 8",
            "moveToWorkspace.7=Leader, Shift+8",
            "switchWorkspace.8=Leader, 9",
            "moveToWorkspace.8=Leader, Shift+9",
            "focusPrevious=Leader, Tab"
        ])
    }

    @Test func actionSpecCarriesPublicCommandDescriptor() throws {
        let spec = try #require(ActionCatalog.spec(for: "toggleWorkspaceBarVisibility"))

        #expect(spec.ipcCommandName == .toggleWorkspaceBar)
        #expect(spec.ipcDescriptor?.path == "command toggle-workspace-bar")
    }

    @Test func niriParameterizedResizeActionsUsePublicCommandDescriptors() throws {
        let spec = try #require(ActionCatalog.spec(for: "setColumnWidth.increase10Percent"))

        #expect(spec.ipcCommandName == .setColumnWidth)
        #expect(spec.ipcDescriptor?.path == "command set-column-width <size-change>")
    }

    @Test func niriWindowFocusActionsUsePublicCommandDescriptors() throws {
        let indexed = try #require(ActionCatalog.spec(for: "focusWindowInColumn.1"))
        let top = try #require(ActionCatalog.spec(for: "focusWindowTop"))
        let fallback = try #require(ActionCatalog.spec(for: "focusWindowOrWorkspaceDown"))

        #expect(indexed.ipcCommandName == .focusWindowInColumn)
        #expect(indexed.ipcDescriptor?.path == "command focus-window-in-column <number>")
        #expect(top.ipcCommandName == .focusWindowTop)
        #expect(top.ipcDescriptor?.path == "command focus-window top")
        #expect(fallback.ipcCommandName == .focusWindowOrWorkspaceDown)
        #expect(fallback.ipcDescriptor?.path == "command focus-window-or-workspace-down")
    }

    @Test func niriColumnMoveActionsUsePublicCommandDescriptors() throws {
        let first = try #require(ActionCatalog.spec(for: "moveColumnToFirst"))
        let indexed = try #require(ActionCatalog.spec(for: "moveColumnToIndex.1"))

        #expect(first.ipcCommandName == .moveColumnToFirst)
        #expect(first.ipcDescriptor?.path == "command move-column-to-first")
        #expect(indexed.ipcCommandName == .moveColumnToIndex)
        #expect(indexed.ipcDescriptor?.path == "command move-column-to-index <number>")
    }

    @Test func niriViewportActionsUsePublicCommandDescriptors() throws {
        let center = try #require(ActionCatalog.spec(for: "centerColumn"))
        let visible = try #require(ActionCatalog.spec(for: "centerVisibleColumns"))

        #expect(center.ipcCommandName == .centerColumn)
        #expect(center.ipcDescriptor?.path == "command center-column")
        #expect(visible.ipcCommandName == .centerVisibleColumns)
        #expect(visible.ipcDescriptor?.path == "command center-visible-columns")
    }

    @Test func niriWindowMoveActionsUsePublicCommandDescriptors() throws {
        let down = try #require(ActionCatalog.spec(for: "moveWindowDown"))
        let fallback = try #require(ActionCatalog.spec(for: "moveWindowDownOrToWorkspaceDown"))
        let consume = try #require(ActionCatalog.spec(for: "consumeWindowIntoColumn"))
        let expel = try #require(ActionCatalog.spec(for: "expelWindowFromColumn"))

        #expect(down.ipcCommandName == .moveWindowDown)
        #expect(down.ipcDescriptor?.path == "command move-window-down")
        #expect(fallback.ipcCommandName == .moveWindowDownOrToWorkspaceDown)
        #expect(fallback.ipcDescriptor?.path == "command move-window-down-or-to-workspace-down")
        #expect(consume.ipcCommandName == .consumeWindowIntoColumn)
        #expect(consume.ipcDescriptor?.path == "command consume-window-into-column")
        #expect(expel.ipcCommandName == .expelWindowFromColumn)
        #expect(expel.ipcDescriptor?.path == "command expel-window-from-column")
    }
}
