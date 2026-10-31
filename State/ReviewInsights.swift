import Foundation
import SwiftUI

/// What the review knows about one parsed file.
struct FileInsight: Sendable, Equatable {
    var symbols: [SymbolChange] = []
    var oldLines: [Int: AttributedString] = [:]   // highlighted removed lines, by old line number
    var newLines: [Int: AttributedString] = [:]   // highlighted added and context lines, by new line number
}

/// A highlighted line's token kinds; the row colours them from the review's palette
/// as it draws, so switching light and dark needn't parse again.
enum TokenKindAttribute: AttributedStringKey {
    typealias Value = TokenKind
    static let name = "sh.simul.token"
}

/// The words that changed inside a removed/added line pair, marked with the line's kind.
enum WordChangeAttribute: AttributedStringKey {
    typealias Value = DiffLine.Kind
    static let name = "sh.simul.word-change"
}

/// Moves, formatting, symbols and highlights for a snapshot, on one serial
/// queue with one long-lived parser (compiling its queries takes a while).
/// Parses are kept for the last snapshot only, by blob or point:path.
final class ReviewInsights: @unchecked Sendable {
    static let maxBytes = 1 << 20
    /// Highlighted lines per review (~9 KB each); files past it show plain, symbols still found.
    static let maxHighlightedLines = 6_000

    private let queue = DispatchQueue(label: "sh.simul.review-insights", qos: .utility)
    // Queue only.
    private var parser: CodeParser?
    private var triedParser = false
    private var cache: [String: ParsedSource] = [:]
    /// Bumped by clear(): a run started before it doesn't refill the cache.
    private var generation = 0
    /// The last run: an equal one whose parses all came from the cache gives equal insights.
    private var last: (id: Session.ID, snapshot: ReviewSnapshot, parse: Bool)?

    /// Moves and formatting for every file; with `parse`, symbols and highlights
    /// (by path) for files in a parsed language, ≤ 1 MB and ≤ 1,500 diff lines.
    /// `changed` is false when the insights equal the last ones returned for `id`,
    /// so the caller needn't compare them (slow at thousands of lines).
    func analyze(_ snapshot: ReviewSnapshot, git: ReviewGit, parse: Bool,
                 for id: Session.ID) async -> (DiffAnalysis, [String: FileInsight], changed: Bool) {
        let files = parse ? snapshot.files.filter {
            !$0.isBinary && $0.lineCount <= ReviewAnalysis.maxFileLines && CodeLanguage.forPath($0.path) != nil
        } : []
        // Old sides already parsed are kept; the rest come from git (async).
        let (generation, hits, fetch): (Int, [String: ParsedSource], [FileDiff]) = await onQueue {
            guard !files.isEmpty, self.loadParser() else { return (self.generation, [:], []) }
            var hits: [String: ParsedSource] = [:], fetch: [FileDiff] = []
            for file in files where file.status != .added {
                let key = Self.oldKey(file, snapshot.point)
                if let hit = self.cache[key] { hits[key] = hit } else { fetch.append(file) }
            }
            return (self.generation, hits, fetch)
        }
        var oldTexts: [String: String] = [:]
        for file in fetch {
            oldTexts[file.path] = await git.file(at: snapshot.point, path: file.oldPath ?? file.path, root: snapshot.root)
        }
        let fetched = oldTexts
        return await onQueue {
            let (analysis, insights, allCached) = self.work(snapshot, files, hits, fetched, generation, words: parse)
            let same = allCached && self.last.map { $0.id == id && $0.parse == parse && $0.snapshot == snapshot } ?? false
            if self.generation == generation { self.last = (id, snapshot, parse) }
            return (analysis, insights, !same)
        }
    }

    /// Token colours for lines of a file's new side outside its hunks (revealed by the
    /// expanders), from the snapshot's parse when cached, else parsed now and kept with it.
    func highlight(_ lines: [String], numbers: [Int], path: String, hash: String) async -> [Int: AttributedString] {
        guard let language = CodeLanguage.forPath(path) else { return [:] }
        return await onQueue {
            guard self.loadParser(), let parser = self.parser else { return [:] }
            let key = "\(language.rawValue):\(hash)"
            let parsed: ParsedSource
            if let hit = self.cache[key] {
                parsed = hit
            } else {
                let text = lines.joined(separator: "\n") + "\n"
                guard text.utf8.count <= Self.maxBytes else { return [:] }
                parsed = parser.parse(text, language)
                self.cache[key] = parsed
            }
            var out: [Int: AttributedString] = [:]
            for n in numbers where lines.indices.contains(n - 1) {
                out[n] = Self.highlight(lines[n - 1], parsed.highlights[n] ?? [])
            }
            return out
        }
    }

