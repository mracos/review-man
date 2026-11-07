import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

final class LoadProgressTests: XCTestCase {

    func testPagedFetchReportsCountsAgainstTheKnownTotal() {
        var progress = LoadProgress()

        progress.apply(.stage(.fetching))
        progress.apply(.fetch(.size(files: 1_088, additions: 9_000, deletions: 120)))
        progress.apply(.fetch(.diffRefused))
        progress.apply(.fetch(.filesFetched(300)))

        XCTAssertEqual(progress.headline, "Fetching files: 300 of \(1_088.formatted())")
        XCTAssertEqual(progress.sizeSummary, "\(1_088.formatted()) files · +\(9_000.formatted()) −120")
        XCTAssertNotNil(progress.note)
        XCTAssertEqual(progress.fractionCompleted!, 300.0 / 1_088.0, accuracy: 0.0001)
    }

    func testTotalIsCappedAtGitHubsListingLimit() {
        var progress = LoadProgress()

        progress.apply(.stage(.fetching))
        progress.apply(.fetch(.size(files: 5_000, additions: 1, deletions: 1)))
        progress.apply(.fetch(.diffRefused))
        progress.apply(.fetch(.filesFetched(1_500)))

        XCTAssertEqual(progress.headline, "Fetching files: \(1_500.formatted()) of \(3_000.formatted())")
        XCTAssertEqual(progress.fractionCompleted!, 0.5, accuracy: 0.0001)
    }

    func testLateEventsNeverMoveProgressBackwards() {
        var progress = LoadProgress()

        progress.apply(.stage(.preparing))
        progress.apply(.stage(.fetching))
        progress.apply(.fetch(.filesFetched(200)))
        progress.apply(.fetch(.filesFetched(100)))

        XCTAssertEqual(progress.stage, .preparing)
        XCTAssertEqual(progress.fetchedFiles, 200)
        XCTAssertNil(progress.fractionCompleted)
    }

    func testSingleDiffFetchIsIndeterminate() {
        var progress = LoadProgress()

        progress.apply(.stage(.fetching))
        progress.apply(.fetch(.size(files: 12, additions: 1, deletions: 1)))

        XCTAssertEqual(progress.headline, "Fetching the diff")
        XCTAssertNil(progress.fractionCompleted)
        XCTAssertNil(progress.note)
    }
}
