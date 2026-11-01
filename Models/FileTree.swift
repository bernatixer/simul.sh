import Foundation

/// The review's file tree, as GitHub's: folders first then files, each by name,
/// and a folder holding only one folder shown as one ("app/services/ai").
struct FileTreeRow: Equatable, Identifiable {
    /// The file's path; a folder's path ends in "/" (a file and folder can share a name).
    let id: String
    let name: String
    let depth: Int
    let isFolder: Bool

    /// The folder's path without its "/"; a file's path.
    var path: String { isFolder ? String(id.dropLast()) : id }
}

enum FileTree {
    static func rows(_ paths: [String]) -> [FileTreeRow] {
        let root = Node()
        for path in paths {
            var node = root
            let parts = path.split(separator: "/").map(String.init)
            for folder in parts.dropLast() {
                if node.folders[folder] == nil { node.folders[folder] = Node() }
                node = node.folders[folder]!
            }
            node.files.append(path)
        }
        var rows: [FileTreeRow] = []
        func emit(_ node: Node, prefix: String, depth: Int) {
            for name in node.folders.keys.sorted(by: Self.before) {
                var label = name, child = node.folders[name]!, path = prefix + name
                while child.files.isEmpty, child.folders.count == 1, let (next, grandchild) = child.folders.first {
                    label += "/" + next
                    path += "/" + next
                    child = grandchild
                }
                rows.append(FileTreeRow(id: path + "/", name: label, depth: depth, isFolder: true))
                emit(child, prefix: path + "/", depth: depth + 1)
            }
            for file in node.files.sorted(by: Self.before) {
                rows.append(FileTreeRow(id: file, name: (file as NSString).lastPathComponent, depth: depth, isFolder: false))
            }
        }
        emit(root, prefix: "", depth: 0)
        return rows
    }

    /// The files in tree order.
    static func order(_ paths: [String]) -> [String] {
        rows(paths).filter { !$0.isFolder }.map(\.id)
    }

    private static func before(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    private final class Node {
        var folders: [String: Node] = [:]
        var files: [String] = []
    }
}
