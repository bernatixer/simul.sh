import AppKit
import SwiftUI

/// Chat uses GitHub light colours with a grey sidebar; terminals keep Ghostty's palette.
@MainActor
enum Theme {
    static var background: Color { adaptive(light: rgb(0xFFFFFF), dark: GhosttyRuntime.shared.backgroundColor) }

    /// A touch lighter than the terminal.
    static var sidebar: Color {
        let base = GhosttyRuntime.shared.backgroundColor
        return adaptive(light: rgb(0xEFEFEF), dark: base.blended(withFraction: 0.035, of: .white) ?? base)
    }

    static var divider: Color { adaptive(light: rgb(0xD0D7DE), dark: NSColor.labelColor.withAlphaComponent(0.08)) }
    static let chatBackground = Color(nsColor: rgb(0xFFFFFF))
    static let chatHover = Color(nsColor: rgb(0xE5E5E5))
    static let chatSelection = Color(nsColor: rgb(0xD8D8D8))
    static let chatAccent = Color(nsColor: rgb(0x1F2328))
    static let chatTrack = Color(nsColor: rgb(0xD0D7DE))
    static let chatBorder = Color(nsColor: rgb(0xD0D7DE))
    static let chatPrompt = Color(nsColor: rgb(0xF6F8FA))
    static var primaryText: Color { Color(nsColor: primaryLabel) }
    static var primaryLabel: NSColor { adaptiveColor(light: rgb(0x1F2328), dark: .labelColor) }
    static func providerTint(_ id: String, light: Bool) -> Color {
        light && id == "claude" ? Color(white: 0.78) : .white
    }
    static var secondaryText: Color { Color(nsColor: secondaryLabel) }
    static var mutedText: Color { Color(nsColor: mutedLabel) }
    static var secondaryLabel: NSColor {
        adaptiveColor(light: rgb(0x656D76), dark: .secondaryLabelColor)
    }
    static var mutedLabel: NSColor {
        adaptiveColor(light: rgb(0x8C959F), dark: .secondaryLabelColor)
    }
    static var warningText: Color {
        adaptive(light: NSColor(srgbRed: 138 / 255, green: 75 / 255, blue: 5 / 255, alpha: 1), dark: .systemOrange)
    }
    static var errorText: Color {
        adaptive(light: NSColor(srgbRed: 180 / 255, green: 35 / 255, blue: 24 / 255, alpha: 1), dark: .systemRed)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: adaptiveColor(light: light, dark: dark))
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? light : dark
        }
    }
}
