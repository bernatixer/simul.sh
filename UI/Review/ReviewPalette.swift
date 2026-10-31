import AppKit
import SwiftUI

/// The review's colours: dark (the terminal's background, as the rest of the
/// app) or light (GitHub's). It follows the review's colour scheme, which the
/// header's sun/moon switch sets, so views read `@Environment(\.reviewPalette)`.
struct ReviewPalette: Equatable, Sendable {
    var light = false

    /// Syntax colours; nil keeps the text colour (plain variables, punctuation).
    /// Dark ones are muted for the dark diff backgrounds; light ones are GitHub's
    /// "prettylights" (Primer light), as github.com's diff draws them.
    func token(_ kind: TokenKind) -> Color? {
        switch kind {
        case .keyword: light ? Self.hex(0xCF222E) : Color(red: 0.78, green: 0.57, blue: 0.80)
        case .string: light ? Self.hex(0x0A3069) : Color(red: 0.62, green: 0.78, blue: 0.55)
        case .comment: light ? Self.hex(0x59636E) : Color(red: 0.50, green: 0.54, blue: 0.59)
        case .number, .constant: light ? Self.hex(0x0550AE) : Color(red: 0.85, green: 0.66, blue: 0.47)
        case .function: light ? Self.hex(0x6639BA) : Color(red: 0.51, green: 0.67, blue: 0.91)
        case .type: light ? Self.hex(0x953800) : Color(red: 0.86, green: 0.76, blue: 0.51)
        case .property: light ? Self.hex(0x0550AE) : Color(red: 0.56, green: 0.77, blue: 0.82)
        case .operator: light ? Self.hex(0xCF222E) : Color(red: 0.67, green: 0.71, blue: 0.77)
        case .variable, .punctuation: nil
        }
    }

