import XCTest
@testable import PRReviewKit

final class PREndpointTests: XCTestCase {

    func testAcceptsGitHubOwnerAndRepositoryNames() {
        for name in ["octocat", "hello-world", "a.b_c", "R2-D2", ".github", "x"] {
            XCTAssertTrue(PREndpoint.isValidName(name), name)
        }
    }

    func testRejectsNamesGhOrAPathWouldInterpret() {
        // `@` makes `gh -F` read a file; `..` and `/` steer REST paths.
        for name in ["", ".", "..", "...", "@foo", "a/b", "a b", "a?x", "a#b", "%40foo", "caf\u{e9}"] {
            XCTAssertFalse(PREndpoint.isValidName(name), name)
        }
    }

    func testValidatingInitRejectsBadPartsAndNonPositiveNumbers() {
        XCTAssertEqual(PREndpoint(validatingOwner: "o", repo: "r", number: 1), PREndpoint(owner: "o", repo: "r", number: 1))
        XCTAssertNil(PREndpoint(validatingOwner: "@o", repo: "r", number: 1))
        XCTAssertNil(PREndpoint(validatingOwner: "o", repo: "..", number: 1))
        XCTAssertNil(PREndpoint(validatingOwner: "o", repo: "r", number: 0))
    }

    func testParsesGitHubPullRequestURLs() {
        let expected = PREndpoint(owner: "octocat", repo: "hello-world", number: 42)
        for string in [
            "https://github.com/octocat/hello-world/pull/42",
            "http://github.com/octocat/hello-world/pull/42",
            "https://www.github.com/octocat/hello-world/pull/42",
            "https://GitHub.com/octocat/hello-world/pull/42",
            "https://github.com/octocat/hello-world/pull/42/files",
            "https://github.com/octocat/hello-world/pull/42#discussion_r1",
            "https://github.com/octocat/hello-world/pull/42?w=1",
        ] {
            XCTAssertEqual(PREndpoint(gitHubURL: URL(string: string)!), expected, string)
        }
    }

    func testRejectsURLsThatAreNotGitHubPullRequests() {
        for string in [
            "https://example.com/o/r/pull/1",
            "https://github.com/o/r",
            "https://github.com/o/r/issues/1",
            "https://github.com/o/r/pull/0",
            "https://github.com/o/r/pull/abc",
            "https://github.com/%40o/r/pull/1",
            "https://github.com/o/../pull/1",
            "https://github.com/o//pull/1",
            "ftp://github.com/o/r/pull/1",
        ] {
            XCTAssertNil(PREndpoint(gitHubURL: URL(string: string)!), string)
        }
    }
}
