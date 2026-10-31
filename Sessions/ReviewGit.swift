import CryptoKit
import Foundation

struct ReviewSnapshot: Equatable {
    let root: String
    let base: String
    let point: String              // the commit (or empty tree) the diff is against
    let files: [FileDiff]
    let hashes: [String: String]   // path -> git hash-object of the working copy; "deleted" for deletions, "submodule:<commit>" for submodules
    /// Changes whenever the diff could (AgentOverview staleness); made once here.
    let fingerprint: String

    init(root: String, base: String, point: String, files: [FileDiff], hashes: [String: String]) {
        (self.root, self.base, self.point, self.files, self.hashes) = (root, base, point, files, hashes)
        fingerprint = Self.fingerprint(point: point, hashes: hashes)
    }
}

/// A line elsewhere in the repo that uses a followed name.
struct NameUse: Identifiable, Sendable, Equatable {
    let path: String
    let line: Int
    let text: String
    var id: String { "\(path):\(line)" }
}

extension String {
    /// Character offsets of `word` where it stands alone, with git grep -w's word characters ([A-Za-z0-9_]).
    func wordOffsets(of word: String) -> [Range<Int>] {
        guard !word.isEmpty else { return [] }
        let isWord = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber || c == "_") }
        var result: [Range<Int>] = [], from = startIndex, offset = 0   // offset: Characters before `from`
        while let r = range(of: word, range: from..<endIndex) {
            let lower = offset + distance(from: from, to: r.lowerBound)
            let upper = lower + distance(from: r.lowerBound, to: r.upperBound)
            (from, offset) = (r.upperBound, upper)
            if r.lowerBound > startIndex, isWord(self[index(before: r.lowerBound)]) { continue }
            if r.upperBound < endIndex, isWord(self[r.upperBound]) { continue }
            result.append(lower..<upper)
        }
        return result
    }
}

enum ReviewGitError: Error, Equatable { case notARepository(String), gitFailed(String) }

private final class Box: @unchecked Sendable { var value = false }

/// Read-only git queries for the review view. Never touches the repo's real index.
struct ReviewGit {
    let git: String
    let gh: String?
    let environment: [String: String]

