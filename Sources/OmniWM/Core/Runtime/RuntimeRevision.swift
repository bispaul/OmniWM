struct RuntimeRevisionDomain: OptionSet {
    let rawValue: UInt8

    static let workspace = RuntimeRevisionDomain(rawValue: 1 << 0)
    static let layout = RuntimeRevisionDomain(rawValue: 1 << 1)
    static let focus = RuntimeRevisionDomain(rawValue: 1 << 2)
    static let fullscreen = RuntimeRevisionDomain(rawValue: 1 << 3)

    static let layoutCommit: RuntimeRevisionDomain = [.workspace, .layout, .fullscreen]
    static let focusCommit: RuntimeRevisionDomain = .focus
}

struct RuntimeRevision: Equatable {
    let runtime: UInt64
    let workspace: UInt64
    let layout: UInt64
    let focus: UInt64
    let fullscreen: UInt64

    func matches(_ other: RuntimeRevision, domains: RuntimeRevisionDomain) -> Bool {
        if domains.contains(.workspace), workspace != other.workspace { return false }
        if domains.contains(.layout), layout != other.layout { return false }
        if domains.contains(.focus), focus != other.focus { return false }
        if domains.contains(.fullscreen), fullscreen != other.fullscreen { return false }
        return true
    }
}
