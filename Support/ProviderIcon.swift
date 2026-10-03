import AppKit
import Foundation

/// Provider logos bundled in Resources/icons. Falls back to SF Symbols
/// styling when a logo is missing.
enum ProviderIcon {
    static func image(for agentID: String, darkBackground: Bool) -> NSImage? {
        let name: String
        switch agentID {
        case "claude": name = "claude-ai-logo"
        // "-dark" is the white logo, for dark backgrounds.
        case "codex": name = darkBackground ? "openai-com-logo-dark" : "openai-com-logo"
        case "opencode": name = "opencode-ai-logo"
        default: return nil
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "icons")
            ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Resources/icons")
        else { return nil }
        return NSImage(contentsOf: url)
    }
}