    func snapshot(folder: String, baseOverride: String?) async throws -> ReviewSnapshot {
        let top = await run(["rev-parse", "--show-toplevel"], in: folder)
        let root = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard top.exitCode == 0, !root.isEmpty else { throw ReviewGitError.notARepository(folder) }

        let base: String
        if let baseOverride {
            guard !baseOverride.hasPrefix("-"), await resolves(baseOverride, root: root) else {
                throw ReviewGitError.gitFailed("unknown base: \(baseOverride)")
            }
            base = baseOverride
        } else { base = await resolveBase(root: root) }
        var point = "HEAD"
        if !(await resolves("HEAD", root: root)) {
            // Unborn branch (no commits yet): everything is new against the empty tree.
            point = await out(["hash-object", "-t", "tree", "/dev/null"], in: root) ?? "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        } else if base != "HEAD" { point = await out(["merge-base", "--end-of-options", "HEAD", base], in: root) ?? base }

        // Mark untracked files intent-to-add in a throwaway copy of the index.
        var indexPath = await out(["rev-parse", "--git-path", "index"], in: root) ?? ".git/index"
        if !indexPath.hasPrefix("/") { indexPath = root + "/" + indexPath }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("simul-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try? FileManager.default.copyItem(atPath: indexPath, toPath: temp.path)  // fresh repo: no index yet
        let env = environment.merging(["GIT_INDEX_FILE": temp.path]) { $1 }

        let add = await run(["add", "--intent-to-add", "--all"], in: root, env: env)
        guard add.exitCode == 0 else { throw ReviewGitError.gitFailed(add.stderr) }
        // -U3: the hunks GitHub shows, whatever the user's diff.context says.
        let diff = await run(["diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "-U3", "-M", "--end-of-options", point], in: root, env: env)
        guard diff.exitCode == 0 else { throw ReviewGitError.gitFailed(diff.stderr) }
        let files = UnifiedDiff.parse(diff.stdout)

        var hashes: [String: String] = [:]
        // Only regular files (or symlinks to one) can be hashed; one directory, submodule or dangling
        // symlink would fail the whole call. Submodules use their new-side commit from the diff
        // ("…-dirty" with local changes); anything else gets no hash and can't be marked viewed.
        let live = files.filter { file in
            var isDirectory: ObjCBool = false
            return file.status != .deleted
                && FileManager.default.fileExists(atPath: root + "/" + file.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }.map(\.path)
        for file in files where file.status == .deleted { hashes[file.path] = "deleted" }
        let subproject = "Subproject commit "
        for file in files where file.status != .deleted && !live.contains(file.path) {
            let lines = file.hunks.flatMap(\.lines)
            if let line = lines.last(where: { $0.kind == .added && $0.text.hasPrefix(subproject) }) {
                hashes[file.path] = "submodule:" + line.text.dropFirst(subproject.count)
            }
        }
        if !live.isEmpty {
            let hashed = await run(["hash-object", "--"] + live, in: root)
            let ids = hashed.stdout.split(separator: "\n").map(String.init)
            if hashed.exitCode == 0, ids.count == live.count { hashes.merge(zip(live, ids)) { $1 } }
        }
        return ReviewSnapshot(root: root, base: base, point: point, files: files, hashes: hashes)
    }

    /// `git hash-object` of content: SHA-1 of "blob <size>\0" + content (clean filters aside).
    static func blobID(_ data: Data) -> String {
        Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data).map { String(format: "%02x", $0) }.joined()
    }

    /// Current working-copy lines of a file, for anchoring comments. None
    /// unless it is a regular file of at most `maxBytes` inside `root` once
    /// symlinks are resolved (agents name these paths).
    func fileLines(root: String, path: String, maxBytes: Int = 2 << 20) async -> [String] {
        func real(_ p: String) -> String? {
            guard let r = realpath(p, nil) else { return nil }
            defer { free(r) }
            return String(cString: r)
        }
        guard let top = real(root), let file = real(root + "/" + path), file.hasPrefix(top.hasSuffix("/") ? top : top + "/"),
              let values = try? URL(fileURLWithPath: file).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= maxBytes,
              let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
    }

    /// A file's raw content at `point` (lossy UTF-8, no textconv); nil if it isn't there or git fails.
    func file(at point: String, path: String, root: String) async -> String? {
        let result = await run(["cat-file", "blob", "--end-of-options", point + ":" + path], in: root)
        return result.exitCode == 0 ? result.stdout : nil
    }

    /// Diff of a previously viewed copy of a file against the working copy, with paths rewritten to `path`.
    func diffSince(viewedContent: URL, root: String, path: String) async -> [FileDiff] {
        let result = await run(["diff", "--no-index", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", viewedContent.path, root + "/" + path], in: root)
        guard result.exitCode == 1 else { return [] }  // 1: differs; 0 same, >1 failure (errors can exit 1 too, then the parse yields nothing)
        return UnifiedDiff.parse(result.stdout).map {
            FileDiff(path: path, oldPath: $0.oldPath == nil ? nil : path, status: $0.status,
                     isBinary: $0.isBinary, hunks: $0.hunks)
        }
    }

    /// Whole-word lines using `name` in the working copy's tracked text files, minus
    /// the lines `files` add (they're in the diff already); at most `limit`, `more` if there were others.
    func uses(of name: String, root: String, files: [FileDiff], limit: Int = 200) async -> (uses: [NameUse], more: Bool) {
        // ponytail: reads every match before trimming to `limit`; a very common name in a huge repo costs memory.
        let result = await run(["grep", "-n", "-w", "-F", "-I", "-z", "--no-color", "--end-of-options", name], in: root)
        guard result.exitCode == 0 else { return ([], false) }  // 1: no matches
        var changed: [String: Set<Int>] = [:]
        for file in files {
            changed[file.path] = Set(file.hunks.flatMap(\.lines).compactMap { $0.kind == .added ? $0.newNumber : nil })
        }
        var uses: [NameUse] = []
        // -z: "path\0line\0text\n", so paths with ':' parse.
        // "\r\n" is one Character in Swift: split on it too (CRLF files).
        for record in result.stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let fields = record.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let line = Int(fields[1]) else { continue }
            let path = String(fields[0])
            if changed[path]?.contains(line) == true { continue }
            if uses.count == limit { return (uses, true) }
            uses.append(NameUse(path: path, line: line, text: String(fields[2])))
        }
        return (uses, false)
    }

    // MARK: - Base resolution

    private func resolveBase(root: String) async -> String {
        if let name = await prBaseName(root: root) {
            if await resolves("origin/" + name, root: root) { return "origin/" + name }
            if await resolves(name, root: root) { return name }
        }
        if let head = await out(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: root),
           await resolves(head, root: root) { return head }
        for name in ["main", "master"] where await resolves(name, root: root) { return name }
        return "HEAD"
    }

    private func prBaseName(root: String) async -> String? {
        guard let gh, let result = await runGH(gh, ["pr", "view", "--json", "baseRefName", "-q", ".baseRefName"], root: root, seconds: 5) else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && !name.isEmpty ? name : nil
    }

    func resolves(_ ref: String, root: String) async -> Bool {
        await run(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: root).exitCode == 0
    }

    // MARK: - Helpers

    /// Runs gh, racing it against a timer; nil on timeout (a hung gh is left to finish on its own).
    func runGH(_ gh: String, _ args: [String], root: String, seconds: UInt64) async -> ProcessRunner.Result? {
        let environment = environment
        return await withCheckedContinuation { cont in
            let once = NSLock(), done = Box()
            @Sendable func finish(_ value: ProcessRunner.Result?) {
                once.lock(); defer { once.unlock() }
                if !done.value { done.value = true; cont.resume(returning: value) }
            }
            Task { finish(await ProcessRunner.run(gh, arguments: args, environment: environment, workingDirectory: root)) }
            Task { try? await Task.sleep(nanoseconds: seconds * 1_000_000_000); finish(nil) }
        }
    }

    func run(_ args: [String], in dir: String, env: [String: String]? = nil) async -> ProcessRunner.Result {
        await ProcessRunner.run(git, arguments: ["-c", "core.quotepath=off", "--no-pager"] + args,
                                environment: env ?? environment, workingDirectory: dir)
    }

    /// Trimmed stdout, nil on failure or empty output.
    func out(_ args: [String], in dir: String) async -> String? {
        let r = await run(args, in: dir)
        let text = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.exitCode == 0 && !text.isEmpty ? text : nil
    }
}

extension ReviewGit {
    /// What `rev` has at `paths` (exact paths): path -> blob or submodule commit id.
    func objects(at rev: String, paths: [String], root: String) async throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }  // no paths would list the whole tree
        let r = await run(["ls-tree", "-r", "-z", "--full-tree", "--end-of-options", rev] + paths, in: root)
        guard r.exitCode == 0 else { throw ReviewGitError.gitFailed(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return GitHubReview.parseLsTree(r.stdout)
    }

    /// The file's lines at `rev` (lossy UTF-8, split like `fileLines`); nil if it has no such file.
    func lines(at rev: String, path: String, root: String) async -> [String]? {
        let r = await run(["cat-file", "blob", "--end-of-options", "\(rev):\(path)"], in: root)
        return r.exitCode == 0 ? r.stdout.components(separatedBy: "\n") : nil
    }

    /// Posts a PR review with `gh api` (the JSON in a private temp file, removed after).
    func postReview(_ payload: GitHubReviewPayload, repo: String, number: Int, root: String) async throws {
        guard let gh else { throw ReviewGitError.gitFailed(Self.ghUnavailable) }
        // repo goes into the API path: "owner/name" only.
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
            && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }) else {
            throw ReviewGitError.gitFailed("Not a GitHub repository: \(repo)")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("simul-review-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: file.path, contents: try JSONEncoder().encode(payload),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ReviewGitError.gitFailed("Couldn't write the review to a temporary file")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let args = ["api", "--method", "POST", "repos/\(repo)/pulls/\(number)/reviews", "--input", file.path]
        guard let r = await runGH(gh, args, root: root, seconds: 30) else {
            throw ReviewGitError.gitFailed("GitHub didn't answer in time. Check the pull request before submitting again.")
        }
        guard r.exitCode == 0 else {
            throw ReviewGitError.gitFailed(GitHubReview.errorMessage(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode))
        }
    }
}
