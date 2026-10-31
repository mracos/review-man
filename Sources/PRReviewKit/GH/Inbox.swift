import Foundation

/// Who is asking: their login and the organizations they can pick from for
/// the team section.
public struct InboxScope: Equatable {
    public var login: String
    public var organizations: [String]

    public init(login: String, organizations: [String]) {
        self.login = login
        self.organizations = organizations
    }
}

/// What every inbox search is narrowed to. Applied inside the search query,
/// so each section's page of results is already the filtered set.
public struct InboxFilter: Equatable {
    /// Pull requests carrying any of these labels; empty means no label filter.
    public var labels: [String]
    /// `owner/repo` names left out of every section.
    public var hiddenRepositories: [String]
    /// Organizations the team section searches; empty means no team search.
    public var teamOrganizations: [String]

    public init(labels: [String] = [], hiddenRepositories: [String] = [], teamOrganizations: [String] = []) {
        self.labels = labels
        self.hiddenRepositories = hiddenRepositories
        self.teamOrganizations = teamOrganizations
    }
}

/// One inbox list, expressed as a GitHub search across every repository.
public enum InboxSection: String, CaseIterable, Identifiable {
    case reviewRequested = "review-requested"
    case myOpen = "my-open"
    case mine
    case team

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .reviewRequested: return "Waiting for my review"
        case .myOpen: return "My open PRs"
        case .mine: return "My PRs"
        case .team: return "Team"
        }
    }

    /// The `search(type: ISSUE)` query, or nil when the section has nothing
    /// to search (a team section without organizations).
    public func searchQuery(filter: InboxFilter) -> String? {
        var terms: [String]
        switch self {
        case .reviewRequested:
            terms = ["is:pr", "is:open", "archived:false", "review-requested:@me"]
        case .myOpen:
            terms = ["is:pr", "is:open", "archived:false", "author:@me"]
        case .mine:
            terms = ["is:pr", "archived:false", "author:@me"]
        case .team:
            let organizations = filter.teamOrganizations.filter(PREndpoint.isValidName)
            guard !organizations.isEmpty else { return nil }
            terms = ["is:pr", "is:open", "archived:false"] + organizations.map { "org:\($0)" }
        }
        let labels = filter.labels
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !labels.isEmpty {
            terms.append("label:" + labels.map { "\"\($0)\"" }.joined(separator: ","))
        }
        terms += filter.hiddenRepositories.filter(Self.isRepositoryName).map { "-repo:\($0)" }
        terms.append("sort:updated-desc")
        return terms.joined(separator: " ")
    }

    private static func isRepositoryName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { PREndpoint.isValidName(String($0)) }
    }
}

/// A label as GitHub shows it: name plus a six-digit hex color.
public struct PRLabel: Equatable, Hashable {
    public var name: String
    public var color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }
}

/// One row of an inbox list.
public struct PRSummary: Equatable, Identifiable {
    public var id: String
    public var number: Int
    public var title: String
    /// `owner/repo`.
    public var repository: String
    public var author: String
    public var url: String
    public var state: String
    public var isDraft: Bool
    public var reviewDecision: String?
    /// The head commit's combined check state (`SUCCESS`, `FAILURE`,
    /// `PENDING`, `ERROR`, `EXPECTED`), nil when it has no checks.
    public var checksState: String?
    public var labels: [PRLabel]
    public var updatedAt: Date
    public var additions: Int
    public var deletions: Int

    public init(
        id: String, number: Int, title: String, repository: String, author: String,
        url: String, state: String, isDraft: Bool, reviewDecision: String?,
        checksState: String?, labels: [PRLabel], updatedAt: Date, additions: Int, deletions: Int
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.repository = repository
        self.author = author
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.checksState = checksState
        self.labels = labels
        self.updatedAt = updatedAt
        self.additions = additions
        self.deletions = deletions
    }

    public var endpoint: PREndpoint? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return PREndpoint(validatingOwner: String(parts[0]), repo: String(parts[1]), number: number)
    }
}
