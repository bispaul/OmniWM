import Foundation
import OSLog
import TOML

// Only file in OmniWM that imports TOML — keep this boundary so swift-toml stays swappable.
enum SettingsTOMLCodec {
    private static let logger = Logger(subsystem: "com.omniwm", category: "config")

    static func encode(_ export: SettingsExport) throws -> Data {
        let canonical = CanonicalTOMLConfig(export: export)
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(canonical)
    }

    static func decode(_ data: Data) throws -> SettingsExport {
        do {
            let canonical = try TOMLDecoder().decode(CanonicalTOMLConfig.self, from: data)
            return canonical.toSettingsExport()
        } catch let DecodingError.keyNotFound(key, context) {
            logger.warning(
                "TOML config: unknown key '\(key.stringValue, privacy: .public)' at \(context.codingPath.map(\.stringValue).joined(separator: "."), privacy: .public)"
            )
            let decoder = TOMLDecoder()
            decoder.userInfo[.settingsTOMLRecoverMissingKeys] = true
            let canonical = try decoder.decode(CanonicalTOMLConfig.self, from: data)
            return canonical.toSettingsExport()
        }
    }
}
