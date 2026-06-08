import Carbon
import Foundation

struct KeyBinding: Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let usesHyper: Bool

    static let unassigned = KeyBinding(keyCode: UInt32.max, modifiers: 0)
    static let defaultLeader = KeyBinding(keyCode: UInt32(kVK_Space), modifiers: 0, usesHyper: true)

    init(keyCode: UInt32, modifiers: UInt32, usesHyper: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.usesHyper = usesHyper
    }

    var isUnassigned: Bool {
        keyCode == UInt32.max && modifiers == 0 && !usesHyper
    }

    var displayString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.displayString(keyCode: keyCode, modifiers: modifiers, usesHyper: usesHyper)
    }

    var humanReadableString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.humanReadableString(keyCode: keyCode, modifiers: modifiers, usesHyper: usesHyper)
    }

    func conflicts(with other: KeyBinding, hyperTrigger: HyperKeyTrigger) -> Bool {
        guard !isUnassigned, !other.isUnassigned, keyCode == other.keyCode else { return false }
        if modifiers == other.modifiers && usesHyper == other.usesHyper {
            return true
        }
        return carbonCompatibilityBinding(for: hyperTrigger) == other ||
            other.carbonCompatibilityBinding(for: hyperTrigger) == self
    }

    var isBarePrintableRoot: Bool {
        guard modifiers == 0, !usesHyper else { return false }
        return Self.barePrintableRootKeyCodes.contains(keyCode)
    }

    func carbonCompatibilityBinding(for hyperTrigger: HyperKeyTrigger) -> KeyBinding? {
        guard usesHyper, !isUnassigned else { return nil }
        if let modifier = hyperTrigger.carbonCompatibilityModifierMask {
            guard modifiers & modifier == 0 else { return nil }
            return KeyBinding(keyCode: keyCode, modifiers: modifiers | modifier)
        }
        guard hyperTrigger == .system, modifiers == 0 else { return nil }
        return KeyBinding(keyCode: keyCode, modifiers: KeySymbolMapper.hyperModifiers)
    }

    private static let barePrintableRootKeyCodes: Set<UInt32> = [
        UInt32(kVK_ANSI_A), UInt32(kVK_ANSI_B), UInt32(kVK_ANSI_C),
        UInt32(kVK_ANSI_D), UInt32(kVK_ANSI_E), UInt32(kVK_ANSI_F),
        UInt32(kVK_ANSI_G), UInt32(kVK_ANSI_H), UInt32(kVK_ANSI_I),
        UInt32(kVK_ANSI_J), UInt32(kVK_ANSI_K), UInt32(kVK_ANSI_L),
        UInt32(kVK_ANSI_M), UInt32(kVK_ANSI_N), UInt32(kVK_ANSI_O),
        UInt32(kVK_ANSI_P), UInt32(kVK_ANSI_Q), UInt32(kVK_ANSI_R),
        UInt32(kVK_ANSI_S), UInt32(kVK_ANSI_T), UInt32(kVK_ANSI_U),
        UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_W), UInt32(kVK_ANSI_X),
        UInt32(kVK_ANSI_Y), UInt32(kVK_ANSI_Z),
        UInt32(kVK_ANSI_0), UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2),
        UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5),
        UInt32(kVK_ANSI_6), UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8),
        UInt32(kVK_ANSI_9),
        UInt32(kVK_ANSI_Equal), UInt32(kVK_ANSI_Minus),
        UInt32(kVK_ANSI_LeftBracket), UInt32(kVK_ANSI_RightBracket),
        UInt32(kVK_ANSI_Semicolon), UInt32(kVK_ANSI_Quote),
        UInt32(kVK_ANSI_Comma), UInt32(kVK_ANSI_Period),
        UInt32(kVK_ANSI_Slash), UInt32(kVK_ANSI_Backslash),
        UInt32(kVK_ANSI_Grave), UInt32(kVK_Space)
    ]
}

extension KeyBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, usesHyper
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let binding = KeySymbolMapper.fromHumanReadable(string)
        {
            self = binding
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        modifiers = try container.decode(UInt32.self, forKey: .modifiers)
        usesHyper = try container.decodeIfPresent(Bool.self, forKey: .usesHyper) ?? false
    }

    func encode(to encoder: Encoder) throws {
        if isUnassigned || KeySymbolMapper.keyName(keyCode) != "?" {
            var container = encoder.singleValueContainer()
            try container.encode(humanReadableString)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
            if usesHyper {
                try container.encode(usesHyper, forKey: .usesHyper)
            }
        }
    }
}

