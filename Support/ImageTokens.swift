import Foundation

/// The "[Image #N]" placeholders Claude Code shows for attached images.
enum ImageTokens {
    struct Token: Equatable {
        let number: Int
        /// First and last column of "[Image #N]" in its line.
        let columns: ClosedRange<Int>
    }

    static func tokens(in line: String) -> [Token] {
        let chars = Array(line)
        var found: [Token] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "[", chars[i...].starts(with: "[Image #") {
                var j = i + 8
                var digits = ""
                while j < chars.count, chars[j].isASCII, chars[j].isNumber {
                    digits.append(chars[j])
                    j += 1
                }
                if !digits.isEmpty, j < chars.count, chars[j] == "]", let n = Int(digits) {
                    found.append(Token(number: n, columns: i...j))
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return found
    }

    /// Every number on screen (any number of lines).
    static func numbers(in text: String) -> [Int] {
        text.split(separator: "\n", omittingEmptySubsequences: false).flatMap { tokens(in: String($0)).map(\.number) }
    }

    /// The highest number on screen more often than before, or nil.
    static func newNumber(before: [Int], after: [Int]) -> Int? {
        var counts = Dictionary(before.map { ($0, 1) }, uniquingKeysWith: +)
        return after.filter { n in
            counts[n, default: 0] -= 1
            return counts[n]! < 0
        }.max()
    }

    /// The token covering `column`, if any.
    // ponytail: columns are characters, so a wide character (CJK, emoji)
    // earlier in the line shifts the match; read cell widths if that bites.
    static func token(atColumn column: Int, in line: String) -> Token? {
        tokens(in: line).first { $0.columns.contains(column) }
    }
}