    static func hex(_ rgb: UInt32) -> Color {
        Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

/// Light values are GitHub's Primer (light) tokens, as github.com's "Files changed" uses them.
@MainActor extension ReviewPalette {
    /// Behind the cards, the header and the footer (bgColor-default).
    var panel: Color { light ? .white : Theme.sidebar }
    /// borderColor-muted: borderColor-default at 70%.
    var divider: Color { light ? Self.hex(0xD1D9E0).opacity(0.7) : Theme.divider }
    /// Faint fills (pills, the layout switch, comment cards) are this at a low opacity.
    var ink: Color { light ? .black : .white }
    /// Code and names without a syntax colour (fgColor-default).
    var text: Color { light ? Self.hex(0x1F2328) : .primary }

    /// File cards: the code area is the terminal's own background, the header a
    /// step lighter, with a border a bit brighter than `divider`.
    var code: Color { light ? .white : Theme.background }
    var fileHeader: Color {
        guard !light else { return Self.hex(0xF6F8FA) }
        let base = GhosttyRuntime.shared.backgroundColor
        return Color(nsColor: base.blended(withFraction: 0.07, of: .white) ?? base)
    }
    var cardBorder: Color { light ? Self.hex(0xD1D9E0) : .white.opacity(0.11) }
    /// The `@@` hunk header row, as on GitHub: a faint blue band, dim text.
    var hunkBackground: Color { light ? Self.hex(0xDDF4FF) : Color(red: 0.22, green: 0.55, blue: 1).opacity(0.10) }
    /// The hunk row's line-number cell, where the expanders are (diffBlob-hunkNum).
    var hunkNum: Color { light ? Self.hex(0xB6E3FF) : Color(red: 0.22, green: 0.55, blue: 1).opacity(0.22) }
    var hunkText: Color { light ? Self.hex(0x59636E) : Color(red: 0.55, green: 0.68, blue: 0.92).opacity(0.8) }

    /// Diff line backgrounds (light: diffBlob-additionLine, -deletionLine).
    var added: Color { light ? Self.hex(0xDAFBE1) : .green.opacity(0.14) }
    var removed: Color { light ? Self.hex(0xFFEBE9) : .red.opacity(0.14) }
    /// Drawn over the line's tint on its line numbers. Light: opaque, so the gutter is exactly
    /// diffBlob-additionNum / -deletionNum; dark: translucent, a step stronger than the line.
    var addedGutter: Color { light ? Self.hex(0xACEEBB) : .green.opacity(0.12) }
    var removedGutter: Color { light ? Self.hex(0xFFCECB) : .red.opacity(0.12) }
    /// Behind the words that changed inside a changed line pair, over the line's tint
    /// (light: the Num colours, as GitHub; dark: the line tint at about 2.5×).
    var addedWord: Color { light ? Self.hex(0xACEEBB) : .green.opacity(0.35) }
    var removedWord: Color { light ? Self.hex(0xFFCECB) : .red.opacity(0.35) }
    /// Lines picked for a comment, as GitHub's: attention muted, the numbers a step stronger.
    var selectedLine: Color { light ? Self.hex(0xFFF8C5) : Self.hex(0xBB8009).opacity(0.18) }
    var selectedNum: Color { light ? Self.hex(0xFAE17D).opacity(0.55) : Self.hex(0xBB8009).opacity(0.3) }
    /// The empty side of a split diff row (diffBlob-emptyLine).
    var filler: Color { light ? Self.hex(0xF6F8FA) : .black.opacity(0.12) }

    /// Text colours for the counts, secondary text and the primary button
    /// (light: fgColor-success, -danger, -muted; button-primary-bgColor with white text).
    var addedText: Color { light ? Self.hex(0x1A7F37) : .green }
    var removedText: Color { light ? Self.hex(0xD1242F) : .red }
    /// Stat squares: success and danger emphasis, a stronger pair than the text.
    var addedSquare: Color { light ? Self.hex(0x1F883D) : .green }
    var removedSquare: Color { light ? Self.hex(0xCF222E) : .red }
    var secondaryText: Color { light ? Self.hex(0x59636E) : .secondary }
    var accent: Color { light ? Self.hex(0x1F883D) : .accentColor }

    /// Behind each use of the name being followed: Primer's attention border (muted), strong
    /// enough to read on the green and red line tints.
    var nameMark: Color {
        light ? Self.hex(0xD4A72C).opacity(0.4) : Self.hex(0xBB8009).opacity(0.4)
    }

    /// Primer's default button (button-default-*): the header's dropdowns, Keep, Auto.
    var buttonFill: Color { light ? Self.hex(0xF6F8FA) : Self.hex(0x212830) }
    var buttonHover: Color { light ? Self.hex(0xEFF2F5) : Self.hex(0x262C36) }
    var buttonBorder: Color { light ? Self.hex(0xD1D9E0) : Self.hex(0x3D444D) }
    var buttonText: Color { light ? Self.hex(0x1F2328) : Self.hex(0xF0F6FC) }
    /// Primer's primary button (button-primary-*): green, white text.
    var primaryFill: Color { light ? Self.hex(0x1F883D) : Self.hex(0x238636) }
    var primaryHover: Color { light ? Self.hex(0x1C8139) : Self.hex(0x29903B) }
    var primaryBorder: Color { light ? Self.hex(0x1F2328).opacity(0.15) : Self.hex(0xF0F6FC).opacity(0.1) }
    /// The file tree: folder icons (treeViewItem-leadingVisual) and the current file's row and bar.
    var folder: Color { Self.hex(0x54AEFF) }
    var treeSelected: Color { light ? Self.hex(0x818B98).opacity(0.15) : Self.hex(0x656C76).opacity(0.24) }
    /// A menu row under the pointer (control-transparent-bgColor-hover).
    var rowHover: Color { light ? Self.hex(0x818B98).opacity(Double(0x1A) / 255) : Self.hex(0x656C76).opacity(Double(0x33) / 255) }
    /// SegmentedControl: the track (bgColor-neutral-muted) and the selected segment (controlKnob-bgColor-rest).
    var segmentTrack: Color { light ? Self.hex(0x818B98).opacity(Double(0x1F) / 255) : Self.hex(0x656C76).opacity(Double(0x33) / 255) }
    var segmentKnob: Color { light ? .white : Self.hex(0x2A313C) }

    /// File status icons, as GitHub's file tree: added success, modified attention, deleted danger.
    func status(_ status: FileDiff.Status) -> Color {
        switch status {
        case .added: addedText
        case .modified: light ? Self.hex(0x9A6700) : Self.hex(0xD29922)
        case .deleted: removedText
        case .renamed: light ? Self.hex(0x0969DA) : Self.hex(0x4493F8)
        }
    }
}

/// The agent's overview: Primer's success, attention and danger roles (muted fill,
/// emphasis border, fg text), light and dark, as github.com draws them.
@MainActor extension ReviewPalette {
    /// Map card fills: muted, untouched the panel's.
    func fill(_ state: AgentOverview.State) -> Color {
        switch state {
        case .added: light ? Self.hex(0xDAFBE1) : Self.hex(0x2EA043).opacity(Double(0x26) / 255)
        case .changed: light ? Self.hex(0xFFF8C5) : Self.hex(0xBB8009).opacity(Double(0x26) / 255)
        case .removed: light ? Self.hex(0xFFEBE9) : Self.hex(0xF85149).opacity(Double(0x1A) / 255)
        case .untouched: panel
        }
    }

    /// Map card borders: emphasis (untouched dashed, in borderColor-default: dark's
    /// card border is too faint dashed).
    func stroke(_ state: AgentOverview.State) -> Color {
        switch state {
        case .added: light ? Self.hex(0x1F883D) : Self.hex(0x238636)
        case .changed: light ? Self.hex(0x9A6700) : Self.hex(0x9E6A03)
        case .removed: light ? Self.hex(0xCF222E) : Self.hex(0xDA3633)
        case .untouched: light ? cardBorder : Self.hex(0x3D444D)
        }
    }

    /// Map edges: as the borders, changed ones in attention fg (stronger on the lane fill).
    func edge(_ state: AgentOverview.State) -> Color {
        state == .changed ? (light ? Self.hex(0x9A6700) : Self.hex(0xD29922)) : stroke(state)
    }

    /// Change map edges and arrowheads: as `edge`, untouched ones lighter but
    /// still readable on the panel (dark's untouched border is too faint for a line).
    func mapEdge(_ state: AgentOverview.State) -> Color {
        state == .untouched ? secondaryText.opacity(0.55) : edge(state)
    }

    /// Severity labels are outlined: danger, attention, muted.
    func severityText(_ severity: AgentOverview.Severity) -> Color {
        switch severity {
        case .high: light ? Self.hex(0xD1242F) : Self.hex(0xF85149)
        case .medium: light ? Self.hex(0x9A6700) : Self.hex(0xD29922)
        case .low: secondaryText
        }
    }

    func severityBorder(_ severity: AgentOverview.Severity) -> Color {
        switch severity {
        case .high: stroke(.removed)
        case .medium: stroke(.changed)
        case .low: cardBorder
        }
    }

    /// Resolved concerns (fgColor-done).
    var done: Color { light ? Self.hex(0x8250DF) : Self.hex(0xAB7DF8) }

    /// Anchor chips and the tour (fgColor-accent on bgColor-accent-muted).
    var link: Color { light ? Self.hex(0x0969DA) : Self.hex(0x4493F8) }
    var linkFill: Color { light ? Self.hex(0xDDF4FF) : Self.hex(0x388BFD).opacity(Double(0x1A) / 255) }
    /// Behind a map lane and the pane's bar (bgColor-muted): the file header's.
    var laneFill: Color { fileHeader }
}

extension EnvironmentValues {
    var reviewPalette: ReviewPalette { ReviewPalette(light: colorScheme == .light) }
}