enum HyperKeyTrigger: Equatable, Hashable {
    case system
    case modifier(UInt32)
    case key(UInt32)
    case mouseButton(Int64)

    static let `default`: HyperKeyTrigger = .modifier(UInt32(optionKey))

    var displayString: String {
        switch self {
        case .system:
            return "⌃⌥⇧⌘"
        case let .modifier(modifier):
            return KeySymbolMapper.modifierSymbols(modifier)
        case let .key(keyCode):
            return KeySymbolMapper.keySymbol(keyCode)
        case let .mouseButton(button):
            return "Mouse \(button)"
        }
    }

    var humanReadableString: String {
        switch self {
        case .system:
            return "Control+Option+Shift+Command"
        case let .modifier(modifier):
            return KeySymbolMapper.modifierNames(modifier)
        case let .key(keyCode):
            return KeySymbolMapper.keyName(keyCode)
        case let .mouseButton(button):
            return "MouseButton\(button)"
        }
    }

    var requiresEventTap: Bool {
        switch self {
        case .system,
             .modifier:
            return false
        case .key,
             .mouseButton:
            return true
        }
    }

    var keyboardKeyCode: UInt32? {
        guard case let .key(keyCode) = self else { return nil }
        return keyCode
    }

    var mouseButtonNumber: Int64? {
        guard case let .mouseButton(button) = self else { return nil }
        return button
    }

    var modifierMaskToExclude: UInt32 {
        switch self {
        case .system,
             .mouseButton:
            return 0
        case let .modifier(modifier):
            return modifier
        case let .key(keyCode):
            return Self.modifierMask(for: keyCode)
        }
    }

    var carbonCompatibilityModifierMask: UInt32? {
        guard case let .modifier(modifier) = self else { return nil }
        return modifier
    }

    func matchesPhysicalKeyCode(_ keyCode: UInt32) -> Bool {
        switch self {
        case .system,
             .mouseButton:
            return false
        case let .key(triggerKeyCode):
            return keyCode == triggerKeyCode
        case let .modifier(modifier):
            return Self.modifierMask(for: keyCode) == modifier
        }
    }

    static func fromHumanReadable(_ string: String) -> HyperKeyTrigger? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.localizedCaseInsensitiveCompare("System Hyper") == .orderedSame ||
            trimmed.localizedCaseInsensitiveCompare("Real Hyper") == .orderedSame ||
            trimmed.localizedCaseInsensitiveCompare("Control+Option+Shift+Command") == .orderedSame
        {
            return .system
        }

        let compactMouse = trimmed.replacingOccurrences(of: " ", with: "")
        if compactMouse.lowercased().hasPrefix("mousebutton"),
           let button = Int64(compactMouse.dropFirst("MouseButton".count)),
           button >= 2
        {
            return .mouseButton(button)
        }

        if let modifier = Self.modifierMask(named: trimmed) {
            return .modifier(modifier)
        }

        if let keyCode = KeySymbolMapper.keyCode(named: trimmed) {
            return .key(keyCode)
        }

        return nil
    }

    static func modifierMask(for keyCode: UInt32) -> UInt32 {
        switch Int(keyCode) {
        case kVK_Shift,
             kVK_RightShift:
            return UInt32(shiftKey)
        case kVK_Control,
             kVK_RightControl:
            return UInt32(controlKey)
        case kVK_Option,
             kVK_RightOption:
            return UInt32(optionKey)
        case kVK_Command,
             kVK_RightCommand:
            return UInt32(cmdKey)
        default:
            return 0
        }
    }

    static func modifierMask(named name: String) -> UInt32? {
        switch name.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "").lowercased() {
        case "shift":
            return UInt32(shiftKey)
        case "control":
            return UInt32(controlKey)
        case "option":
            return UInt32(optionKey)
        case "command":
            return UInt32(cmdKey)
        default:
            return nil
        }
    }
}

extension HyperKeyTrigger: Codable {
    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let trigger = HyperKeyTrigger.fromHumanReadable(string)
        {
            self = trigger
            return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Invalid Hyper key trigger")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(humanReadableString)
    }
}

enum HotkeySequenceStep: Equatable, Hashable {
    case leader
    case chord(KeyBinding)

    var displayString: String {
        switch self {
        case .leader:
            return "Leader"
        case let .chord(binding):
            return binding.displayString
        }
    }

    var humanReadableString: String {
        switch self {
        case .leader:
            return "Leader"
        case let .chord(binding):
            return binding.humanReadableString
        }
    }

