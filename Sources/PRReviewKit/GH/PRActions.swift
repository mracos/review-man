import Foundation

/// How a pull request can be merged, as the repository allows.
public enum MergeMethod: String, CaseIterable, Identifiable {
    case squash
    case merge
    case rebase

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .squash: return "Squash and merge"
        case .merge: return "Create a merge commit"
        case .rebase: return "Rebase and merge"
        }
    }
}

/// A write to the pull request itself, run through `gh pr`.
public enum PRAction: Equatable {
    case merge(MergeMethod)
    case approve
    case markReady
    case convertToDraft
    case close
    case reopen

    /// The `gh` arguments, as an argument array (never a shell string).
    public func arguments(for endpoint: PREndpoint) -> [String] {
        let target = [String(endpoint.number), "--repo", "\(endpoint.owner)/\(endpoint.repo)"]
        switch self {
        case .merge(let method): return ["pr", "merge"] + target + ["--\(method.rawValue)"]
        case .approve: return ["pr", "review"] + target + ["--approve"]
        case .markReady: return ["pr", "ready"] + target
        case .convertToDraft: return ["pr", "ready"] + target + ["--undo"]
        case .close: return ["pr", "close"] + target
        case .reopen: return ["pr", "reopen"] + target
        }
    }
}

/// What the viewer may do to a pull request, from the repository permission
/// and the pull request's own state.
public struct PRActionState: Equatable {
    public var state: String
    public var isDraft: Bool
    public var mergeable: String
    /// `ADMIN`, `MAINTAIN`, `WRITE`, `TRIAGE` or `READ`.
    public var viewerPermission: String
    public var viewerCanUpdate: Bool
    public var viewerDidAuthor: Bool
    public var allowedMergeMethods: [MergeMethod]

    public init(
        state: String, isDraft: Bool, mergeable: String, viewerPermission: String,
        viewerCanUpdate: Bool, viewerDidAuthor: Bool, allowedMergeMethods: [MergeMethod]
    ) {
        self.state = state
        self.isDraft = isDraft
        self.mergeable = mergeable
        self.viewerPermission = viewerPermission
        self.viewerCanUpdate = viewerCanUpdate
        self.viewerDidAuthor = viewerDidAuthor
        self.allowedMergeMethods = allowedMergeMethods
    }

    private var isOpen: Bool { state == "OPEN" }

    /// Merge methods offered now: none unless the viewer can push and the
    /// pull request is open, ready and not known to conflict.
    public var mergeMethods: [MergeMethod] {
        guard ["ADMIN", "MAINTAIN", "WRITE"].contains(viewerPermission),
              isOpen, !isDraft, mergeable != "CONFLICTING" else { return [] }
        return allowedMergeMethods
    }

    /// GitHub does not let authors approve their own pull requests.
    public var canApprove: Bool { isOpen && !viewerDidAuthor }
    public var canMarkReady: Bool { viewerCanUpdate && isOpen && isDraft }
    public var canConvertToDraft: Bool { viewerCanUpdate && isOpen && !isDraft }
    public var canClose: Bool { viewerCanUpdate && isOpen }
    public var canReopen: Bool { viewerCanUpdate && state == "CLOSED" }

    public var hasAnyAction: Bool {
        !mergeMethods.isEmpty || canApprove || canMarkReady || canConvertToDraft || canClose || canReopen
    }
}
