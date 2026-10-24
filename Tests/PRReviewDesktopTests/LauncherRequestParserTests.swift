import XCTest
import PRReviewKit
@testable import PRReviewDesktop

final class LauncherRequestParserTests: XCTestCase {

    func testParsesDemoAndReferences() {
        XCTAssertEqual(LauncherRequestParser.parse(["--demo"]), .demo)
        XCTAssertEqual(
            LauncherRequestParser.parse(["https://github.com/o/r/pull/1"]),
            .open(reference: "https://github.com/o/r/pull/1")
        )
        XCTAssertEqual(LauncherRequestParser.parse(["o/r#42"]), .open(reference: "o/r#42"))
    }

    func testRejectsInvalidInput() {
        guard case .invalid = LauncherRequestParser.parse([]) else {
            return XCTFail("missing reference must be invalid")
        }
        guard case .invalid = LauncherRequestParser.parse(["--bogus"]) else {
            return XCTFail("unknown option must be invalid")
        }
        guard case .invalid = LauncherRequestParser.parse(["o/r#1", "o/r#2"]) else {
            return XCTFail("multiple references must be invalid")
        }
    }

    func testNormalizesToAppURL() {
        XCTAssertEqual(
            LauncherRequestParser.appURL(for: "https://github.com/octocat/hello-world/pull/123"),
            "pr-review://open/octocat/hello-world/123"
        )
        XCTAssertEqual(
            LauncherRequestParser.appURL(for: "octocat/hello-world#42"),
            "pr-review://open/octocat/hello-world/42"
        )
        XCTAssertNil(LauncherRequestParser.appURL(for: "not a reference"))
        XCTAssertNil(LauncherRequestParser.appURL(for: "123"), "bare numbers must be resolved by the caller")
    }

    func testResolveEndpointPure() {
        XCTAssertEqual(
            LauncherRequestParser.resolveEndpoint(from: "https://github.com/a/b/pull/7"),
            PREndpoint(owner: "a", repo: "b", number: 7)
        )
        XCTAssertEqual(
            LauncherRequestParser.resolveEndpoint(from: "a/b#9"),
            PREndpoint(owner: "a", repo: "b", number: 9)
        )
        XCTAssertNil(LauncherRequestParser.resolveEndpoint(from: "https://example.com/o/r/pull/1"))
        XCTAssertNil(LauncherRequestParser.resolveEndpoint(from: "o/r#0"))
    }
}

// MARK: - Strictness additions

extension LauncherRequestParserTests {
    func testDemoCannotCombineWithReference() {
        guard case .invalid = LauncherRequestParser.parse(["--demo", "o/r#1"]) else {
            return XCTFail("--demo with a reference must be invalid")
        }
    }

    func testExtraPathComponentsAreRejected() {
        // "a/b/c/pull/7" must NOT normalize to a/b#7.
        XCTAssertNil(LauncherRequestParser.resolveEndpoint(from: "https://github.com/a/b/c/pull/7"))
        XCTAssertNil(LauncherRequestParser.resolveEndpoint(from: "https://github.com/a/b/pull/7/extra"))
        // The exact form still works.
        XCTAssertEqual(
            LauncherRequestParser.resolveEndpoint(from: "https://github.com/a/b/pull/7"),
            PREndpoint(owner: "a", repo: "b", number: 7)
        )
    }
}

extension LauncherRequestParserTests {
    func testRequiresHttpsAndRejectsTrailingSlash() {
        XCTAssertNil(LauncherRequestParser.resolveEndpoint(from: "http://github.com/a/b/pull/7"))
        XCTAssertNil(LauncherRequestParser.resolveEndpoint(from: "https://github.com/a/b/pull/7/"))
        XCTAssertEqual(
            LauncherRequestParser.resolveEndpoint(from: "https://github.com/a/b/pull/7"),
            PREndpoint(owner: "a", repo: "b", number: 7)
        )
    }
}

extension LauncherRequestParserTests {
    func testRejectsSurroundingWhitespace() {
        XCTAssertNil(LauncherRequestParser.resolveEndpoint(from: " https://github.com/a/b/pull/7"))
        XCTAssertNil(LauncherRequestParser.resolveEndpoint(from: "https://github.com/a/b/pull/7 "))
    }
}

extension LauncherRequestParserTests {
    func testRejectsDoubledSlashes() {
        XCTAssertNil(LauncherRequestParser.resolveEndpoint(from: "https://github.com/a//b/pull/7"))
        XCTAssertNil(LauncherRequestParser.resolveEndpoint(from: "https://github.com/a/b//pull/7"))
    }

    func testRejectsNamesGhWouldInterpret() {
        XCTAssertNil(LauncherRequestParser.resolveEndpoint(from: "@etc/r#1"))
        XCTAssertNil(LauncherRequestParser.resolveEndpoint(from: "o/..#1"))
        XCTAssertNil(LauncherRequestParser.resolveEndpoint(from: "https://github.com/@etc/r/pull/1"))
        XCTAssertNil(LauncherRequestParser.appURL(for: "@etc/r#1"))
    }
}
