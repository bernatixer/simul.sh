import Foundation

/// URLs in a terminal line, by column (one character per cell, like
/// ImageTokens). Lets the terminal show a pointing hand over links that
/// the agent itself opens on click.
enum TerminalLinks {
    static func isURL(atColumn column: Int, in line: String) -> Bool {
        let chars = Array(line)
        guard column >= 0, column < chars.count, !chars[column].isWhitespace else { return false }
        var start = column
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        var end = column
        while end + 1 < chars.count, !chars[end + 1].isWhitespace { end += 1 }
        let word = String(chars[start...end])
        guard let scheme = word.range(of: "https?://", options: .regularExpression) else { return false }
        return column - start >= word.distance(from: word.startIndex, to: scheme.lowerBound)
    }
}
