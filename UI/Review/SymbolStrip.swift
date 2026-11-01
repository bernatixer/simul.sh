import SwiftUI

/// Under an expanded file's header: the functions and types its changes
/// touch, grouped by kind as small pills that wrap. Clicking one scrolls to
/// its first line.
struct SymbolStrip: View {
    let symbols: [SymbolChange]
    let onSelect: (SymbolChange) -> Void
    @Environment(\.reviewPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            FlowLayout(spacing: 4) {
                // SymbolDiff sorts by kind, so each group is a run. A label and its
                // first pill are one view, so a label never ends a line alone.
                ForEach(symbols.indices, id: \.self) { i in
                    let label = Self.label(symbols[i].kind)
                    if i == 0 || Self.label(symbols[i - 1].kind) != label {
                        HStack(spacing: 4) {
                            Text(label)
                                .foregroundStyle(palette.secondaryText)
                                .padding(.vertical, 1)
                                .fixedSize()
                            pill(symbols[i])
                        }
                        .padding(.leading, i == 0 ? 0 : 6)
                    } else {
                        pill(symbols[i])
                    }
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(palette.divider).frame(height: 1)
        }
    }

    private func pill(_ symbol: SymbolChange) -> some View {
        Button { onSelect(symbol) } label: {
            Text(Self.title(symbol))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(palette.ink.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.secondaryText)
        .help("Go to its first line")
    }

    static func label(_ kind: SymbolChange.Kind) -> String {
        switch kind {
        case .changed: "Changed"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .moved: "Moved"
        case .formatting: "Formatting"
        }
    }

    static func title(_ symbol: SymbolChange) -> String {
        switch symbol.kind {
        case let .renamed(from): "\(from) → \(symbol.name)"
        case let .moved(from): "\(symbol.name) ← \(from)"
        default: symbol.name
        }
    }
}

/// Its views left to right, wrapping onto new lines; a view wider than the
/// line is truncated to it.
struct FlowLayout: Layout {
    var spacing: CGFloat

    /// The arrangement for the last width: a parent's relayout (a sibling
    /// grew) asks again with the same width.
    struct Cache {
        var width: CGFloat = -1
        var frames: [CGRect] = []
        var size: CGSize = .zero
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? .infinity
        let size = arranged(width, subviews, &cache).size
        return CGSize(width: width.isFinite ? width : size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let frames = arranged(bounds.width, subviews, &cache).frames
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }

    private func arranged(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) -> Cache {
        if cache.width != width {
            let (frames, size) = arrange(width, subviews)
            cache = Cache(width: width, frames: frames, size: size)
        }
        return cache
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> ([CGRect], CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            line = max(line, size.height)
        }
        return (frames, CGSize(width: widest, height: y + line))
    }
}
