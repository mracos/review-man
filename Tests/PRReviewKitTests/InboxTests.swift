import XCTest
@testable import PRReviewKit

final class InboxTests: XCTestCase {

    func testSectionQueriesUseTheViewerAndSortByUpdate() {
        let filter = InboxFilter()

        XCTAssertEqual(
            InboxSection.reviewRequested.searchQuery(filter: filter),
            "is:pr is:open archived:false review-requested:@me sort:updated-desc"
        )
        XCTAssertEqual(
            InboxSection.myOpen.searchQuery(filter: filter),
            "is:pr is:open archived:false author:@me sort:updated-desc"
        )
        XCTAssertEqual(
            InboxSection.recentlyClosed.searchQuery(filter: filter),
            "is:pr is:closed archived:false author:@me sort:updated-desc"
        )
    }

    func testTeamSearchesTheChosenOrganizationsOnly() {
        XCTAssertNil(InboxSection.team.searchQuery(filter: InboxFilter()))
        XCTAssertEqual(
            InboxSection.team.searchQuery(filter: InboxFilter(teamOrganizations: ["acme", "tools"])),
            "is:pr is:open archived:false org:acme org:tools sort:updated-desc"
        )
    }

    /// Filters are part of the search, so each section's page of results is
    /// already the filtered set.
    func testLabelsAndHiddenRepositoriesNarrowEverySearch() {
        let filter = InboxFilter(labels: ["agentic-workflows", "ai review"], hiddenRepositories: ["acme/legacy"])

        XCTAssertEqual(
            InboxSection.myOpen.searchQuery(filter: filter),
            "is:pr is:open archived:false author:@me label:\"agentic-workflows\",\"ai review\" -repo:acme/legacy sort:updated-desc"
        )
    }

    /// Label names are free text, so a quote must not end the qualifier early.
    func testLabelQuotesCannotBreakOutOfTheQualifier() {
        let query = InboxSection.myOpen.searchQuery(filter: InboxFilter(labels: ["a\" org:evil"])) ?? ""

        XCTAssertTrue(query.contains("label:\"a org:evil\""), query)
    }

    func testSummaryEndpointComesFromTheRepository() {
        let summary = PRSummary(
            id: "PR_1", number: 7, title: "t", repository: "acme/api", author: "u",
            url: "https://github.com/acme/api/pull/7", state: "OPEN", isDraft: false,
            reviewDecision: nil, checksState: nil, labels: [], updatedAt: Date(), additions: 1, deletions: 0
        )

        XCTAssertEqual(summary.endpoint, PREndpoint(owner: "acme", repo: "api", number: 7))
    }
}
