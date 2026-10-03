// Renders Resources/AppIcon.icns from the orbit dot-matrix art.
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

@main
struct MakeIcon {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1]) // .iconset directory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let renderer = ImageRenderer(content: AppIcon())
                renderer.scale = CGFloat(size * scale) / 1024
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { throw CocoaError(.fileWriteUnknown) }
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                try png.write(to: output.appendingPathComponent(name))
            }
        }
    }
}
