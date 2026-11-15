import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An image in the message box: a copy in the session's pastes folder, and
/// the name it's shown under ("image.png" for a pasted screenshot).
struct ComposerImage: Equatable, Identifiable {
    let url: URL
    let name: String
    var id: URL { url }
}

/// The message box's contents in order: text, and images where they were
/// pasted. Sent the same way (PromptPiece).
enum ComposerPart: Equatable {
    case text(String)
    case image(ComposerImage)
}

/// The message box's text field: an AppKit text view, because SwiftUI's
/// can't hold images. A pasted image, or image files copied in Finder, go
/// in at the cursor as a token (thumbnail, name, size) that Backspace
/// deletes like a character; other files paste as their paths. Return
/// sends, ⇧/⌥Return adds a line.
struct ComposerTextView: NSViewRepresentable {
    @Binding var parts: [ComposerPart]
    /// Grows with the text, 2 to 10 lines.
    @Binding var height: CGFloat
    let placeholder: String
    /// Changing it puts the cursor in the box.
    let focusRequest: Int
    /// Where pasted and dropped images are copied.
    let imagesFolder: URL
    let onSubmit: () -> Void

    static let font = NSFont.systemFont(ofSize: 13.5)
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.pasteHandler = { [weak coordinator = context.coordinator] in coordinator?.paste(from: $0, into: $1) ?? false }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.typingAttributes = Self.textAttributes
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.setAccessibilityLabel("Message")

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = scroll.documentView as? ComposerNSTextView else { return }
        let appearance = NSAppearance(named: context.environment.colorScheme == .light ? .aqua : .darkAqua)
        if textView.appearance?.name != appearance?.name { textView.appearance = appearance }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
        // Changed from outside (× on a thumbnail, a sent message, a draft back): rebuild.
        if let storage = textView.textStorage, Self.parts(of: storage) != parts {
            coordinator.load(parts, into: textView)
        }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            // After the terminal underneath has given the keyboard up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    static var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor]
    }

    /// The box's contents: text runs, and an image per token.
    static func parts(of storage: NSAttributedString) -> [ComposerPart] {
        var parts: [ComposerPart] = []
        var text = ""
        let string = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let token = value as? ImageToken {
                if !text.isEmpty { parts.append(.text(text)) }
                text = ""
                parts.append(.image(token.item))
            } else {
                text += string.substring(with: range)
            }
        }
        if !text.isEmpty { parts.append(.text(text)) }
        return parts
    }

    /// A copy of `url` in `folder` (pasted images already are): a clean
    /// path, which Claude turns into an attachment, cleared on launch like
    /// terminal pastes. nil if it can't be copied.
    static func localCopy(of url: URL, in folder: URL) -> URL? {
        if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { return url }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("paste-\(UUID().uuidString.prefix(8)).\(url.pathExtension.lowercased())")
        return (try? FileManager.default.copyItem(at: url, to: copy)) == nil ? nil : copy
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var focusRequest = -1

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, let storage = textView.textStorage else { return }
            let parts = ComposerTextView.parts(of: storage)
            if parent.parts != parts { parent.parts = parts }
            textView.needsDisplay = true // placeholder
            measure(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        /// Copied files: images as tokens, the rest typed as paths. An image
        /// on its own is saved first. Text is left to the text view.
        func paste(from pasteboard: NSPasteboard, into textView: NSTextView) -> Bool {
            let folder = parent.imagesFolder
            let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            if !files.isEmpty {
                for file in files {
                    if ComposerTextView.imageTypes.contains(file.pathExtension.lowercased()),
                       let copy = ComposerTextView.localCopy(of: file, in: folder) {
                        insert(ComposerImage(url: copy, name: file.lastPathComponent), into: textView)
                    } else {
                        insert(NSAttributedString(string: ClipboardPaste.shellEscaped(file.path) + " ",
                                                  attributes: ComposerTextView.textAttributes), into: textView)
                    }
                }
                return true
            }
            if pasteboard.string(forType: .string) != nil { return false }
            guard let saved = ClipboardPaste.saveImage(from: pasteboard, in: folder) else { return false }
            insert(ComposerImage(url: saved, name: "image.png"), into: textView)
            return true
        }

        /// A token and a space at the cursor, undoable like typing.
        func insert(_ image: ComposerImage, into textView: NSTextView) {
            let token = NSMutableAttributedString(attachment: makeToken(image, in: textView))
            token.addAttributes(ComposerTextView.textAttributes, range: NSRange(location: 0, length: token.length))
            token.append(NSAttributedString(string: " ", attributes: ComposerTextView.textAttributes))
            insert(token, into: textView)
        }

        private func insert(_ string: NSAttributedString, into textView: NSTextView) {
            let range = textView.selectedRange()
            guard textView.shouldChangeText(in: range, replacementString: string.string) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: string)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location + string.length, length: 0))
        }

        /// Replaces the box's contents (cursor to the end).
        func load(_ parts: [ComposerPart], into textView: NSTextView) {
            let contents = NSMutableAttributedString()
            for part in parts {
                switch part {
                case let .text(text):
                    contents.append(NSAttributedString(string: text, attributes: ComposerTextView.textAttributes))
                case let .image(image):
                    let token = NSMutableAttributedString(attachment: makeToken(image, in: textView))
                    token.addAttributes(ComposerTextView.textAttributes, range: NSRange(location: 0, length: token.length))
                    contents.append(token)
                }
            }
            textView.textStorage?.setAttributedString(contents)
            textView.typingAttributes = ComposerTextView.textAttributes
            textView.setSelectedRange(NSRange(location: contents.length, length: 0))
            textView.needsDisplay = true
            measure(textView)
        }

        /// The token draws a placeholder until its thumbnail is decoded,
        /// off the main thread.
        private func makeToken(_ image: ComposerImage, in textView: NSTextView) -> ImageToken {
            let token = ImageToken(image: image)
            let url = image.url
            Task { [weak textView] in
                let thumbnail = await Task.detached(priority: .userInitiated) {
                    ClipboardPaste.thumbnail(of: url, maxPixels: 48)
                }.value
                guard let thumbnail, let textView, let storage = textView.textStorage else { return }
                token.thumbnail = NSImage(cgImage: thumbnail, size: NSSize(width: 16, height: 16))
                storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                    guard value as? ImageToken === token else { return }
                    textView.layoutManager?.invalidateDisplay(forCharacterRange: range)
                    stop.pointee = true
                }
            }
            return token
        }

        func measure(_ textView: NSTextView) {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: ComposerTextView.font)
            let height = min(max(layout.usedRect(for: container).height, line * 2), line * 10).rounded(.up)
            guard abs(parent.height - height) > 0.5 else { return }
            let binding = parent.$height
            DispatchQueue.main.async { binding.wrappedValue = height } // not during a view update
        }
    }
}

