import Foundation

// MARK: - GraphQL DTOs (file scope so they can be shared across functions)

private struct GQLPageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct GQLCommentNode: Decodable {
    let id: String
    let databaseId: Int?
    let body: String
    let author: GQLAuthor?
    let createdAt: String
}

private struct GQLAuthor: Decodable {
    let login: String
}

private struct GQLCommentConn: Decodable {
    let pageInfo: GQLPageInfo
    let nodes: [GQLCommentNode]
}

private struct GQLThreadNode: Decodable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool
    let path: String
    let line: Int?
    let originalLine: Int?
    let diffSide: String?
    let startLine: Int?
    let originalStartLine: Int?
    let comments: GQLCommentConn
}

private struct GQLThreadConn: Decodable {
    let pageInfo: GQLPageInfo
    let nodes: [GQLThreadNode]
}

private struct GQLPR: Decodable {
    let reviewThreads: GQLThreadConn
}

private struct GQLRepo: Decodable {
    let pullRequest: GQLPR
}

private struct GQLThreadsData: Decodable {
    let repository: GQLRepo
}

private struct GQLSingleThread: Decodable {
    struct Wrap: Decodable {
        let comments: GQLCommentConn
    }
    let node: Wrap?
}

private struct GQLEnvelope<T: Decodable>: Decodable {
    struct Err: Decodable { let message: String }
    let data: T?
    let errors: [Err]?
}

/// One GraphQL variable value. Only values a `gh api graphql` `-F` flag can
/// express: a string (gh infers numbers/booleans) or an explicit JSON null.
private enum GraphQLVariable {
    case string(String)
    case null
}

/// GitHub client backed by the `gh` CLI. All I/O is asynchronous and routed
/// through an injectable `CommandRunning` seam so tests never touch a real
/// process.
public final class GitHubClient: GitHubServing {

    private let commandRunner: CommandRunning
    private let payloadDirectory: URL
    private let resolver: (any GitHubExecutableResolving & GitHubExecutableInspecting)

    public init(
        commandRunner: CommandRunning = SystemCommandRunner(),
        payloadDirectory: URL = FileManager.default.temporaryDirectory,
        resolver: (any GitHubExecutableResolving & GitHubExecutableInspecting)? = nil
    ) {
        self.commandRunner = commandRunner
        self.payloadDirectory = payloadDirectory
        self.resolver = resolver ?? GitHubExecutableResolver()
    }

    public func dependencyStatus() async -> GitHubDependencyStatus {
        await GitHubDependencyChecker(runner: commandRunner, resolver: resolver).check()
    }

    // MARK: - Command helpers

    public func ensureAvailable() async throws {
        AppLog.info("github", "Checking GitHub CLI availability")
        do {
            _ = try await commandRunner.run(["--version"], timeout: 30)
            AppLog.info("github", "GitHub CLI is available")
        } catch is CancellationError {
            AppLog.warning("github", "GitHub CLI availability check was cancelled")
            throw CancellationError()
        } catch {
            AppLog.failure("github", context: "GitHub CLI availability check failed", error: error)
            // A broken or missing `gh` maps to the same actionable message as
            // a resolver miss.
            throw GitHubError.ghUnavailable(
                "The `gh` GitHub CLI is required but could not be run.\n"
                + "Install it with:  brew install gh\n"
                + "Then authenticate with:  gh auth login"
            )
        }
    }

    private func runJSON<T: Decodable>(_ args: [String]) async throws -> T {
        let r = try await commandRunner.run(args, timeout: GH.defaultTimeout)
        do {
            return try JSONDecoder().decode(T.self, from: r.data)
        } catch {
            throw GitHubError.parse("Could not decode response for: \(args.first ?? "gh api")")
        }
    }