    /// Compiles every language's queries ahead of the first parse.
    func prewarm() {
        queue.async { if self.loadParser() { self.parser?.prepare() } }
    }

    func clear() {
        queue.async {
            self.cache = [:]
            self.last = nil
            self.generation += 1
        }
    }

    // MARK: - On the queue

    private func work(_ snapshot: ReviewSnapshot, _ files: [FileDiff], _ hits: [String: ParsedSource],
                      _ oldTexts: [String: String], _ started: Int,
                      words: Bool) -> (DiffAnalysis, [String: FileInsight], allCached: Bool) {
        let analysis = ReviewAnalysis.analyze(snapshot.files)
        guard let parser, !files.isEmpty else {
            var insights: [String: FileInsight] = [:]
            if words { Self.markWords(snapshot.files, analysis, in: &insights, budget: Self.maxHighlightedLines) }
            return (analysis, insights, true)
        }
        var used: [String: ParsedSource] = [:]
        var allCached = true
        func parsed(_ key: String?, _ language: CodeLanguage, _ text: () -> String?) -> ParsedSource? {
            if let key, let hit = used[key] ?? hits[key] ?? cache[key] { used[key] = hit; return hit }
            allCached = false
            guard let text = text(), text.utf8.count <= Self.maxBytes else { return nil }
            let result = parser.parse(text, language)
            if let key { used[key] = result }
            return result
        }
        let empty = ParsedSource(symbols: [], highlights: [:])
        var insights: [String: FileInsight] = [:]
        var changes: [String: [SymbolChange]] = [:]
        var oldSymbols: [String: [CodeSymbol]] = [:], newSymbols: [String: [CodeSymbol]] = [:]
        var highlighted = 0
        for file in files {
            guard let language = CodeLanguage.forPath(file.path) else { continue }
            let newKey = snapshot.hashes[file.path].map { "\(language.rawValue):\($0)" }
            let old = file.status == .added ? empty
                : parsed(Self.oldKey(file, snapshot.point), language, { oldTexts[file.path] })
            let new = file.status == .deleted ? empty
                : parsed(newKey, language, { Self.workingCopy(snapshot.root + "/" + file.path) })
            // Without both sides there are no symbols, but the side we have is still highlighted.
            guard old != nil || new != nil else { continue }

            var insight = FileInsight()
            var changedOld = Set<Int>(), changedNew = Set<Int>()
            let colour = highlighted < Self.maxHighlightedLines
            for line in file.hunks.flatMap(\.lines) {
                switch line.kind {
                case .removed:
                    guard let n = line.oldNumber else { continue }
                    changedOld.insert(n)
                    if colour, let old { insight.oldLines[n] = Self.highlight(line.text, old.highlights[n] ?? []) }
                case .added:
                    guard let n = line.newNumber else { continue }
                    changedNew.insert(n)
                    if colour, let new { insight.newLines[n] = Self.highlight(line.text, new.highlights[n] ?? []) }
                case .context:
                    // Once, from the new side (or the old one without it); both columns show it.
                    guard colour, let n = line.newNumber, let o = line.oldNumber else { continue }
                    if let new { insight.newLines[n] = Self.highlight(line.text, new.highlights[n] ?? []) }
                    else if let old { insight.newLines[n] = Self.highlight(line.text, old.highlights[o] ?? []) }
                }
            }
            highlighted += insight.oldLines.count + insight.newLines.count
            insights[file.path] = insight
            guard let old, let new else { continue }
            changes[file.path] = SymbolDiff.compare(old: old.symbols, new: new.symbols, changedOld: changedOld, changedNew: changedNew)
            oldSymbols[file.path] = old.symbols
            newSymbols[file.path] = new.symbols
        }
        for (path, symbols) in SymbolDiff.linkMoves(changes, old: oldSymbols, new: newSymbols) {
            insights[path]?.symbols = symbols
        }
        Self.markWords(snapshot.files, analysis, in: &insights, budget: Self.maxHighlightedLines - highlighted)
        if generation == started { cache = used }
        return (analysis, insights, allCached)
    }

