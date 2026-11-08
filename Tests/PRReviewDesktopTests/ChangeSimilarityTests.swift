import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

final class ChangeSimilarityTests: XCTestCase {

    func testSignatureKeepsOnlyChangedLinesTrimmed() throws {
        let file = try XCTUnwrap(DiffParser.parse("""
        diff --git a/a.js b/a.js
        --- a/a.js
        +++ b/a.js
        @@ -1,3 +1,4 @@
         context stays out
        -  import x from 'old'
        +import x from 'new'
        +
        """).first)

        XCTAssertEqual(ChangeSimilarity.signature(of: file), ["-import x from 'old'", "+import x from 'new'"])
    }

    func testFileWithoutChangedLinesHasNoSignature() {
        XCTAssertNil(ChangeSimilarity.signature(of: DiffFile()))
    }

    func testSameAndSimilarPaths() {
        let rewrite: Set<String> = ["-import old", "+import new"]
        let signatures: [(path: String, signature: Set<String>)] = [
            ("a.js", rewrite),
            ("b.js", rewrite),
            ("c.js", rewrite.union(["+extra()"])),
            ("d.js", ["+unrelated()"]),
        ]

        XCTAssertEqual(ChangeSimilarity.paths(similarTo: "a.js", minimum: 1, signatures: signatures), ["a.js", "b.js"])
        XCTAssertEqual(
            ChangeSimilarity.paths(similarTo: "a.js", minimum: ChangeSimilarity.similarThreshold, signatures: signatures),
            ["a.js", "b.js", "c.js"]
        )
        XCTAssertEqual(ChangeSimilarity.paths(similarTo: "missing.js", minimum: 1, signatures: signatures), [])
    }
}
