import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

/// Called from the inbox's concurrent section searches, so every piece of
/// recorded state is guarded by a lock.
private final class InboxService: GitHubServing, @unchecked Sendable {
    var rowsByQuery: [String: [PRSummary]] = [:]
    var failingQueryFragment: String?
    private let lock = NSLock()
    private var recordedQueries: [String] = []
    private var recordedScopeFetches = 0

    var queries: [String] { lock.withLock { recordedQueries } }
    var scopeFetches: Int { lock.withLock { recordedScopeFetches } }

    func ensureAvailable() async throws {}
    func resolveEndpoint(from argument: String) async throws -> PREndpoint { PREndpoint(owner: "o", repo: "r", number: 1) }
    func fetchAll(_ endpoint: PREndpoint) async throws -> FetchBundle { throw GitHubError.parse("unused") }
    func submitReview(_ endpoint: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {}
    func replyToThread(_ endpoint: PREndpoint, commentID: Int, body: String) async throws {}
    func resolveThread(_ endpoint: PREndpoint, threadID: String, resolved: Bool) async throws {}

    func fetchViewerScope() async throws -> InboxScope {
        lock.withLock { recordedScopeFetches += 1 }
        return InboxScope(login: "me", organizations: ["acme", "tools"])
    }

    func searchPullRequests(query: String, first: Int) async throws -> [PRSummary] {
        lock.withLock { recordedQueries.append(query) }
        if let fragment = failingQueryFragment, query.contains(fragment) {
            throw GitHubError.parse("search failed")
        }
        return rowsByQuery.first { query.contains($0.key) }?.value ?? []
    }
}

private func row(_ number: Int, _ repository: String = "acme/api", labels: [String] = []) -> PRSummary {
    PRSummary(
        id: "PR_\(number)", number: number, title: "PR \(number)", repository: repository, author: "u",
        url: "https://github.com/\(repository)/pull/\(number)", state: "OPEN", isDraft: false,
        reviewDecision: nil, checksState: nil, labels: labels.map { PRLabel(name: $0, color: "ededed") },
        updatedAt: Date(), additions: 1, deletions: 0
    )
}

@MainActor
final class InboxStoreTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "inbox-\(UUID().uuidString)")!
    }

    private func makeStore(_ service: InboxService) -> InboxStore {
        InboxStore(service: service, defaults: defaults, refreshesOnChange: false)
    }

    func testStartsWithMySectionsGroupedByRepository() async {
        let service = InboxService()
        service.rowsByQuery = ["review-requested:@me": [row(1)], "is:open archived:false author:@me": [row(2)]]
        let inbox = makeStore(service)

        await inbox.refresh()

        XCTAssertEqual(inbox.sections, [.reviewRequested, .myOpen, .mine])
        XCTAssertTrue(inbox.groupByRepository)
        XCTAssertEqual(inbox.rows(for: .reviewRequested).map(\.number), [1])
        XCTAssertEqual(inbox.rows(for: .myOpen).map(\.number), [2])
        XCTAssertEqual(inbox.organizations, ["acme", "tools"])
    }

    func testTeamWithoutOrganizationsAsksForSetupInsteadOfSearching() async {
        let service = InboxService()
        let inbox = makeStore(service)
        inbox.setSection(.team, enabled: true)

        await inbox.refresh()

        XCTAssertEqual(inbox.sections, [.reviewRequested, .myOpen, .mine, .team])
        XCTAssertTrue(inbox.needsSetup(.team))
        XCTAssertFalse(service.queries.contains { $0.contains("org:") })
    }

    func testTeamSearchesTheChosenOrganizations() async {
        let service = InboxService()
        service.rowsByQuery = ["org:acme": [row(9, "acme/web")]]
        let inbox = makeStore(service)
        inbox.setSection(.team, enabled: true)
        inbox.toggleTeamOrganization("acme")

        await inbox.refresh()

        XCTAssertFalse(inbox.needsSetup(.team))
        XCTAssertEqual(inbox.rows(for: .team).map(\.number), [9])
    }

    func testFiltersReachTheSearchAndSurviveANewStore() async {
        let service = InboxService()
        let inbox = makeStore(service)
        inbox.hideRepository("acme/legacy")
        inbox.toggleLabel("agentic-workflows")
        inbox.setSection(.mine, enabled: false)
        inbox.setGroupByRepository(false)

        await inbox.refresh()

        XCTAssertTrue(service.queries.allSatisfy { $0.contains("-repo:acme/legacy") && $0.contains("label:\"agentic-workflows\"") })
        let reopened = makeStore(InboxService())
        XCTAssertEqual(reopened.filter, InboxFilter(labels: ["agentic-workflows"], hiddenRepositories: ["acme/legacy"]))
        XCTAssertEqual(reopened.sections, [.reviewRequested, .myOpen])
        XCTAssertFalse(reopened.groupByRepository)
    }

    func testShowingARepositoryAgainAndClearingLabels() {
        let inbox = makeStore(InboxService())
        inbox.hideRepository("acme/legacy")
        inbox.toggleLabel("a")
        inbox.toggleLabel("b")

        inbox.showRepository("acme/legacy")
        inbox.clearLabels()

        XCTAssertEqual(inbox.filter, InboxFilter())
    }

    func testKnownLabelsComeFromLoadedRowsAndTheFilter() async {
        let service = InboxService()
        service.rowsByQuery = ["review-requested:@me": [row(1, labels: ["bug", "agentic-workflows"])]]
        let inbox = makeStore(service)
        inbox.toggleLabel("chore")

        await inbox.refresh()

        XCTAssertEqual(inbox.knownLabels, ["agentic-workflows", "bug", "chore"])
    }

    func testRowsGroupByRepositoryInOrderOfMostRecentUpdate() async {
        let service = InboxService()
        service.rowsByQuery = ["review-requested:@me": [row(1, "acme/web"), row(2, "acme/api"), row(3, "acme/web")]]
        let inbox = makeStore(service)

        await inbox.refresh()

        let groups = inbox.groupedRows(for: .reviewRequested)
        XCTAssertEqual(groups.map(\.repository), ["acme/web", "acme/api"])
        XCTAssertEqual(groups.map { $0.rows.map(\.number) }, [[1, 3], [2]])
    }

    func testRepositoriesCanBeToggledFromTheListOfKnownOnes() async {
        let service = InboxService()
        service.rowsByQuery = ["review-requested:@me": [row(1, "acme/web"), row(2, "acme/api")]]
        let inbox = makeStore(service)
        await inbox.refresh()

        inbox.toggleRepository("acme/web")

        XCTAssertTrue(inbox.isHidden("acme/web"))
        XCTAssertEqual(inbox.knownRepositories, ["acme/api", "acme/web"], "a hidden repository stays listed so it can come back")
        inbox.toggleRepository("acme/web")
        XCTAssertFalse(inbox.isHidden("acme/web"))
    }

    func testCollapsedRepositoriesSurviveANewStore() {
        let inbox = makeStore(InboxService())
        inbox.toggleRepositoryCollapsed("acme/web")
        inbox.toggleRepositoryCollapsed("acme/api")
        inbox.toggleRepositoryCollapsed("acme/api")

        let reopened = makeStore(InboxService())

        XCTAssertTrue(reopened.isRepositoryCollapsed("acme/web"))
        XCTAssertFalse(reopened.isRepositoryCollapsed("acme/api"))
    }

    func testCollapsedSectionsSurviveANewStore() {
        let inbox = makeStore(InboxService())
        inbox.toggleCollapsed(.mine)
        inbox.toggleCollapsed(.team)
        inbox.toggleCollapsed(.team)

        let reopened = makeStore(InboxService())

        XCTAssertTrue(reopened.isCollapsed(.mine))
        XCTAssertFalse(reopened.isCollapsed(.team))
    }

    func testViewerScopeIsFetchedOnce() async {
        let service = InboxService()
        let inbox = makeStore(service)

        await inbox.refresh()
        await inbox.refresh()

        XCTAssertEqual(service.scopeFetches, 1)
    }

    func testAFailingSearchOnlyMarksItsOwnSection() async {
        let service = InboxService()
        service.rowsByQuery = ["review-requested:@me": [row(1)]]
        service.failingQueryFragment = "is:open archived:false author:@me"
        let inbox = makeStore(service)

        await inbox.refresh()

        XCTAssertNotNil(inbox.error(for: .myOpen))
        XCTAssertNil(inbox.error(for: .reviewRequested))
        XCTAssertEqual(inbox.rows(for: .reviewRequested).map(\.number), [1])
    }
}