    func resolved(leaderKey: KeyBinding) -> KeyBinding? {
        switch self {
        case .leader:
            return leaderKey.isUnassigned ? nil : leaderKey
        case let .chord(binding):
            return binding.isUnassigned ? nil : binding
        }
    }

    static func fromHumanReadable(_ string: String) -> HotkeySequenceStep? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveCompare("Leader") == .orderedSame {
            return .leader
        }
        return KeySymbolMapper.fromHumanReadable(trimmed).map(HotkeySequenceStep.chord)
    }
}

enum HotkeyTrigger: Equatable, Hashable {
    case unassigned
    case chord(KeyBinding)
    case sequence([HotkeySequenceStep])

    var isUnassigned: Bool {
        switch self {
        case .unassigned:
            return true
        case let .chord(binding):
            return binding.isUnassigned
        case let .sequence(steps):
            return steps.isEmpty
        }
    }

    var displayString: String {
        switch self {
        case .unassigned:
            return "Unassigned"
        case let .chord(binding):
            return binding.displayString
        case let .sequence(steps):
            return steps.map(\.displayString).joined(separator: ", ")
        }
    }

    var humanReadableString: String {
        switch self {
        case .unassigned:
            return "Unassigned"
        case let .chord(binding):
            return binding.humanReadableString
        case let .sequence(steps):
            return steps.map(\.humanReadableString).joined(separator: ", ")
        }
    }

    var chordBinding: KeyBinding? {
        guard case let .chord(binding) = self, !binding.isUnassigned else { return nil }
        return binding
    }

    func resolvedSequence(leaderKey: KeyBinding) -> [KeyBinding]? {
        switch self {
        case let .sequence(steps):
            let resolved = steps.compactMap { $0.resolved(leaderKey: leaderKey) }
            return resolved.count == steps.count ? resolved : nil
        case let .chord(binding):
            return binding.isUnassigned ? nil : [binding]
        case .unassigned:
            return nil
        }
    }

    func conflicts(with other: HotkeyTrigger, leaderKey: KeyBinding, hyperTrigger: HyperKeyTrigger) -> Bool {
        guard !isUnassigned, !other.isUnassigned else { return false }
        switch (self, other) {
        case let (.chord(lhs), .chord(rhs)):
            return lhs.conflicts(with: rhs, hyperTrigger: hyperTrigger)
        case (.sequence, .sequence):
            guard let lhs = resolvedSequence(leaderKey: leaderKey),
                  let rhs = other.resolvedSequence(leaderKey: leaderKey)
            else { return false }
            if lhs.conflictMatches(rhs, hyperTrigger: hyperTrigger) ||
                lhs.isConflictPrefix(of: rhs, hyperTrigger: hyperTrigger) ||
                rhs.isConflictPrefix(of: lhs, hyperTrigger: hyperTrigger)
            {
                return true
            }
            guard let lhsRoot = lhs.first, let rhsRoot = rhs.first else { return false }
            return lhsRoot != rhsRoot && lhsRoot.conflicts(with: rhsRoot, hyperTrigger: hyperTrigger)
        case let (.chord(binding), .sequence):
            guard let root = other.resolvedSequence(leaderKey: leaderKey)?.first else { return false }
            return binding.conflicts(with: root, hyperTrigger: hyperTrigger)
        case let (.sequence, .chord(binding)):
            guard let root = resolvedSequence(leaderKey: leaderKey)?.first else { return false }
            return root.conflicts(with: binding, hyperTrigger: hyperTrigger)
        default:
            return false
        }
    }

    static func fromHumanReadable(_ string: String) -> HotkeyTrigger? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "Unassigned" { return .unassigned }
        if let binding = KeySymbolMapper.fromHumanReadable(trimmed) {
            return binding.isUnassigned ? .unassigned : .chord(binding)
        }
        if trimmed.contains(",") {
            let steps = trimmed
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0) }
                .compactMap(HotkeySequenceStep.fromHumanReadable)
            let rawStepCount = trimmed.split(separator: ",", omittingEmptySubsequences: false).count
            guard steps.count == rawStepCount else { return nil }
            return .sequence(steps)
        }
        return nil
    }
}

extension HotkeyTrigger: Codable {
    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let trigger = HotkeyTrigger.fromHumanReadable(string)
        {
            self = trigger
            return
        }
        let binding = try KeyBinding(from: decoder)
        self = binding.isUnassigned ? .unassigned : .chord(binding)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .unassigned,
             .sequence:
            var container = encoder.singleValueContainer()
            try container.encode(humanReadableString)
        case let .chord(binding):
            try binding.encode(to: encoder)
        }
    }
}

