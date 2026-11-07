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
    /// `fetchAll`, reporting how far it got while it runs. Big pull requests
    /// take several requests, and the window shows each step.
    func fetchAll(_ endpoint: PREndpoint, progress: @escaping FetchProgressHandler) async throws -> FetchBundle
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
}

/// What a pull request fetch has got to.
public enum FetchProgress: Equatable, Sendable {
    /// The pull request's size, from its metadata.
    case size(files: Int, additions: Int, deletions: Int)
    /// GitHub refused the diff in one piece (over 300 files or too many
    /// lines), so files come page by page.
    case diffRefused
    /// Files fetched so far through those pages.
    case filesFetched(Int)
}

public typealias FetchProgressHandler = @Sendable (FetchProgress) -> Void

public extension GitHubServing {
    /// Default: no progress, so test doubles need only `fetchAll(_:)`.
    func fetchAll(_ endpoint: PREndpoint, progress: @escaping FetchProgressHandler) async throws -> FetchBundle {
        try await fetchAll(endpoint)
    }

    /// Default: an inert "checking" status so lightweight test doubles do not
    /// need to implement health probing. `GitHubClient` overrides this.
    func dependencyStatus() async -> GitHubDependencyStatus {
        GitHubDependencyStatus(state: .checking)
    }
}