    private func loadParser() -> Bool {
        if !triedParser {
            triedParser = true
            if let url = Bundle.main.resourceURL?.appendingPathComponent("tree-sitter-queries"),
               FileManager.default.fileExists(atPath: url.path) {
                parser = CodeParser(queries: url)
            } else {
                Log.app.error("tree-sitter queries missing from the app bundle; review shows plain diffs")
            }
        }
        return parser != nil
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: work()) } }
    }

    // MARK: - Helpers

    private static func oldKey(_ file: FileDiff, _ point: String) -> String {
        "\(CodeLanguage.forPath(file.path)?.rawValue ?? ""):\(point):\(file.oldPath ?? file.path)"
    }

    /// Lossy UTF-8; nil if missing or over the size limit.
    private static func workingCopy(_ path: String) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= maxBytes,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `simul-name:<name>`, percent-encoded.
    static func nameURL(_ name: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "simul-name"
        parts.path = name
        return parts.url
    }

    private static let followed: Set<TokenKind> = [.function, .type, .variable, .property, .constant]
    /// Words some queries tag as variables or constants that aren't worth following.
    private static let keywords: Set<String> = [
        "self", "cls", "this", "super", "None", "True", "False", "null", "undefined", "true", "false",
        "NaN", "Infinity", "arguments", "require", "module", "exports",
    ]

    /// Marks the changed words of each removed/added pair the split view draws side by side (unified marks
    /// the same ones); moved and whitespace-only lines keep their own treatment. Lines it adds that weren't
    /// highlighted count against `budget`.
    private static func markWords(_ files: [FileDiff], _ analysis: DiffAnalysis, in insights: inout [String: FileInsight],
                                  budget: Int) {
        var budget = budget
        for file in files where !file.isBinary && file.lineCount <= ReviewAnalysis.maxFileLines {
            for (h, hunk) in file.hunks.enumerated() {
                let note = { (i: Int) in analysis.notes[LineRef(path: file.path, hunk: h, index: i)] }
                for case let .pair(l?, r?) in hunk.rows(split: true, note: note, isOpen: { _ in true }) {
                    let old = hunk.lines[l], new = hunk.lines[r]
                    guard old.kind == .removed, new.kind == .added, note(l) == nil, note(r) == nil,
                          let o = old.oldNumber, let n = new.newNumber else { continue }
                    // Just the two lines, then in place: holding a copy of the insight would copy its dictionaries.
                    let left = insights[file.path]?.oldLines[o], right = insights[file.path]?.newLines[n]
                    let fresh = (left == nil ? 1 : 0) + (right == nil ? 1 : 0)
                    guard fresh <= budget, let words = WordDiff.changes(old: old.text, new: new.text) else { continue }
                    budget -= fresh
                    insights[file.path, default: FileInsight()].oldLines[o] =
                        mark(left ?? AttributedString(old.text), words.old, .removed)
                    insights[file.path, default: FileInsight()].newLines[n] =
                        mark(right ?? AttributedString(new.text), words.new, .added)
                }
            }
        }
    }

    private static func mark(_ line: AttributedString, _ ranges: [Range<Int>], _ kind: DiffLine.Kind) -> AttributedString {
        var line = line
        let count = line.characters.count
        for range in ranges where range.upperBound <= count {
            let lower = line.index(line.startIndex, offsetByCharacters: range.lowerBound)
            let upper = line.index(line.startIndex, offsetByCharacters: range.upperBound)
            line[lower..<upper][WordChangeAttribute.self] = kind
        }
        return line
    }

    /// The line with its token kinds, its followable names as `simul-name:` links
    /// (the row gives uncoloured ones the text colour, or Text draws them in the accent colour).
    private static func highlight(_ text: String, _ spans: [HighlightSpan]) -> AttributedString {
        var result = AttributedString(text)
        let count = result.characters.count
        for span in spans where span.range.lowerBound < count {
            let lower = result.index(result.startIndex, offsetByCharacters: span.range.lowerBound)
            let upper = result.index(result.startIndex, offsetByCharacters: min(span.range.upperBound, count))
            let coloured = ReviewPalette().token(span.kind) != nil
            if coloured { result[lower..<upper][TokenKindAttribute.self] = span.kind }
            guard followed.contains(span.kind) else { continue }
            let name = String(result[lower..<upper].characters)
            if name.count >= 2, !keywords.contains(name),
               name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) {
                result[lower..<upper].link = nameURL(name)
            }
        }
        return result
    }
}