private extension Array where Element == KeyBinding {
    func conflictMatches(_ other: [KeyBinding], hyperTrigger: HyperKeyTrigger) -> Bool {
        count == other.count && zip(self, other).allSatisfy { $0.conflicts(with: $1, hyperTrigger: hyperTrigger) }
    }

    func isConflictPrefix(of other: [KeyBinding], hyperTrigger: HyperKeyTrigger) -> Bool {
        count < other.count && zip(self, other).allSatisfy { $0.conflicts(with: $1, hyperTrigger: hyperTrigger) }
    }
}

struct HotkeyBinding: Codable, Equatable, Identifiable {
    let id: String
    let command: HotkeyCommand
    var binding: HotkeyTrigger

    var category: HotkeyCategory {
        ActionCatalog.category(for: id) ?? .focus
    }

    init(id: String, command: HotkeyCommand, binding: KeyBinding) {
        self.init(id: id, command: command, trigger: binding.isUnassigned ? .unassigned : .chord(binding))
    }

    init(id: String, command: HotkeyCommand, trigger: HotkeyTrigger) {
        self.id = id
        self.command = command
        binding = HotkeyBindingRegistry.canonicalizeTrigger(trigger)
    }
}

extension HotkeyBinding {
    private enum CodingKeys: String, CodingKey {
        case id, bindings, binding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let trigger = try container.decodeIfPresent(HotkeyTrigger.self, forKey: .binding)
            ?? HotkeyBindingRegistry.firstTrigger(
                from: try container.decodeIfPresent([KeyBinding].self, forKey: .bindings) ?? []
            )
            ?? .unassigned
        guard let command = HotkeyBindingRegistry.command(for: id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Unknown hotkey binding id: \(id)"
            )
        }
        self = HotkeyBinding(id: id, command: command, trigger: trigger)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(binding, forKey: .binding)
    }
}

struct PersistedHotkeyBinding: Codable, Equatable {
    let id: String
    let binding: HotkeyTrigger

    private enum CodingKeys: String, CodingKey {
        case id, bindings, binding
    }

    init(id: String, binding: KeyBinding) {
        self.init(id: id, trigger: binding.isUnassigned ? .unassigned : .chord(binding))
    }

    init(id: String, trigger: HotkeyTrigger) {
        self.id = id
        binding = HotkeyBindingRegistry.canonicalizeTrigger(trigger)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        binding = try container.decodeIfPresent(HotkeyTrigger.self, forKey: .binding)
            ?? HotkeyBindingRegistry.firstTrigger(
                from: try container.decodeIfPresent([KeyBinding].self, forKey: .bindings) ?? []
            )
            ?? .unassigned
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(binding, forKey: .binding)
    }
}