    /// Runs `gh api graphql` with a static query string and typed variables.
    /// Surfaces GraphQL `errors` payloads as `.api`.
    private func runGraphQL<T: Decodable>(
        query: String,
        variables: [String: GraphQLVariable]
    ) async throws -> T {
        var args = ["api", "graphql", "-f", "query=\(query)"]
        for (k, v) in variables.sorted(by: { $0.key < $1.key }) {
            switch v {
            case .string(let s):
                args.append("-F")
                args.append("\(k)=\(s)")
            case .null:
                args.append("-F")
                args.append("\(k)=null")
            }
        }
        let r = try await commandRunner.run(args, timeout: GH.defaultTimeout)
        let decoder = JSONDecoder()
        guard let env = try? decoder.decode(GQLEnvelope<T>.self, from: r.data) else {
            throw GitHubError.parse("Could not decode GraphQL response")
        }
        if let errors = env.errors, !errors.isEmpty {
            throw GitHubError.api(errors.map { $0.message }.joined(separator: "\n"))
        }
        guard let data = env.data else {
            throw GitHubError.api("Empty GraphQL response")
        }
        return data
    }

    // MARK: - Endpoint resolution

    /// Accepts: full PR URL, `owner/repo#number`, or a bare number (resolved
    /// against the repository of the current working directory).
    public func resolveEndpoint(from arg: String) async throws -> PREndpoint {
        AppLog.info("github", "Resolving pull request reference \(arg)")
        var trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasPrefix("https://github.com/") || trimmed.hasPrefix("http://github.com/") {
            let path = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            // ["https:", "github.com", owner, repo, "pull", N]
            if path.count >= 5, path[path.count - 2] == "pull", let n = Int(path[path.count - 1]) {
                let endpoint = PREndpoint(owner: path[path.count - 4], repo: path[path.count - 3], number: n)
                AppLog.info("github", "Resolved URL to \(endpoint)")
                return endpoint
            }
            throw GitHubError.parse("Not a GitHub PR URL: \(arg)")
        }
        // owner/repo#number
        if trimmed.contains("#") {
            let parts = trimmed.split(separator: "#", maxSplits: 1)
            guard parts.count == 2, let n = Int(parts[1]) else {
                throw GitHubError.parse("Expected owner/repo#number: \(arg)")
            }
            let repoParts = parts[0].split(separator: "/")
            guard repoParts.count == 2 else {
                throw GitHubError.parse("Expected owner/repo#number: \(arg)")
            }
            let endpoint = PREndpoint(owner: String(repoParts[0]), repo: String(repoParts[1]), number: n)
            AppLog.info("github", "Resolved shorthand to \(endpoint)")
            return endpoint
        }
        // bare number: resolve repo from cwd
        if let n = Int(trimmed) {
            let out = try await commandRunner.run(
                ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                timeout: GH.defaultTimeout
            )
            let name = String(data: out.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = name.split(separator: "/")
            guard parts.count == 2 else {
                throw GitHubError.parse("Could not determine the current repository; use owner/repo#number or a full URL.")
            }
            let endpoint = PREndpoint(owner: String(parts[0]), repo: String(parts[1]), number: n)
            AppLog.info("github", "Resolved current-repository reference to \(endpoint)")
            return endpoint
        }
        throw GitHubError.parse("Could not understand PR reference: \(arg)")
    }

    // MARK: - Fetches

    private struct PRInfoDTO: Decodable {
        struct AuthorDTO: Decodable { let login: String }
        let number: Int
        let title: String
        let body: String?
        let state: String
        let isDraft: Bool
        let headRefOid: String
        let headRefName: String
        let baseRefName: String
        let additions: Int
        let deletions: Int
        let changedFiles: Int
        let reviewDecision: String?
        let url: String
        let author: AuthorDTO
        let statusCheckRollup: [CheckDTO]?
    }

    /// One `statusCheckRollup` entry: a check run (`status` + `conclusion`) or
    /// a commit status context (`state`).
    private struct CheckDTO: Decodable {
        let status: String?
        let conclusion: String?
        let state: String?
    }

    private static func checksSummary(_ rollup: [CheckDTO]?) -> PRChecksSummary? {
        guard let rollup, !rollup.isEmpty else { return nil }
        var summary = PRChecksSummary(passed: 0, failed: 0, pending: 0)
        for check in rollup {
            if let state = check.state {
                switch state {
                case "SUCCESS": summary.passed += 1
                case "PENDING", "EXPECTED": summary.pending += 1
                default: summary.failed += 1
                }
            } else if check.status != "COMPLETED" {
                summary.pending += 1
            } else {
                switch check.conclusion {
                case "SUCCESS", "NEUTRAL", "SKIPPED": summary.passed += 1
                default: summary.failed += 1
                }
            }
        }
        return summary
    }

    public func fetchPRInfo(_ ep: PREndpoint) async throws -> PRInfo {
        AppLog.info("github", "Fetching PR metadata for \(ep)")
        let fields = "number,title,body,state,isDraft,headRefOid,headRefName,baseRefName,"
            + "additions,deletions,changedFiles,reviewDecision,url,author,statusCheckRollup"
        let dto: PRInfoDTO = try await runJSON([
            "pr", "view", "--repo", "\(ep.owner)/\(ep.repo)", String(ep.number), "--json", fields,
        ])
        let info = PRInfo(
            number: dto.number,
            title: dto.title,
            body: dto.body,
            author: dto.author.login,
            state: dto.state,
            isDraft: dto.isDraft,
            headRefOid: dto.headRefOid,
            headRefName: dto.headRefName,
            baseRefName: dto.baseRefName,
            additions: dto.additions,
            deletions: dto.deletions,
            changedFiles: dto.changedFiles,
            reviewDecision: dto.reviewDecision,
            url: dto.url,
            checks: Self.checksSummary(dto.statusCheckRollup)
        )
        AppLog.info("github", "Fetched metadata for \(ep); state=\(info.state); files=\(info.changedFiles); head=\(info.headRefOid.prefix(12))")
        return info
    }

    /// Fetches the full unified diff; falls back to the per-file `files`
    /// endpoint when the raw diff fails (huge PRs, 406s, etc). Cancellation is
    /// never swallowed by the fallback.
    public func fetchDiff(_ ep: PREndpoint, progress: @escaping FetchProgressHandler = { _ in }) async throws -> [DiffFile] {
        AppLog.info("github", "Fetching diff for \(ep)")
        do {
            let r = try await commandRunner.run([
                "api", "repos/\(ep.owner)/\(ep.repo)/pulls/\(ep.number)",
                "-H", "Accept: application/vnd.github.v3.diff",
            ], timeout: GH.defaultTimeout)
            let text = String(data: r.data, encoding: .utf8) ?? ""
            let files = DiffParser.parse(text)
            if !files.isEmpty || text.isEmpty {
                AppLog.info("github", "Fetched raw diff for \(ep); bytes=\(r.data.count); files=\(files.count)")
                return files
            }
            AppLog.warning("github", "Raw diff for \(ep) was non-empty but could not be parsed; using file fallback")
        } catch is CancellationError {
            AppLog.warning("github", "Diff fetch cancelled for \(ep)")
            throw CancellationError()
        } catch {
            AppLog.failure("github", context: "Raw diff fetch failed for \(ep); using file fallback", error: error)
        }
        progress(.diffRefused)
        return try await fetchFilesFallback(ep, progress: progress)
    }

    /// Files per page of the fallback; GitHub's maximum.
    static let filesPageSize = 100
    /// GitHub lists at most this many files for a pull request.
    public static let maxListedFiles = 3000

    private struct PRFileDTO: Decodable {
        let filename: String
        let status: String
        let additions: Int
        let deletions: Int
        let changes: Int
        let patch: String?
        let previous_filename: String?
    }

    /// Pages by hand rather than with `--paginate` so each page can report
    /// progress.
    private func fetchFilesFallback(_ ep: PREndpoint, progress: FetchProgressHandler) async throws -> [DiffFile] {
        AppLog.info("github", "Fetching per-file diff fallback for \(ep)")
        var dtos: [PRFileDTO] = []
        var page = 1
        while true {
            let batch: [PRFileDTO] = try await runJSON([
                "api", "repos/\(ep.owner)/\(ep.repo)/pulls/\(ep.number)/files?per_page=\(Self.filesPageSize)&page=\(page)",
            ])
            dtos += batch
            progress(.filesFetched(dtos.count))
            if batch.count < Self.filesPageSize || dtos.count >= Self.maxListedFiles { break }
            page += 1
        }
        let files = dtos.map { dto in
            var file = DiffFile()
            switch dto.status {
            case "added": file.status = .added
            case "removed", "deleted": file.status = .deleted
            case "renamed": file.status = .renamed
            default: file.status = .modified
            }
            if let prev = dto.previous_filename { file.oldPath = prev }
            file.newPath = dto.filename
            guard let patch = dto.patch else {
                file.tooLarge = true
                return file
            }
            let old = file.oldPath ?? file.path
            let new = file.newPath ?? file.path
            let header = "diff --git a/\(old) b/\(new)\n"
                + "--- \(file.oldPath.map { "a/\($0)" } ?? "/dev/null")\n"
                + "+++ \(file.newPath.map { "b/\($0)" } ?? "/dev/null")\n"
            if let first = DiffParser.parse(header + patch).first {
                var f = first
                f.status = file.status
                if let prev = dto.previous_filename { f.oldPath = prev }
                return f
            }
            file.tooLarge = true
            return file
        }
        AppLog.info("github", "Fetched per-file diff fallback for \(ep); files=\(files.count); unavailable=\(files.filter(\.tooLarge).count)")
        return files
    }

    // MARK: - Review threads (GraphQL, cursor-paginated, variable-driven)

    private static let threadsQuery = """
    query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id isResolved isOutdated path line originalLine diffSide startLine originalStartLine
              comments(first: 100) {
                nodes { id databaseId body author { login } createdAt }
                pageInfo { hasNextPage endCursor }
              }
            }
          }
        }
      }
    }
    """

    private static let threadCommentsQuery = """
    query($threadID: ID!, $cursor: String!) {
      node(id: $threadID) {
        ... on ReviewThread {
          comments(first: 100, after: $cursor) {
            nodes { id databaseId body author { login } createdAt }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
    """

    public func fetchThreads(_ ep: PREndpoint) async throws -> [PRThread] {
        AppLog.info("github", "Fetching review threads for \(ep)")
        var threads: [PRThread] = []
        var after: String?
        repeat {
            let variables: [String: GraphQLVariable] = [
                "owner": .string(ep.owner),
                "repo": .string(ep.repo),
                "number": .string(String(ep.number)),
                "cursor": after.map { .string($0) } ?? .null,
            ]
            let data: GQLThreadsData = try await runGraphQL(
                query: Self.threadsQuery,
                variables: variables
            )
            let conn = data.repository.pullRequest.reviewThreads
            // Fetch each thread's (possibly multi-page) comments concurrently;
            // the task group keeps concurrency bounded by the executor and
            // preserves thread order by collecting into index slots.
            let pageNodes = conn.nodes
            var ordered: [PRThread?] = Array(repeating: nil, count: pageNodes.count)
            try await withThrowingTaskGroup(of: (Int, PRThread).self) { group in
                for (i, node) in pageNodes.enumerated() {
                    group.addTask {
                        let comments = try await self.fetchThreadComments(threadID: node.id, initial: node.comments)
                        let thread = PRThread(
                            id: node.id,
                            path: node.path,
                            line: node.line,
                            originalLine: node.originalLine,
                            side: node.diffSide ?? "RIGHT",
                            startLine: node.startLine,
                            startSide: node.startLine != nil ? (node.diffSide ?? "RIGHT") : nil,
                            isOutdated: node.isOutdated,
                            isResolved: node.isResolved,
                            comments: comments
                        )
                        return (i, thread)
                    }
                }
                for try await (i, thread) in group {
                    ordered[i] = thread
                }
            }
            threads.append(contentsOf: ordered.compactMap { $0 })
            after = conn.pageInfo.hasNextPage ? conn.pageInfo.endCursor : nil
        } while after != nil
        AppLog.info("github", "Fetched review threads for \(ep); threads=\(threads.count)")
        return threads
    }

    private func fetchThreadComments(
        threadID: String,
        initial: GQLCommentConn
    ) async throws -> [PRComment] {
        var comments = initial.nodes.map { nodeToComment($0) }
        var cursor = initial.pageInfo.hasNextPage ? initial.pageInfo.endCursor : nil
        while let c = cursor {
            let data: GQLSingleThread = try await runGraphQL(
                query: Self.threadCommentsQuery,
                variables: [
                    "threadID": .string(threadID),
                    "cursor": .string(c),
                ]
            )
            guard let conn = data.node?.comments else { break }
            comments.append(contentsOf: conn.nodes.map { nodeToComment($0) })
            cursor = conn.pageInfo.hasNextPage ? conn.pageInfo.endCursor : nil
        }
        return comments
    }

    private func nodeToComment(_ n: GQLCommentNode) -> PRComment {
        PRComment(
            databaseId: n.databaseId,
            author: n.author?.login ?? "unknown",
            body: n.body,
            createdAt: parseGHDate(n.createdAt) ?? Date()
        )
    }

    public func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
        try await fetchAll(ep, progress: { _ in })
    }

