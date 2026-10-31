import SwiftUI

/// Simul's small buttons, in place of stock bordered ones: quiet (no fill
/// until hovered, like the title-bar icons), pill (a soft fill, like the
/// new-session folder button) and primary (accent).
struct SimulButtonStyle: ButtonStyle {
    enum Kind { case quiet, pill, primary }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        SimulButtonBody(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == SimulButtonStyle {
    static func simul(_ kind: SimulButtonStyle.Kind) -> SimulButtonStyle { SimulButtonStyle(kind: kind) }
}

private struct SimulButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SimulButtonStyle.Kind
    @Environment(\.isEnabled) private var enabled
    /// Dark everywhere but a light review.
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { if hovering != $0 { hovering = $0 } }
    }

    /// Fills are this at a low opacity.
    private var ink: Color { scheme == .light ? .black : .white }

    private var active: Bool { enabled && (hovering || configuration.isPressed) }

    private var foreground: Color {
        guard enabled else { return Color.secondary.opacity(0.6) }
        switch kind {
        case .primary: return .white
        case .pill: return .primary
        case .quiet: return active ? .primary : .secondary
        }
    }

    private var fill: Color {
        let pressed = configuration.isPressed
        switch kind {
        case .primary:
            return enabled ? ReviewPalette(light: scheme == .light).accent.opacity(pressed ? 0.7 : hovering ? 0.85 : 1) : ink.opacity(0.06)
        case .pill:
            return ink.opacity(pressed ? 0.14 : active ? 0.10 : 0.06)
        case .quiet:
            return ink.opacity(pressed ? 0.12 : active ? 0.08 : 0)
        }
    }
}

/// The review's buttons, as GitHub's (Primer's default button): a light fill and a
/// border, hover a step darker. 28 tall for the header's dropdowns, smaller inline.
/// `primary`: GitHub's green button (white text), for the review's main action.
struct PrimerButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        PrimerButtonBody(configuration: configuration, height: height, primary: primary)
    }
}

extension ButtonStyle where Self == PrimerButtonStyle {
    static func primer(height: CGFloat = 28, primary: Bool = false) -> PrimerButtonStyle {
        PrimerButtonStyle(height: height, primary: primary)
    }
}

private struct PrimerButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    let primary: Bool
    @Environment(\.reviewPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        let active = enabled && (hovering || configuration.isPressed)
        configuration.label
            .font(.system(size: 12, weight: primary ? .semibold : .medium))
            .foregroundStyle(primary ? .white : palette.buttonText)
            .padding(.horizontal, height < 28 ? 8 : 12)
            .frame(height: height)
            .background(shape.fill(primary ? (active ? palette.primaryHover : palette.primaryFill)
                                           : (active ? palette.buttonHover : palette.buttonFill)))
            .overlay(shape.strokeBorder(primary ? palette.primaryBorder : palette.buttonBorder, lineWidth: 1))
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.5)
            .onHover { if hovering != $0 { hovering = $0 } }
    }
}

extension View {
    /// Simul's text field: a plain field on a quiet rounded fill.
    func simulField() -> some View { modifier(SimulField()) }
}

private struct SimulField: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let ink: Color = scheme == .light ? .black : .white
        return content
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(ink.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink.opacity(0.10), lineWidth: 1))
    }
}
