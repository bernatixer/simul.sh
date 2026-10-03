import AppKit
import SwiftUI

/// Window palette derived from the terminal's own background, so the
/// sidebar, title area and terminal are shades of one color instead of
/// four unrelated greys.
@MainActor
enum Theme {
    static var background: Color { Color(nsColor: GhosttyRuntime.shared.backgroundColor) }

    /// A touch lighter than the terminal.
    static var sidebar: Color {
        let base = GhosttyRuntime.shared.backgroundColor
        return Color(nsColor: base.blended(withFraction: 0.035, of: .white) ?? base)
    }

    static let divider = Color.white.opacity(0.06)
}
