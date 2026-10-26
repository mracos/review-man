import Foundation

/// Persistence errors surfaced to the session store.
public enum PersistenceError: Error, CustomStringConvertible {
    case saveFailed(String)
    case loadFailed(String)

    public var description: String {
        switch self {
        case .saveFailed(let s): return "Could not save local state: \(s)"
        case .loadFailed(let s): return "Could not load local state: \(s)"
        }
    }
}

/// Shared, serialized, atomic local persistence for draft comments and
/// viewed-file marks, keyed by `owner_repo_number_sha` in the legacy
/// application-support directory.
///
/// All access goes through one instance (an actor serializes every operation),
/// so multiple windows in the same process can never interleave writes to the
/// same file. Writes are atomic: data is written to a same-directory temporary
/// file and then swapped into place, so a reader only ever sees a complete
/// document. Failures throw instead of being silently swallowed.
public actor ReviewPersistence: ReviewPersisting {

    public static let shared = ReviewPersistence()

    /// The directory holding `drafts-*.json` and `viewed-*.json`.
    public let directory: URL

    /// Filesystem swap seam (internal, test-only): `(temporaryURL, destinationURL)`.
    private let replace: (URL, URL) throws -> Void

    public init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/pr-review"),
        replacement: ((URL, URL) throws -> Void)? = nil
    ) {
        self.directory = directory
        self.replace = replacement ?? { temp, destination in
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
        }
    }

    // MARK: - Key and filenames (legacy contract)

    nonisolated func key(_ endpoint: PREndpoint, sha: String) -> String {
        "\(endpoint.owner)_\(endpoint.repo)_\(endpoint.number)_\(sha)"
            .replacingOccurrences(of: "/", with: "_")
    }

    /// PR-scoped key (no SHA): hidden-reviewer state is intentionally shared
    /// across head changes for the same pull request.
    nonisolated func key(_ endpoint: PREndpoint) -> String {
        "\(endpoint.owner)_\(endpoint.repo)_\(endpoint.number)"
            .replacingOccurrences(of: "/", with: "_")
    }

    nonisolated func draftsFileName(_ endpoint: PREndpoint, sha: String) -> String {
        "drafts-\(key(endpoint, sha: sha)).json"
    }

    nonisolated func viewedFileName(_ endpoint: PREndpoint, sha: String) -> String {
        "viewed-\(key(endpoint, sha: sha)).json"
    }

    nonisolated func hiddenReviewersFileName(_ endpoint: PREndpoint) -> String {
        "hidden-reviewers-\(key(endpoint)).json"
    }

    // MARK: - Drafts

    public func loadDraftState(
        for endpoint: PREndpoint,
        headSHA: String
    ) async throws -> PersistedDraftState {
        let url = directory.appendingPathComponent(draftsFileName(endpoint, sha: headSHA))
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .missing }
        guard let data = fm.contents(atPath: url.path) else {
            throw PersistenceError.loadFailed("could not read \(url.lastPathComponent)")
        }
        do {
            let dtos = try JSONDecoder().decode([DraftDTO].self, from: data)
            return .present(dtos.map { $0.draft })
        } catch {
            throw PersistenceError.loadFailed("malformed \(url.lastPathComponent): \(error)")
        }
    }

    public func saveDrafts(
        _ drafts: [DraftComment],
        for endpoint: PREndpoint,
        headSHA: String
    ) async throws {
        let url = directory.appendingPathComponent(draftsFileName(endpoint, sha: headSHA))
        let dtos = drafts.map { DraftDTO($0) }
        let data: Data
        do {
            data = try JSONEncoder().encode(dtos)
        } catch {
            throw PersistenceError.saveFailed("encoding drafts: \(error)")
        }
        try atomicWrite(data, to: url)
    }

    // MARK: - Viewed

    public func loadViewed(for endpoint: PREndpoint, headSHA: String) async throws -> Set<String> {
        let url = directory.appendingPathComponent(viewedFileName(endpoint, sha: headSHA))
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }
        guard let data = fm.contents(atPath: url.path) else {
            throw PersistenceError.loadFailed("could not read \(url.lastPathComponent)")
        }
        do {
            return Set(try JSONDecoder().decode([String].self, from: data))
        } catch {
            throw PersistenceError.loadFailed("malformed \(url.lastPathComponent): \(error)")
        }
    }

    public func saveViewed(_ viewed: Set<String>, for endpoint: PREndpoint, headSHA: String) async throws {
        let url = directory.appendingPathComponent(viewedFileName(endpoint, sha: headSHA))
        let data: Data
        do {
            data = try JSONEncoder().encode(viewed.sorted())
        } catch {
            throw PersistenceError.saveFailed("encoding viewed marks: \(error)")
        }
        try atomicWrite(data, to: url)
    }

    // MARK: - Hidden reviewers

    public func loadHiddenReviewers(for endpoint: PREndpoint) async throws -> Set<String> {
        let url = directory.appendingPathComponent(hiddenReviewersFileName(endpoint))
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }
        guard let data = fm.contents(atPath: url.path) else {
            throw PersistenceError.loadFailed("could not read \(url.lastPathComponent)")
        }
        do {
            return Set(try JSONDecoder().decode([String].self, from: data))
        } catch {
            throw PersistenceError.loadFailed("malformed \(url.lastPathComponent): \(error)")
        }
    }

    public func saveHiddenReviewers(_ hidden: Set<String>, for endpoint: PREndpoint) async throws {
        let url = directory.appendingPathComponent(hiddenReviewersFileName(endpoint))
        let data: Data
        do {
            data = try JSONEncoder().encode(hidden.sorted())
        } catch {
            throw PersistenceError.saveFailed("encoding hidden reviewers: \(error)")
        }
        try atomicWrite(data, to: url)
    }

    // MARK: - Atomic write

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = directory.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            // Owner-only: drafts carry private comment bodies and paths.
            // Re-applied after the swap, since replacing an existing file can
            // keep the old file's mode.
            guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try replace(temp, destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? fm.removeItem(at: temp)
            throw PersistenceError.saveFailed("writing \(destination.lastPathComponent): \(error)")
        }
    }
}

/// Legacy draft JSON shape. `isOrphaned` is derived in-memory state and is
/// deliberately NOT part of the persisted document.
private struct DraftDTO: Codable {
    let id: UUID
    let path: String
    let line: Int
    let side: String
    let body: String
    let createdAt: Date
    let startLine: Int?
    let startSide: String?

    init(_ draft: DraftComment) {
        self.id = draft.id
        self.path = draft.path
        self.line = draft.line
        self.side = draft.side
        self.body = draft.body
        self.createdAt = draft.createdAt
        self.startLine = draft.startLine
        self.startSide = draft.startSide
    }

    var draft: DraftComment {
        DraftComment(
            id: id, path: path, line: line, side: side, body: body,
            createdAt: createdAt, startLine: startLine, startSide: startSide
        )
    }
}