    public func fetchAll(_ ep: PREndpoint, progress: @escaping FetchProgressHandler) async throws -> FetchBundle {
        AppLog.info("github", "Starting concurrent PR fetch for \(ep)")
        // The three top-level fetches are independent; running them
        // concurrently hides subprocess startup and network latency behind each
        // other. Cancellation propagates to all three via `async let`.
        async let pr = fetchPRInfo(ep, progress: progress)
        async let files = fetchDiff(ep, progress: progress)
        async let threads = fetchThreads(ep)
        let bundle = try await FetchBundle(pr: pr, files: files, threads: threads)
        AppLog.info("github", "Completed concurrent PR fetch for \(ep); files=\(bundle.files.count); threads=\(bundle.threads.count)")
        return bundle
    }

    private func fetchPRInfo(_ ep: PREndpoint, progress: FetchProgressHandler) async throws -> PRInfo {
        let info = try await fetchPRInfo(ep)
        progress(.size(files: info.changedFiles, additions: info.additions, deletions: info.deletions))
        return info
    }

    // MARK: - Writes

    public func submitReview(
        _ ep: PREndpoint,
        commitID: String,
        body: String,
        event: String,
        drafts: [DraftComment]
    ) async throws {
        AppLog.info("review", "Submitting \(event) review for \(ep); drafts=\(drafts.count); commit=\(commitID.prefix(12))")
        let payload = PayloadBuilder.reviewPayload(
            commitID: commitID, body: body, event: event, drafts: drafts
        )
        let file = try PayloadBuilder.writeJSONToTemp(payload, in: payloadDirectory)
        defer { try? FileManager.default.removeItem(atPath: file) }
        _ = try await commandRunner.run([
            "api", "-X", "POST",
            "repos/\(ep.owner)/\(ep.repo)/pulls/\(ep.number)/reviews",
            "--input", file,
        ], timeout: GH.defaultTimeout)
        AppLog.info("review", "Submitted review for \(ep)")
    }

