import Foundation

/// Persistence format:
///
///     { "version": 1, "runs": [WorkflowRun] }
///
/// Same rules as SessionStore: atomic writes, previous copy kept as
/// runs.json.prev, a corrupt file falls back to it.
struct RunStoreSnapshot: Codable {
    var version: Int
    var runs: [WorkflowRun]

    static let currentVersion = 1
}

final class RunStore: @unchecked Sendable {
    private let fileURL: URL
    private let backupURL: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL = Paths.runsFile, backupURL: URL = Paths.runsBackupFile) {
        self.fileURL = fileURL
        self.backupURL = backupURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Set when the file is from a newer Simul: saving would lose its runs.
    private(set) var readOnly = false

    func load() -> [WorkflowRun] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        if let runs = try? read(fileURL) { return runs }
        Log.store.error("failed to load \(self.fileURL.path, privacy: .public); trying the backup")
        return (try? read(backupURL)) ?? []
    }

    func save(_ runs: [WorkflowRun]) {
        guard !readOnly else { return }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(RunStoreSnapshot(version: RunStoreSnapshot.currentVersion, runs: runs))
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: backupURL)
                try? fileManager.copyItem(at: fileURL, to: backupURL)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.store.error("failed to save runs: \(String(describing: error), privacy: .public)")
        }
    }

    /// Run by run: one that can't be read (say, a stage kind from a newer
    /// Simul) is left out instead of losing them all.
    private func read(_ url: URL) throws -> [WorkflowRun] {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["runs"] as? [Any] else { throw CocoaError(.fileReadCorruptFile) }
        guard root["version"] as? Int == RunStoreSnapshot.currentVersion else {
            Log.store.warning("runs.json is from another version of Simul: not reading or overwriting it")
            readOnly = true
            return []
        }
        return list.compactMap { item in
            guard let one = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            do { return try decoder.decode(WorkflowRun.self, from: one) } catch {
                Log.store.error("skipping a run that can't be read: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }
}

/// The user's workflows: `<data dir>/workflows/*.json`, each a Workflow.
enum WorkflowLibrary {
    struct Entry: Identifiable, Equatable {
        var id: String { file.path }
        var file: URL
        var workflow: Workflow?
        /// Why it can't run; empty when it can.
        var problems: [String]
    }

    static func load(from dir: URL = Paths.workflows) -> [Entry] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var seen: Set<String> = []
        return files.map { file in
            guard let data = try? Data(contentsOf: file), data.count <= 1_000_000 else {
                return Entry(file: file, workflow: nil, problems: ["can't read the file"])
            }
            do {
                let workflow = try JSONDecoder().decode(Workflow.self, from: data)
                var problems = workflow.validate()
                if WorkflowTemplates.named(workflow.id) != nil {
                    problems.append("id \(workflow.id) is a built-in workflow's; give it another")
                } else if !seen.insert(workflow.id).inserted {
                    problems.append("id \(workflow.id) is used by another file; give it another")
                }
                return Entry(file: file, workflow: workflow, problems: problems)
            } catch {
                return Entry(file: file, workflow: nil, problems: [describe(error)])
            }
        }
    }

    /// Writes `workflow` as a new file (never over another), its id made
    /// unique like the file's name; returns it.
    static func save(_ workflow: Workflow, to dir: URL = Paths.workflows) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var workflow = workflow
        let base = workflow.id
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(workflow.id).json").path) {
            workflow.id = "\(base)-\(n)"
            n += 1
        }
        let url = dir.appendingPathComponent("\(workflow.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(workflow).write(to: url, options: .atomic)
        return url
    }

    /// Saves an edited workflow: over `replacing` (renamed if its id changed),
    /// or as a new file.
    static func write(_ workflow: Workflow, replacing file: URL?, to dir: URL = Paths.workflows) throws -> URL {
        guard let file else { return try save(workflow, to: dir) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let target = file.deletingPathExtension().lastPathComponent == workflow.id ? file : dir.appendingPathComponent("\(workflow.id).json")
        guard target == file || !FileManager.default.fileExists(atPath: target.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try encoder.encode(workflow).write(to: target, options: .atomic)
        if target != file { try? FileManager.default.removeItem(at: file) }
        return target
    }

    /// A decoding error in words: which field, what's wrong.
    static func describe(_ error: Error) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined().trimmingCharacters(in: ["."])
        }
        switch error as? DecodingError {
        case let .keyNotFound(key, context)?: return "\(path(context.codingPath + [key])): missing"
        case let .typeMismatch(_, context)?, let .valueNotFound(_, context)?:
            return "\(path(context.codingPath)): \(context.debugDescription)"
        case let .dataCorrupted(context)?:
            return context.codingPath.isEmpty ? "not valid JSON" : "\(path(context.codingPath)): \(context.debugDescription)"
        default: return String(describing: error)
        }
    }
}
