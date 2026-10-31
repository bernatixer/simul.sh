import Foundation

/// The words that changed inside a removed/added line pair, as GitHub marks
/// them: character offsets on each side, or nil when the lines differ too much
/// to be worth marking (or are too long to compare).
enum WordDiff {
    /// Longer lines aren't compared.
    static let maxLength = 500
    /// At most this many token pairs compared (the LCS table's size).
    static let maxWork = 40_000

    private struct Token {
        let text: String
        let range: Range<Int>
        let space: Bool
    }

    static func changes(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>])? {
        let a = Array(old), b = Array(new)
        let lengthA = a.last == "\r" ? a.count - 1 : a.count, lengthB = b.last == "\r" ? b.count - 1 : b.count
        guard max(lengthA, lengthB) <= maxLength else { return nil }
        let x = tokens(a[..<lengthA]), y = tokens(b[..<lengthB])

        // Common ends first: the table is only for what's between them.
        var low = 0
        while low < x.count, low < y.count, x[low].text == y[low].text { low += 1 }
        var highX = x.count, highY = y.count
        while highX > low, highY > low, x[highX - 1].text == y[highY - 1].text { highX -= 1; highY -= 1 }
        let n = highX - low, m = highY - low
        guard n * m <= maxWork else { return nil }

        // lcs[i * w + j]: the longest common run of x[low + i..<highX] and y[low + j..<highY].
        let w = m + 1
        var lcs = [Int](repeating: 0, count: (n + 1) * w)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i * w + j] = x[low + i].text == y[low + j].text ? lcs[(i + 1) * w + j + 1] + 1
                    : max(lcs[(i + 1) * w + j], lcs[i * w + j + 1])
            }
        }
        var sameX = [Bool](repeating: true, count: x.count), sameY = [Bool](repeating: true, count: y.count)
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, x[low + i].text == y[low + j].text {
                i += 1; j += 1
            } else if j == m || (i < n && lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]) {
                sameX[low + i] = false; i += 1
            } else {
                sameY[low + j] = false; j += 1
            }
        }

        // Whitespace doesn't count: two unrelated lines share their indentation.
        func text(_ t: [Token], _ keep: (Int) -> Bool) -> Int {
            t.indices.filter { !t[$0].space && keep($0) }.reduce(0) { $0 + t[$1].range.count }
        }
        let shared = text(x) { sameX[$0] }
        guard shared * 2 >= max(text(x) { _ in true }, text(y) { _ in true }) else { return nil }
        let result = (ranges(x, sameX), ranges(y, sameY))
        return result.0.isEmpty && result.1.isEmpty ? nil : result
    }

    /// Identifier and number runs, whitespace runs, and single other characters.
    private static func tokens(_ chars: ArraySlice<Character>) -> [Token] {
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var result: [Token] = []
        var i = chars.startIndex
        while i < chars.endIndex {
            let c = chars[i]
            var j = i + 1
            if isWord(c) {
                while j < chars.endIndex, isWord(chars[j]) { j += 1 }
            } else if c.isWhitespace {
                while j < chars.endIndex, chars[j].isWhitespace { j += 1 }
            }
            result.append(Token(text: String(chars[i..<j]), range: i..<j, space: c.isWhitespace))
            i = j
        }
        return result
    }

    /// The changed tokens' ranges, ones separated only by whitespace merged.
    private static func ranges(_ tokens: [Token], _ same: [Bool]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var k = 0
        while k < tokens.count {
            guard !same[k] else { k += 1; continue }
            var end = k, j = k + 1
            while j < tokens.count {
                if !same[j] { end = j; j += 1 }
                else if tokens[j].space, j + 1 < tokens.count, !same[j + 1] { j += 1 }
                else { break }
            }
            result.append(tokens[k].range.lowerBound..<tokens[end].range.upperBound)
            k = end + 1
        }
        return result
    }
}
