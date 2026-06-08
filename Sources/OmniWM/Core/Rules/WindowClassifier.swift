import Foundation

@MainActor
enum WindowClassifier {
    enum PreFilterResult {
        case admit
        case reject(reason: String)
    }

    static func preFilter(
        windowId: Int,
        pid: pid_t,
        windowInfo: WindowServerInfo?,
        bundleId: String?
    ) -> PreFilterResult {
        guard let bundleId else { return .admit }
        guard chromiumBundleIds.contains(bundleId) else { return .admit }
        guard let info = windowInfo else { return .admit }
        if info.title == nil || info.title?.isEmpty == true {
            return .reject(reason: "chromium-internal-no-title")
        }
        return .admit
    }

    static let chromiumBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]
}
