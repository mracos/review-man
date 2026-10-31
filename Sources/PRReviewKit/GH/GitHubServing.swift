import Foundation

/// The GitHub operations the UI depends on, backed by the authenticated `gh`
/// CLI. Asynchronous so callers can be cancelled and so writes can be tracked
/// independently.
public protocol GitHubServing {
    /// Verifies `gh` exists (and that authentication is configured) with a
    /// minimal probe.
    func ensureAvailable() async throws
    /// Accepts a full PR URL, `owner/repo#number`, or a bare number resolved
    /// against the current working directory's repository.
    func resolveEndpoint(from argument: String) async throws -> PREndpoint
    /// Fetches PR info, the diff, and review threads in one bundle.
    func fetchAll(_ endpoint: PREndpoint) async throws -> FetchBundle
    /// Submits a review anchored to `commitID`.
    func submitReview(
        _ endpoint: PREndpoint,
        commitID: String,
        body: String,
        event: String,
        drafts: [DraftComment]
    ) async throws
    /// Posts a reply to a thread's root comment.
    func replyToThread(_ endpoint: PREndpoint, commentID: Int, body: String) async throws
    /// Resolves or unresolves a review thread.
    func resolveThread(_ endpoint: PREndpoint, threadID: String, resolved: Bool) async throws
    /// Runs the direct `gh` dependency health checks (version, auth, minimal
    /// API probe) and returns an actionable status.
    func dependencyStatus() async -> GitHubDependencyStatus
    /// A file's lines at a commit, for revealing context between hunks.
    func fetchFileLines(_ endpoint: PREndpoint, path: String, ref: String) async throws -> [String]
}

public extension GitHubServing {
    /// Default: an inert "checking" status so lightweight test doubles do not
    /// need to implement health probing. `GitHubClient` overrides this.
    func dependencyStatus() async -> GitHubDependencyStatus {
        GitHubDependencyStatus(state: .checking)
    }

    /// Default: no file content, so doubles that never expand context need
    /// not implement it. `GitHubClient` overrides it.
    func fetchFileLines(_ endpoint: PREndpoint, path: String, ref: String) async throws -> [String] {
        throw GitHubError.parse("File contents are not available")
    }
}
