import XCTest
@testable import PRReviewKit

final class PullRequestTextScannerTests: XCTestCase {

    private func found(_ text: String) -> String? {
        PullRequestTextScanner.endpoint(in: text).map { "\($0.owner)/\($0.repo)#\($0.number)" }
    }

    func testFindsLinksWithExtraPathOrWordsAround() {
        XCTAssertEqual(found("https://github.com/acme/api/pull/12"), "acme/api#12")
        XCTAssertEqual(found("see https://github.com/acme/api/pull/12/files#diff-1 please"), "acme/api#12")
        XCTAssertEqual(found("https://github.com/Koltin-Dev/sales/pull/5818/changes"), "Koltin-Dev/sales#5818")
    }

    func testFindsLinksWithoutSchemeOrWithWww() {
        XCTAssertEqual(found("github.com/acme/api/pull/12"), "acme/api#12")
        XCTAssertEqual(found("http://www.github.com/acme/api/pull/12"), "acme/api#12")
    }

    func testFallsBackToTheNextSelectionFlavour() {
        // A link's visible text ("fix coupons #491") rarely names the PR; its URL does.
        let endpoint = PullRequestTextScanner.endpoint(inAnyOf: [
            "fix coupons #491",
            "https://github.com/acme/api/pull/491",
        ])

        XCTAssertEqual(endpoint.map { "\($0.owner)/\($0.repo)#\($0.number)" }, "acme/api#491")
    }

    func testFindsShorthandAndTakesTheFirstReference() {
        XCTAssertEqual(found("fixed in acme/api#7, see also acme/web#8"), "acme/api#7")
        XCTAssertEqual(found("acme/web#8 then https://github.com/acme/api/pull/9"), "acme/web#8")
    }

    func testIgnoresIssuesOtherHostsAndInvalidNames() {
        XCTAssertNil(found("https://github.com/acme/api/issues/12"))
        XCTAssertNil(found("https://gitlab.com/acme/api/pull/12"))
        XCTAssertNil(found("nothing here #12"))
        XCTAssertNil(found("https://github.com/acme/api/pull/0"))
    }
}
