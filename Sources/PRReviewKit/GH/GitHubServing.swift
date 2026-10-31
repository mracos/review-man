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
    /// Pull requests matching a GitHub search query, across repositories.
    func searchPullRequests(query: String, first: Int) async throws -> [PRSummary]
    /// The authenticated user's login and organizations.
    func fetchViewerScope() async throws -> InboxScope
}

public extension GitHubServing {
    /// Default: an inert "checking" status so lightweight test doubles do not
    /// need to implement health probing. `GitHubClient` overrides this.
    func dependencyStatus() async -> GitHubDependencyStatus {
        GitHubDependencyStatus(state: .checking)
    }

    /// Default: an empty inbox, so test doubles without one need not
    /// implement it. `GitHubClient` overrides both.
    func searchPullRequests(query: String, first: Int) async throws -> [PRSummary] { [] }

    func fetchViewerScope() async throws -> InboxScope { InboxScope(login: "", organizations: []) }
}
