import AppKit
import ImageIO

/// What a terminal paste should type for the clipboard's contents. Copied
/// files paste as their paths and an image on its own is saved as a PNG and
/// pasted as its path: agents (Claude Code, Codex) turn a pasted image path
/// into an attachment.
enum ClipboardPaste {
    /// Text for a paste: file paths, else plain text, else a saved image's
    /// path (`savedImage` is set then). Empty when there's nothing usable.
    static func text(from pasteboard: NSPasteboard, savingImagesIn folder: URL) -> (text: String, savedImage: URL?) {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            return (files.map { shellEscaped($0.path) }.joined(separator: " "), nil)
        }
        if let string = pasteboard.string(forType: .string) {
            return (string, nil)
        }
        if let image = saveImage(from: pasteboard, in: folder) {
            return (shellEscaped(image.path), image)
        }
        return ("", nil)
    }

    /// Writes the clipboard's image (PNG, or TIFF converted to PNG) into
    /// `folder`; nil when the clipboard holds no image or writing fails.
    static func saveImage(from pasteboard: NSPasteboard, in folder: URL) -> URL? {
        let png = pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        guard let png else { return nil }
        let url = folder.appendingPathComponent("paste-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Backslash-escapes what a shell would split or expand, the way a
    /// terminal pastes a dragged file.
    static func shellEscaped(_ path: String) -> String {
        let special = Set(#"\ ()[]{}<>"'`!#$&;|*?"#).union(["\t"])
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    /// A small thumbnail, decoded at `maxPixels` on its longest side without
    /// loading the full image. Call off the main thread.
    static func thumbnail(of url: URL, maxPixels: Int = 200) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }
}
