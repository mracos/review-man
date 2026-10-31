import Foundation

public struct PREndpoint: Equatable, CustomStringConvertible {
    public var owner: String
    public var repo: String
    public var number: Int

    public init(owner: String, repo: String, number: Int) {
        self.owner = owner
        self.repo = repo
        self.number = number
    }

    /// Nil unless both names pass `isValidName` and the number is positive.
    public init?(validatingOwner owner: String, repo: String, number: Int) {
        guard number > 0, Self.isValidName(owner), Self.isValidName(repo) else { return nil }
        self.init(owner: owner, repo: repo, number: number)
    }

    /// Parses `http(s)://(www.)github.com/owner/repo/pull/N`, ignoring any
    /// trailing tab (`/files`), query or fragment.
    public init?(gitHubURL url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com"
        else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5, parts[0].isEmpty, parts[3] == "pull", let number = Int(parts[4]) else { return nil }
        self.init(validatingOwner: parts[1], repo: parts[2], number: number)
    }

    public var description: String { "\(owner)/\(repo)#\(number)" }

    /// GitHub owner and repository names: ASCII letters, digits, `.`, `_` and
    /// `-`, not made only of dots. Both reach `gh` as `-F owner=...` and as
    /// REST path segments, where a leading `@` reads a local file and `..`
    /// walks to another endpoint.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.contains(where: { $0 != "." }) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-": return true
            default: return false
            }
        }
    }
}

public struct PRInfo {
    public var number: Int
    public var title: String
    public var body: String?
    public var author: String
    public var state: String
    public var isDraft: Bool
    public var headRefOid: String
    public var headRefName: String
    public var baseRefName: String
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var reviewDecision: String?
    public var url: String
    /// Nil when the head commit has no checks or status contexts.
    public var checks: PRChecksSummary?
    /// GraphQL node ID, needed by mutations that take a pull request ID.
    public var nodeID: String?

    public init(
        number: Int, title: String, body: String?, author: String, state: String,
        isDraft: Bool, headRefOid: String, headRefName: String, baseRefName: String,
        additions: Int, deletions: Int, changedFiles: Int, reviewDecision: String?, url: String,
        checks: PRChecksSummary? = nil, nodeID: String? = nil
    ) {
        self.number = number
        self.title = title
        self.body = body
        self.author = author
        self.state = state
        self.isDraft = isDraft
        self.headRefOid = headRefOid
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.reviewDecision = reviewDecision
        self.url = url
        self.checks = checks
        self.nodeID = nodeID
    }
}

/// CI state of the head commit, counted across check runs and commit statuses.
public struct PRChecksSummary: Equatable {
    public var passed: Int
    public var failed: Int
    public var pending: Int

    public init(passed: Int, failed: Int, pending: Int) {
        self.passed = passed
        self.failed = failed
        self.pending = pending
    }

    public var total: Int { passed + failed + pending }
}

public struct PRComment: Equatable {
    public var databaseId: Int?
    public var author: String
    public var body: String
    public var createdAt: Date

    public init(databaseId: Int?, author: String, body: String, createdAt: Date) {
        self.databaseId = databaseId
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }
}

public struct PRThread: Equatable, Identifiable {
    public var id: String
    public var path: String
    /// Current diff line (nil when outdated or file-level).
    public var line: Int?
    public var originalLine: Int?
    public var side: String   // "RIGHT" or "LEFT"
    public var startLine: Int?
    public var startSide: String?
    public var isOutdated: Bool
    public var isResolved: Bool
    public var comments: [PRComment]

    public init(
        id: String, path: String, line: Int?, originalLine: Int?, side: String,
        startLine: Int?, startSide: String?, isOutdated: Bool, isResolved: Bool,
        comments: [PRComment]
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.originalLine = originalLine
        self.side = side
        self.startLine = startLine
        self.startSide = startSide
        self.isOutdated = isOutdated
        self.isResolved = isResolved
        self.comments = comments
    }

    public var rootCommentID: Int? { comments.first?.databaseId }
    public var rootComment: PRComment? { comments.first }
    public var lastCommentAt: Date { comments.map { $0.createdAt }.max() ?? .distantPast }
}

/// A local, not-yet-submitted review comment.
public struct DraftComment: Equatable {
    public var id: UUID
    public var path: String
    public var line: Int
    public var side: String
    public var body: String
    public var createdAt: Date
    public var startLine: Int?
    public var startSide: String?
    /// Derived in-memory state: true when the anchor no longer exists in the
    /// fetched diff. Orphaned drafts are excluded from submission until their
    /// anchor reappears (automatic reattachment) or they are deleted. This is
    /// never persisted to the legacy JSON files.
    public var isOrphaned: Bool

    public init(
        id: UUID = UUID(), path: String, line: Int, side: String, body: String,
        createdAt: Date = Date(), startLine: Int? = nil, startSide: String? = nil,
        isOrphaned: Bool = false
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.side = side
        self.body = body
        self.createdAt = createdAt
        self.startLine = startLine
        self.startSide = startSide
        self.isOrphaned = isOrphaned
    }
}

public struct FetchBundle {
    public var pr: PRInfo
    public var files: [DiffFile]
    public var threads: [PRThread]
}