    public func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {
        AppLog.info("review", "Posting reply for \(ep); commentID=\(commentID)")
        struct Reply: Encodable { let body: String }
        let file = try PayloadBuilder.writeJSONToTemp(Reply(body: body), in: payloadDirectory)
        defer { try? FileManager.default.removeItem(atPath: file) }
        _ = try await commandRunner.run([
            "api", "-X", "POST",
            "repos/\(ep.owner)/\(ep.repo)/pulls/\(ep.number)/comments/\(commentID)/replies",
            "--input", file,
        ], timeout: GH.defaultTimeout)
        AppLog.info("review", "Posted reply for \(ep); commentID=\(commentID)")
    }

    public func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {
        AppLog.info("review", "Setting thread resolved=\(resolved) for \(ep); threadID=\(threadID)")
        // ResolveReviewThreadInput/UnresolveReviewThreadInput contain only
        // clientMutationId and threadId (verified against the GitHub schema).
        let mutation = resolved
            ? "mutation($id: ID!) { resolveReviewThread(input: { threadId: $id }) { thread { id isResolved } } }"
            : "mutation($id: ID!) { unresolveReviewThread(input: { threadId: $id }) { thread { id isResolved } } }"
        struct EmptyData: Decodable {}
        _ = try await runGraphQL(query: mutation, variables: ["id": .string(threadID)]) as EmptyData
        AppLog.info("review", "Updated thread resolution for \(ep); threadID=\(threadID); resolved=\(resolved)")
    }
}