/// An image's token in the text: thumbnail, name in the link colour, file
/// size, as T3 Code shows them. Drawn by its cell, so colours follow the
/// box's light or dark appearance.
@MainActor
final class ImageToken: NSTextAttachment {
    let item: ComposerImage
    var thumbnail: NSImage?
    let size: String

    init(image: ComposerImage) {
        item = image
        let bytes = (try? image.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        super.init(data: nil, ofType: nil)
        attachmentCell = ImageTokenCell(token: self)
    }

    required init?(coder: NSCoder) { fatalError("not coded") }
}

private final class ImageTokenCell: NSTextAttachmentCell {
    unowned let token: ImageToken
    private static let thumb: CGFloat = 16
    private static let nameFont = ComposerTextView.font
    private static let sizeFont = NSFont.systemFont(ofSize: 11)

    init(token: ImageToken) {
        self.token = token
        super.init()
    }

    required init(coder: NSCoder) { fatalError("not coded") }

    private var name: NSAttributedString {
        NSAttributedString(string: token.item.name, attributes: [.font: Self.nameFont, .foregroundColor: NSColor.linkColor])
    }

    private var size: NSAttributedString {
        NSAttributedString(string: token.size, attributes: [.font: Self.sizeFont, .foregroundColor: NSColor.secondaryLabelColor])
    }

    override func cellSize() -> NSSize {
        NSSize(width: 2 + Self.thumb + 5 + name.size().width + 5 + size.size().width + 3,
               height: max(Self.thumb, name.size().height))
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: Self.nameFont.descender)
    }

    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        let box = NSRect(x: frame.minX + 2, y: frame.midY - Self.thumb / 2, width: Self.thumb, height: Self.thumb)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).addClip()
        if let thumbnail = token.thumbnail {
            thumbnail.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor.quaternaryLabelColor.setFill()
            box.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = self.name
        let nameSize = name.size()
        name.draw(at: NSPoint(x: box.maxX + 5, y: frame.midY - nameSize.height / 2))
        let size = self.size
        let sizeSize = size.size()
        size.draw(at: NSPoint(x: box.maxX + 5 + nameSize.width + 5, y: frame.midY - sizeSize.height / 2 + 0.5))
    }
}

final class ComposerNSTextView: NSTextView {
    var placeholder = ""
    /// Returns true when it took the paste.
    var pasteHandler: ((NSPasteboard, NSTextView) -> Bool)?

    override func paste(_ sender: Any?) {
        if pasteHandler?(.general, self) == true { return }
        pasteAsPlainText(sender)
    }

    /// A plain-text view turns Paste off for an image-only clipboard, so
    /// ⌘V would never reach `paste`.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(paste(_:)) else { return super.validateUserInterfaceItem(item) }
        return NSPasteboard.general.canReadItem(withDataConformingToTypes: [
            UTType.image.identifier, UTType.fileURL.identifier, UTType.plainText.identifier,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(at: .zero, withAttributes: [
            .font: ComposerTextView.font,
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }
}
