import SwiftUI

/// A comment's ```suggestion block, as GitHub draws it: "Suggested change" over a mini diff,
/// the commented lines removed and the suggestion added.
struct SuggestionDiff: View {
    @Environment(\.reviewPalette) private var palette
    /// The lines commented on, if the diff shows them.
    let old: [String]?
    let new: [String]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        VStack(alignment: .leading, spacing: 0) {
            Text("Suggested change")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.fileHeader)
            Rectangle().fill(palette.cardBorder).frame(height: 1)
            ForEach(Array((old ?? []).enumerated()), id: \.offset) { _, line in
                row("-", line, palette.removed, palette.removedText)
            }
            ForEach(Array(new.enumerated()), id: \.offset) { _, line in
                row("+", line, palette.added, palette.addedText)
            }
        }
        .background(palette.code)
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.cardBorder, lineWidth: 1))
    }

    private func row(_ sign: String, _ text: String, _ fill: Color, _ signColour: Color) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(sign).foregroundStyle(signColour).frame(width: 22)
            Text(verbatim: text).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
    }
}

/// A comment's text, its suggestion blocks as SuggestionDiffs.
struct CommentText: View {
    @Environment(\.reviewPalette) private var palette
    let text: String
    /// The commented lines, for the suggestions' removed side.
    var original: [String]?

    var body: some View {
        if Suggestion.contains(text) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Suggestion.parts(text).enumerated()), id: \.offset) { _, part in
                    switch part {
                    case let .text(t): prose(t)
                    case let .suggestion(lines): SuggestionDiff(old: original, new: lines)
                    }
                }
            }
        } else {
            prose(text)
        }
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(palette.text)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
