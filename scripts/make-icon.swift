// Renders Resources/AppIcon.icns and the README/social banners from the
// orbit dot-matrix art.
// Run: scripts/make-icon.sh (compiles this with UI/Components/DotMatrix.swift).
import AppKit
import SwiftUI

struct AppIcon: View {
    var body: some View {
        ZStack {
            // macOS icon grid: 824pt squircle centered in 1024.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.20, green: 0.22, blue: 0.27), Color(red: 0.10, green: 0.11, blue: 0.14)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            // Light parked on the upper-right board.
            DotMatrix(source: .orbit, columns: 36, shimmer: 1, fixedTime: -0.5)
                .frame(width: 640, height: 640)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// The orbit beside the name, on the icon's background.
struct Banner: View {
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        HStack(spacing: height * 0.1) {
            DotMatrix(source: .orbit, columns: 36, shimmer: 1, fixedTime: -0.5)
                .frame(width: height * 0.7, height: height * 0.7)
            VStack(alignment: .leading, spacing: height * 0.035) {
                Text("Simul")
                    .font(.system(size: height * 0.22, weight: .bold))
                    .tracking(-height * 0.006)
                Text("One player, many boards.")
                    .font(.system(size: height * 0.07, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Claude Code · Codex · OpenCode · shell")
                    .font(.system(size: height * 0.045, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.top, height * 0.02)
            }
        }
        .foregroundStyle(.white)
        .frame(width: width, height: height)
        .background(LinearGradient(
            colors: [Color(red: 0.16, green: 0.17, blue: 0.21), Color(red: 0.08, green: 0.09, blue: 0.11)],
            startPoint: .top, endPoint: .bottom))
    }
}

@MainActor func png(_ view: some View, scale: CGFloat) throws -> Data {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    return png
}

@main
struct MakeIcon {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1]) // .iconset directory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                try png(AppIcon(), scale: CGFloat(size * scale) / 1024)
                    .write(to: output.appendingPathComponent(name))
            }
        }
        // README banner (2×) and the og:image for simul.sh (1200×630).
        let assets = URL(fileURLWithPath: CommandLine.arguments[2])
        try png(Banner(width: 1280, height: 400), scale: 2).write(to: assets.appendingPathComponent("banner.png"))
        try png(Banner(width: 1200, height: 630), scale: 1).write(to: assets.appendingPathComponent("og.png"))
    }
}
