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