enum HotkeyBindingRegistry {
    private static let commandPaletteID = "openCommandPalette"
    private static let legacyCommandPaletteIDs = (
        windowFinder: "openWindowFinder",
        menuPalette: "openMenuPalette"
    )
    private static let defaultBindings = DefaultHotkeyBindings.all()
    private static let bindingsByID = Dictionary(
        defaultBindings.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static func defaults() -> [HotkeyBinding] {
        defaultBindings
    }

    static func command(for id: String) -> HotkeyCommand? {
        bindingsByID[id]?.command
    }

    static func makeBinding(id: String, binding: KeyBinding) -> HotkeyBinding? {
        guard let defaultBinding = bindingsByID[id] else { return nil }
        return HotkeyBinding(id: id, command: defaultBinding.command, binding: binding)
    }

    static func makeBinding(id: String, trigger: HotkeyTrigger) -> HotkeyBinding? {
        guard let defaultBinding = bindingsByID[id] else { return nil }
        return HotkeyBinding(id: id, command: defaultBinding.command, trigger: trigger)
    }

    static func canonicalize(_ persisted: [PersistedHotkeyBinding]) -> [HotkeyBinding] {
        var overrides: [String: HotkeyTrigger] = [:]
        var explicitOverrideIDs: Set<String> = []
        var commandPaletteOverridePresent = false
        var legacyWindowFinderBinding: HotkeyTrigger?
        var legacyMenuPaletteBinding: HotkeyTrigger?

        for entry in persisted {
            let normalizedBinding = canonicalizeTrigger(entry.binding)
            if isLegacyWorkspaceDefault(id: entry.id, trigger: normalizedBinding) {
                continue
            }

            switch entry.id {
            case commandPaletteID:
                commandPaletteOverridePresent = true
                explicitOverrideIDs.insert(commandPaletteID)
                overrides[commandPaletteID] = normalizedBinding
            case legacyCommandPaletteIDs.windowFinder:
                legacyWindowFinderBinding = normalizedBinding.isUnassigned ? nil : normalizedBinding
            case legacyCommandPaletteIDs.menuPalette:
                legacyMenuPaletteBinding = normalizedBinding.isUnassigned ? nil : normalizedBinding
            default:
                guard bindingsByID[entry.id] != nil else { continue }
                explicitOverrideIDs.insert(entry.id)
                overrides[entry.id] = normalizedBinding
            }
        }

        if !commandPaletteOverridePresent, let legacyBinding = legacyWindowFinderBinding ?? legacyMenuPaletteBinding {
            explicitOverrideIDs.insert(commandPaletteID)
            overrides[commandPaletteID] = legacyBinding
        }

        return defaultBindings.map { binding in
            guard explicitOverrideIDs.contains(binding.id) else { return binding }
            let override = overrides[binding.id] ?? .unassigned
            return HotkeyBinding(id: binding.id, command: binding.command, trigger: override)
        }
    }

    static func migrateLegacyDefaultWorkspaceBindings(_ bindings: [HotkeyBinding]) -> [HotkeyBinding] {
        bindings.map { binding in
            guard isLegacyWorkspaceDefault(id: binding.id, trigger: binding.binding),
                  let defaultBinding = bindingsByID[binding.id]
            else { return binding }
            return defaultBinding
        }
    }

    static func canonicalizeBinding(_ binding: KeyBinding) -> KeyBinding {
        binding.isUnassigned ? .unassigned : binding
    }

    static func canonicalizeTrigger(_ trigger: HotkeyTrigger) -> HotkeyTrigger {
        switch trigger {
        case .unassigned:
            return .unassigned
        case let .chord(binding):
            return binding.isUnassigned ? .unassigned : .chord(binding)
        case let .sequence(steps):
            return steps.isEmpty ? .unassigned : .sequence(steps)
        }
    }

    static func firstTrigger(from bindings: [KeyBinding]) -> HotkeyTrigger? {
        bindings.first { !$0.isUnassigned }.map(HotkeyTrigger.chord)
    }

    private static func isLegacyWorkspaceDefault(id: String, trigger: HotkeyTrigger) -> Bool {
        guard case let .chord(binding) = trigger else { return false }
        let digitCodes = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
        ]
        for (workspace, keyCode) in digitCodes.enumerated() {
            if id == "switchWorkspace.\(workspace)" {
                return binding == KeyBinding(keyCode: keyCode, modifiers: UInt32(optionKey))
            }
            if id == "moveToWorkspace.\(workspace)" {
                return binding == KeyBinding(keyCode: keyCode, modifiers: UInt32(optionKey | shiftKey))
            }
        }
        return false
    }

    static func decodePersistedBindings(from data: Data) -> [HotkeyBinding]? {
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }

        let decoder = JSONDecoder()
        var persisted: [PersistedHotkeyBinding] = []
        for rawEntry in rawArray {
            guard JSONSerialization.isValidJSONObject(rawEntry),
                  let entryData = try? JSONSerialization.data(withJSONObject: rawEntry),
                  let entry = try? decoder.decode(PersistedHotkeyBinding.self, from: entryData)
            else {
                continue
            }
            persisted.append(entry)
        }

        return canonicalize(persisted)
    }

    static func canonicalizedJSONArray(from rawArray: Any) -> Any {
        guard let entries = rawArray as? [Any] else {
            return encodedJSONArray(for: defaultBindings)
        }

        let decoder = JSONDecoder()
        var persisted: [PersistedHotkeyBinding] = []
        for rawEntry in entries {
            guard JSONSerialization.isValidJSONObject(rawEntry),
                  let entryData = try? JSONSerialization.data(withJSONObject: rawEntry),
                  let entry = try? decoder.decode(PersistedHotkeyBinding.self, from: entryData)
            else {
                continue
            }
            persisted.append(entry)
        }

        return encodedJSONArray(for: canonicalize(persisted))
    }

    private static func encodedJSONArray(for bindings: [HotkeyBinding]) -> Any {
        guard let data = try? JSONEncoder().encode(bindings),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return []
        }
        return json
    }
}

enum HotkeyCategory: String, CaseIterable {
    case workspace = "Workspace"
    case focus = "Focus"
    case move = "Move Window"
    case monitor = "Monitor"
    case layout = "Layout"
    case column = "Column"
}

private extension Array where Element: Equatable {
    func isStrictPrefix(of other: [Element]) -> Bool {
        count < other.count && zip(self, other).allSatisfy { $0 == $1 }
    }
}
