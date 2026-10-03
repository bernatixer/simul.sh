import AppKit
import SwiftUI

/// Pixel art drawn as a dot matrix (Codex-style): a source is sampled once
/// into an n×n grid of coverage + color, then drawn as small rounded dots
/// with stable per-dot brightness and an optional animated highlight.
struct DotMatrix: View {
    enum Source {
        /// Simul's mark: you in the middle, a ring of boards around you, and
        /// a light moving from board to board (a chess simul, abstracted).
        case orbit
        case glyph(String)
        /// An image (e.g. an agent logo); `key` identifies it in the cache.
        case image(NSImage, key: String)
    }

    var source: Source = .orbit
    var columns: Int = 48
    /// Shimmer speed; 0 = static.
    var shimmer: Double = 1
    /// Freeze the highlight at this time (for still images like the icon).
    var fixedTime: Double?

    var body: some View {
        let cells = Self.cells(for: source, columns: columns)
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: shimmer == 0 || fixedTime != nil)) { timeline in
            let time = fixedTime ?? timeline.date.timeIntervalSinceReferenceDate * shimmer
            Canvas { context, size in
                let cell = min(size.width, size.height) / CGFloat(columns)
                let dot = cell * 0.62
                let origin = CGPoint(
                    x: (size.width - cell * CGFloat(columns)) / 2,
                    y: (size.height - cell * CGFloat(columns)) / 2)
                for row in 0..<columns {
                    for col in 0..<columns {
                        let sample = cells[row * columns + col]
                        guard sample.coverage > 0.12 else { continue }
                        let noise = Self.hash(row, col)
                        let sweep = shimmer == 0 ? 0 : highlight(row: row, col: col, time: time)
                        let brightness = min(1, 0.22 + 0.6 * sample.coverage * (0.55 + 0.45 * noise) + sweep)
                        let color = sample.color ?? (noise < 0.07
                            ? Color(red: 0.45, green: 0.74, blue: 0.86) // sparse teal accents
                            : Color.white)
                        let rect = CGRect(
                            x: origin.x + CGFloat(col) * cell + (cell - dot) / 2,
                            y: origin.y + CGFloat(row) * cell + (cell - dot) / 2,
                            width: dot, height: dot)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: dot * 0.2),
                            with: .color(color.opacity(brightness)))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Orbit: a light circling the ring. Everything else: a diagonal band
    /// sweeping across.
    private func highlight(row: Int, col: Int, time: Double) -> Double {
        if case .orbit = source {
            let center = Double(columns - 1) / 2
            let angle = atan2(Double(row) - center, Double(col) - center)
            return pow(max(0, cos(angle - time * 1.6)), 10) * 0.55
        }
        let phase = Double(row + col) * 0.18 - time * 2.2
        return pow(max(0, cos(phase)), 12) * 0.45
    }

    struct Cell {
        var coverage: Double
        /// The source's own color here; nil = default palette (white/teal).
        var color: Color?
    }

    /// Eight round "boards" on a dotted orbit around a larger round
    /// "player" in the middle. Discs get soft edges so they read as circles.
    private static func orbitCells(columns: Int) -> [Cell] {
        let n = Double(columns)
        let center = (n - 1) / 2
        let orbit = n * 0.34
        let boardRadius = n * 0.065
        let playerRadius = n * 0.12
        let boards = (0..<8).map { i -> (Double, Double) in
            let angle = Double(i) * .pi / 4 - .pi / 2
            return (center + orbit * cos(angle), center + orbit * sin(angle))
        }
        /// 1 inside, fading to 0 across the last cell of the edge.
        func disc(_ distance: Double, _ radius: Double) -> Double {
            min(1, max(0, radius + 0.5 - distance))
        }
        var cells = [Cell](repeating: Cell(coverage: 0), count: columns * columns)
        for row in 0..<columns {
            for col in 0..<columns {
                let (x, y) = (Double(col), Double(row))
                let distance = hypot(x - center, y - center)
                var coverage = 0.0
                // Dotted orbit (every other cell along the ring).
                if abs(distance - orbit) < 0.5, (row + col) % 2 == 0 { coverage = 0.25 }
                for (bx, by) in boards {
                    coverage = max(coverage, disc(hypot(x - bx, y - by), boardRadius))
                }
                coverage = max(coverage, disc(distance, playerRadius))
                cells[row * columns + col].coverage = coverage
            }
        }
        return cells
    }

    /// Stable pseudo-random value in [0, 1) per dot.
    private nonisolated static func hash(_ row: Int, _ col: Int) -> Double {
        var x = UInt32(truncatingIfNeeded: row &* 73_856_093 ^ col &* 19_349_663)
        x ^= x >> 13; x = x &* 0x5bd1_e995; x ^= x >> 15
        return Double(x % 10_000) / 10_000
    }

    private static var cache: [String: [Cell]] = [:]

    /// Draws the source 6× supersampled (ink bounds centered) into an RGBA
    /// bitmap, then box-averages coverage and color per cell. Row 0 = top.
    static func cells(for source: Source, columns: Int) -> [Cell] {
        let key: String
        switch source {
        case .orbit: return orbitCells(columns: columns)
        case let .glyph(glyph): key = "g:\(glyph)#\(columns)"
        case let .image(_, imageKey): key = "i:\(imageKey)#\(columns)"
        }
        if let cached = cache[key] { return cached }

        let scale = 6
        let pixels = columns * scale
        var cells = [Cell](repeating: Cell(coverage: 0), count: columns * columns)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return cells }

        let size = CGFloat(pixels)
        let colored: Bool
        switch source {
        case .orbit:
            return cells
        case let .glyph(glyph):
            colored = false
            context.setFillColor(gray: 1, alpha: 1)
            let font = NSFont.systemFont(ofSize: size * 0.9)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: glyph,
                attributes: [.font: font, kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true]))
            let ink = CTLineGetImageBounds(line, context)
            let fit = 0.92 * size / max(ink.width, ink.height, 1)
            context.translateBy(x: size / 2, y: size / 2)
            context.scaleBy(x: fit, y: fit)
            context.textPosition = CGPoint(x: -ink.midX, y: -ink.midY)
            CTLineDraw(line, context)
        case let .image(image, _):
            colored = true
            var rect = CGRect(x: 0, y: 0, width: size, height: size)
            if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                let inset = size * 0.04
                context.interpolationQuality = .high
                context.draw(cgImage, in: rect.insetBy(dx: inset, dy: inset))
            }
        }

        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return cells }
        var lumas = [Double?](repeating: nil, count: columns * columns)
        for row in 0..<columns {
            for col in 0..<columns {
                var r = 0, g = 0, b = 0, a = 0
                for y in 0..<scale {
                    for x in 0..<scale {
                        let i = ((row * scale + y) * pixels + col * scale + x) * 4
                        r += Int(data[i]); g += Int(data[i + 1]); b += Int(data[i + 2]); a += Int(data[i + 3])
                    }
                }
                let index = row * columns + col
                cells[index].coverage = Double(a) / Double(scale * scale * 255)
                if colored, a > 0 {
                    // Un-premultiply to the ink's own color.
                    let (red, green, blue) = (Double(r) / Double(a), Double(g) / Double(a), Double(b) / Double(a))
                    lumas[index] = 0.299 * red + 0.587 * green + 0.114 * blue
                    cells[index].color = Color(red: red, green: green, blue: blue)
                }
            }
        }
        if colored {
            // Mostly-dark logos (black OpenAI knot) would vanish on a dark
            // background: draw them in the default palette. Otherwise dark
            // parts are cut-outs of a light logo (OpenCode): leave them empty.
            let inked = lumas.compactMap { $0 }
            let darkLogo = inked.reduce(0, +) / Double(max(inked.count, 1)) < 0.35
            for index in cells.indices {
                guard let luma = lumas[index] else { continue }
                if darkLogo {
                    cells[index].color = nil
                } else if luma < 0.35 {
                    cells[index].coverage = 0
                }
            }
        }
        cache[key] = cells
        return cells
    }
}
