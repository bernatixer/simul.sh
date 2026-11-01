import Foundation

/// The processes workflow stages run: the user's check commands (in their
/// login shell), git, and gh. All off the main thread.
struct WorkflowTools: Sendable {
    let shell: String
    let gh: String?
    let environment: [String: String]
    private let git = "/usr/bin/git"

    init(shell: String, gh: String?, environment: [String: String]) {
        self.shell = shell
        self.gh = gh
        self.environment = environment
    }

    struct Output: Sendable {
        var exitCode: Int32
        var output: String
        var errors = ""
        var timedOut = false
    }

    /// `command` in the user's login shell, in `folder`; stdout and stderr
    /// together, at most the last `keep` lines. Killed after `timeout`.
    func runShell(_ command: String, in folder: String, timeout: TimeInterval, keep: Int = 80) async -> Output {
        var result = await run(shell, ["-lc", command], in: folder, timeout: timeout, together: true)
        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false)
        result.output = lines.suffix(keep).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// Runs `executable` with its output going to files, not pipes: a child
    /// it leaves behind (a server started in the background) can't keep this
    /// waiting. After `timeout` it and everything it started are stopped.
    private func run(_ executable: String, _ arguments: [String], in folder: String, timeout: TimeInterval,
                     together: Bool = false) async -> Output {
        let env = environment
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let dir = FileManager.default.temporaryDirectory
                let outURL = dir.appendingPathComponent("simul-\(UUID().uuidString).out")
                let errURL = together ? outURL : dir.appendingPathComponent("simul-\(UUID().uuidString).err")
                FileManager.default.createFile(atPath: outURL.path, contents: nil)
                FileManager.default.createFile(atPath: errURL.path, contents: nil)
                defer {
                    try? FileManager.default.removeItem(at: outURL)
                    try? FileManager.default.removeItem(at: errURL)
                }
                guard let out = try? FileHandle(forWritingTo: outURL), let err = together ? out : try? FileHandle(forWritingTo: errURL) else {
                    return cont.resume(returning: Output(exitCode: 127, output: "", errors: "Can't create output files"))
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: folder)
                var merged = ProcessInfo.processInfo.environment
                env.forEach { merged[$0.key] = $0.value }
                process.environment = merged
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                let exited = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in exited.signal() }
                do { try process.run() } catch {
                    return cont.resume(returning: Output(exitCode: 127, output: "", errors: String(describing: error)))
                }
                var timedOut = false
                if exited.wait(timeout: .now() + timeout) == .timedOut {
                    timedOut = true
                    // Everything it started, found once: after SIGTERM some may already be orphaned.
                    let pids = Self.descendants(of: process.processIdentifier) + [process.processIdentifier]
                    pids.forEach { kill($0, SIGTERM) }
                    _ = exited.wait(timeout: .now() + 5)
                    pids.forEach { kill($0, SIGKILL) }
                    _ = exited.wait(timeout: .now() + 5)
                }
                try? out.close()
                if !together { try? err.close() }
                // ponytail: reads whole outputs; a command printing gigabytes would be read whole too.
                let stdout = (try? Data(contentsOf: outURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                let stderr = together ? "" : (try? Data(contentsOf: errURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                cont.resume(returning: Output(exitCode: timedOut ? -1 : process.terminationStatus, output: stdout,
                                              errors: stderr, timedOut: timedOut))
            }
        }
    }

    /// Every process under `pid`, deepest first.
    private static func descendants(of pid: Int32) -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        try? pgrep.run()
        let children = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { Int32($0) }
        pgrep.waitUntilExit()
        return children.flatMap { descendants(of: $0) + [$0] }
    }

    // MARK: git

    func git(_ args: [String], in folder: String) async -> String? {
        let result = await run(git, args, in: folder, timeout: 120)
        guard result.exitCode == 0 else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func head(_ folder: String) async -> String? { await git(["rev-parse", "HEAD"], in: folder) }

    /// The working tree as a commit, without touching it or the index
    /// (`git stash create`); HEAD when there's nothing uncommitted.
    /// ponytail: untracked files aren't in it, so a fix that only adds new files looks empty.
    func snapshotTree(_ folder: String) async -> String? {
        if let stash = await git(["stash", "create"], in: folder), !stash.isEmpty { return stash }
        return await head(folder)
    }

    func diff(from: String, to: String, in folder: String) async -> String {
        await git(["diff", "--no-color", "--no-ext-diff", from, to], in: folder) ?? ""
    }

    /// Where the change starts: the merge base with `base` ("origin/main"),
    /// else with origin's default branch, main or master; HEAD if none.
    func mergePoint(_ folder: String, base: String? = nil) async -> String {
        var candidates: [String] = []
        if let base { candidates.append(base) }
        if let remoteHead = await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: folder) {
            candidates.append(remoteHead)
        }
        candidates += ["origin/main", "origin/master", "main", "master"]
        for candidate in candidates {
            if let point = await git(["merge-base", "HEAD", candidate], in: folder), !point.isEmpty { return point }
        }
        return "HEAD"
    }

    /// Lines added plus removed since `point`, uncommitted work included.
    func diffLines(_ folder: String, since point: String) async -> Int {
        guard let stat = await git(["diff", "--numstat", point], in: folder) else { return 0 }
        return stat.split(separator: "\n").reduce(0) { sum, line in
            let parts = line.split(separator: "\t")
            return sum + (parts.count >= 2 ? (Int(parts[0]) ?? 0) + (Int(parts[1]) ?? 0) : 0)
        }
    }

    // MARK: GitHub

    struct GitHubError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func ghRun(_ args: [String], in folder: String) async throws -> Data {
        guard let gh else { throw GitHubError(message: "GitHub CLI (gh) isn't installed") }
        let result = await run(gh, args, in: folder, timeout: 90)
        guard result.exitCode == 0 else {
            let message = result.timedOut ? "GitHub didn't answer in time" : result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubError(message: message.isEmpty ? "gh failed (\(result.exitCode))" : String(message.prefix(300)))
        }
        return Data(result.output.utf8)
    }

    /// `pr`: a number or link; empty for the current branch's pull request.
    func pullRequest(_ pr: String, in folder: String) async throws -> PullRequestStatus {
        var args = ["pr", "view", "--json", PullRequestStatus.ghFields]
        let target = pr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.isEmpty { args += ["--", target] }
        return try PullRequestStatus.decode(ghJSON: try await ghRun(args, in: folder))
    }

    func threads(repo: String, number: Int, in folder: String) async throws -> [ReviewThread] {
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else { throw GitHubError(message: "Unexpected repository \(repo)") }
        let data = try await ghRun(["api", "graphql", "-f", "query=\(ReviewThread.query)",
                                    "-F", "owner=\(parts[0])", "-F", "name=\(parts[1])", "-F", "number=\(number)"], in: folder)
        return try ReviewThread.decode(graphQL: data)
    }
}

