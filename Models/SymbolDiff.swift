import Foundation

struct SymbolChange: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case changed, added, deleted, renamed(from: String), moved(from: String), formatting }
    let name: String
    let kind: Kind
    let newLines: ClosedRange<Int>?   // nil for deleted
    let oldLines: ClosedRange<Int>?   // nil for added
}

enum SymbolDiff {
    /// One file. Only symbols touching changed lines are reported.
    static func compare(old: [CodeSymbol], new: [CodeSymbol], changedOld: Set<Int>, changedNew: Set<Int>) -> [SymbolChange] {
        func touches(_ r: ClosedRange<Int>, _ lines: Set<Int>) -> Bool { r.contains { lines.contains($0) } }
        let oldByName = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let newNames = Set(new.map(\.name))
        var out: [SymbolChange] = []
        var unmatchedNew: [CodeSymbol] = []
        for n in new {
            guard let o = oldByName[n.name] else { unmatchedNew.append(n); continue }
            if o.rawHash == n.rawHash { continue }
            guard touches(n.lines, changedNew) || touches(o.lines, changedOld) else { continue }
            out.append(SymbolChange(name: n.name, kind: o.shapeHash == n.shapeHash ? .formatting : .changed,
                                    newLines: n.lines, oldLines: o.lines))
        }
        var unmatchedOld = old.filter { !newNames.contains($0.name) }
        for n in unmatchedNew {
            if let i = unmatchedOld.firstIndex(where: { $0.shapeHash == n.shapeHash }) {
                let o = unmatchedOld.remove(at: i)
                out.append(SymbolChange(name: n.name, kind: .renamed(from: o.name), newLines: n.lines, oldLines: o.lines))
            } else {
                out.append(SymbolChange(name: n.name, kind: .added, newLines: n.lines, oldLines: nil))
            }
        }
        out += unmatchedOld.map { SymbolChange(name: $0.name, kind: .deleted, newLines: nil, oldLines: $0.lines) }
        // A class edit or rename is implied by its members' own entries.
        let classKinds = Dictionary(new.map { ($0.name, $0.kind) }, uniquingKeysWith: { a, _ in a })
        let renamedClasses: [(old: String, new: String)] = out.compactMap {
            if case .renamed(let from) = $0.kind, classKinds[$0.name] == .class { return (from, $0.name) }
            return nil
        }
        let names = out.map(\.name)
        out = out.filter { c in
            switch c.kind {
            case .changed, .formatting:
                return classKinds[c.name] != .class || !names.contains { $0.hasPrefix(c.name + ".") }
            case .renamed(let from):
                return !renamedClasses.contains { from.hasPrefix($0.old + ".") && c.name.hasPrefix($0.new + ".")
                    && from.dropFirst($0.old.count) == c.name.dropFirst($0.new.count) }
            default: return true
            }
        }
        return sorted(out)
    }

    /// Across files: an added symbol in one file whose shapeHash equals a deleted one in another → moved(from: "<oldPath>").
    static func linkMoves(_ byPath: [String: [SymbolChange]], old: [String: [CodeSymbol]], new: [String: [CodeSymbol]]) -> [String: [SymbolChange]] {
        func hash(_ path: String, _ name: String, in symbols: [String: [CodeSymbol]]) -> Int? {
            symbols[path]?.first { $0.name == name }?.shapeHash
        }
        let paths = byPath.keys.sorted()
        var deleted: [(path: String, change: SymbolChange, hash: Int)] = []
        for path in paths {
            for c in byPath[path]! where c.kind == .deleted {
                if let h = hash(path, c.name, in: old) { deleted.append((path, c, h)) }
            }
        }
        var result = byPath
        var removed: [String: [SymbolChange]] = [:]
        for path in paths {
            var list = byPath[path]!
            for (i, c) in list.enumerated() where c.kind == .added {
                guard let h = hash(path, c.name, in: new),
                      let j = deleted.firstIndex(where: { $0.hash == h && $0.path != path }) else { continue }
                let d = deleted.remove(at: j)
                list[i] = SymbolChange(name: c.name, kind: .moved(from: d.path), newLines: c.newLines, oldLines: d.change.oldLines)
                removed[d.path, default: []].append(d.change)
            }
            result[path] = list
        }
        for (path, gone) in removed {
            result[path] = result[path]!.filter { !gone.contains($0) }
        }
        return result.mapValues(sorted)
    }

    /// changed, added, deleted, renamed, moved, formatting; by line within a kind.
    private static func sorted(_ changes: [SymbolChange]) -> [SymbolChange] {
        func rank(_ k: SymbolChange.Kind) -> Int {
            switch k {
            case .changed: 0
            case .added: 1
            case .deleted: 2
            case .renamed: 3
            case .moved: 4
            case .formatting: 5
            }
        }
        func line(_ c: SymbolChange) -> Int { (c.newLines ?? c.oldLines)?.lowerBound ?? 0 }
        return changes.sorted { (rank($0.kind), line($0), $0.name) < (rank($1.kind), line($1), $1.name) }
    }
}
