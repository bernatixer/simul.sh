import Foundation

/// Branch and worktree of a directory, read straight from `.git` files —
/// no `git` process, cheap enough to poll.
struct GitInfo: Equatable {
    /// Branch name, or a short SHA when HEAD is detached.
    var branch: String
    /// Linked worktree name; nil for the main checkout.
    var worktree: String?

    static func read(directory: String) -> GitInfo? {
        let fileManager = FileManager.default
        var dir = URL(fileURLWithPath: directory).standardizedFileURL
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                var gitDir = dotGit
                var worktree: String?
                if !isDirectory.boolValue {
                    // Linked worktree (or submodule): ".git" is "gitdir: <path>".
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first,
                          line.hasPrefix("gitdir: ") else { return nil }
                    gitDir = URL(fileURLWithPath: String(line.dropFirst(8)), relativeTo: dir)
                        .standardizedFileURL
                    if gitDir.deletingLastPathComponent().lastPathComponent == "worktrees" {
                        worktree = gitDir.lastPathComponent
                    }
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                else { return nil }
                let ref = head.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "ref: refs/heads/"
                let branch = ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : String(ref.prefix(7))
                return GitInfo(branch: branch, worktree: worktree)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }
}
