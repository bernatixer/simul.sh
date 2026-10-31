import Foundation

/// Persistence format:
///
///     { "version": 1, "reviews": { "<session uuid>": ReviewState } }
///
/// Same rules as SessionStore: atomic writes, previous copy kept as
/// reviews.json.prev. Also holds copies of viewed files (by git hash), so
/// "changed since viewed" can show a diff against what the reviewer saw.
struct ReviewStoreSnapshot: Codable, Equatable {
    var version: Int
    var reviews: [String: ReviewState]

    static let currentVersion = 1
}

/// Sendable: every property is an immutable let, and FileManager.default
/// and the coders are thread-safe. ReviewCenter calls it from one serial queue.
final class ReviewStore: @unchecked Sendable {
    private let fileURL: URL
    private let backupURL: URL
    private let snapshots: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL = Paths.reviewsFile, backupURL: URL = Paths.reviewsBackupFile,
         snapshots: URL = Paths.reviewSnapshots) {
        self.fileURL = fileURL
        self.backupURL = backupURL
        self.snapshots = snapshots
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Missing file returns [:]. Corrupt primary falls back to `.prev`;
    /// corrupt both returns [:].
    func load() -> [UUID: ReviewState] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            return try readReviews(from: fileURL)
        } catch {
            Log.store.error("failed to load \(self.fileURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            if fileManager.fileExists(atPath: backupURL.path),
               let reviews = try? readReviews(from: backupURL) {
                Log.store.warning("recovered \(reviews.count) reviews from backup")
                return reviews
            }
            return [:]
        }
    }

    func save(_ reviews: [UUID: ReviewState]) {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let snapshot = ReviewStoreSnapshot(
                version: ReviewStoreSnapshot.currentVersion,
                reviews: Dictionary(uniqueKeysWithValues: reviews.map { ($0.key.uuidString, $0.value) })
            )
            let data = try encoder.encode(snapshot)
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: backupURL)
                try? fileManager.copyItem(at: fileURL, to: backupURL)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.store.error("failed to save reviews: \(String(describing: error), privacy: .public)")
        }
    }

    /// Copies the working file into snapshots/<hash> if not there; returns its URL.
    func keepViewedContent(of file: URL, hash: String) -> URL? {
        guard let target = snapshotURL(hash: hash) else { return nil }
        if fileManager.fileExists(atPath: target.path) { return target }
        do {
            try fileManager.createDirectory(at: snapshots, withIntermediateDirectories: true)
            try fileManager.copyItem(at: file, to: target)
            return target
        } catch {
            Log.store.error("failed to keep \(file.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func viewedContent(hash: String) -> URL? {
        guard let url = snapshotURL(hash: hash), fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Deletes snapshots no ViewedMark references.
    func pruneSnapshots(keeping hashes: Set<String>) {
        let names = (try? fileManager.contentsOfDirectory(atPath: snapshots.path)) ?? []
        for name in names where !hashes.contains(name) {
            try? fileManager.removeItem(at: snapshots.appendingPathComponent(name))
        }
    }

    /// Hashes are git blob hashes: 40 (sha1) or 64 (sha256) lowercase hex.
    /// Anything else could name a path outside the folder.
    private func snapshotURL(hash: String) -> URL? {
        guard hash.count == 40 || hash.count == 64,
              hash.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }) else { return nil }
        return snapshots.appendingPathComponent(hash)
    }

    private func readReviews(from url: URL) throws -> [UUID: ReviewState] {
        let snapshot = try decoder.decode(ReviewStoreSnapshot.self, from: Data(contentsOf: url))
        switch snapshot.version {
        case ReviewStoreSnapshot.currentVersion:
            // UUID parsing is case-insensitive: two keys can collide, keep one.
            return Dictionary(snapshot.reviews.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            }, uniquingKeysWith: { first, _ in first })
        default:
            Log.store.warning("unknown reviews version \(snapshot.version), ignoring contents")
            return [:]
        }
    }
}
