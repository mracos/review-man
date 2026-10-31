import XCTest
@testable import PRReviewKit

final class ContextExpansionTests: XCTestCase {

    /// The head version of a 30-line file whose lines 10 and 25 changed.
    private let newFile = (1...30).map { $0 == 10 || $0 == 25 ? "new \($0)" : "line \($0)" }

    private func file() -> DiffFile {
        func hunk(around changed: Int) -> String {
            var lines = ["@@ -\(changed - 3),7 +\(changed - 3),7 @@"]
            for n in (changed - 3)...(changed + 3) {
                if n == changed {
                    lines += ["-old \(n)", "+new \(n)"]
                } else {
                    lines.append(" line \(n)")
                }
            }
            return lines.joined(separator: "\n")
        }
        let patch = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        \(hunk(around: 10))
        \(hunk(around: 25))
        """
        return DiffParser.parse(patch)[0]
    }

    func testHiddenLinesComeFromTheHunkHeaders() {
        let file = file()

        XCTAssertEqual(file.hiddenLinesAbove(hunk: 0), 6)
        XCTAssertEqual(file.hiddenLinesAbove(hunk: 1), 8)
        XCTAssertEqual(file.hiddenLinesAbove(hunk: 2), 0)
    }

    func testExpandingRevealsContextWithBothLineNumbers() {
        let expanded = file().expandingContext(aboveHunk: 1, count: 3, newFileLines: newFile)

        let hunk = expanded.hunks[1]
        XCTAssertEqual(Array(hunk.lines.prefix(3)), [
            DiffLine(kind: .context, content: "line 19", oldLine: 19, newLine: 19),
            DiffLine(kind: .context, content: "line 20", oldLine: 20, newLine: 20),
            DiffLine(kind: .context, content: "line 21", oldLine: 21, newLine: 21),
        ])
        XCTAssertEqual(hunk.newStart, 19)
        XCTAssertEqual(hunk.newCount, 10)
        XCTAssertEqual(hunk.oldStart, 19)
        XCTAssertEqual(expanded.hiddenLinesAbove(hunk: 1), 5)
    }

    func testClosingTheGapMergesWithThePreviousHunk() {
        let expanded = file().expandingContext(aboveHunk: 1, count: 100, newFileLines: newFile)

        XCTAssertEqual(expanded.hunks.count, 1)
        XCTAssertEqual(expanded.hunks[0].newStart, 7)
        XCTAssertEqual(expanded.hunks[0].newCount, 22)
        let newLines = expanded.hunks[0].lines.compactMap(\.newLine)
        XCTAssertEqual(newLines, Array(7...28))
    }

    func testExpandingTheTopReachesLineOne() {
        let expanded = file().expandingContext(aboveHunk: 0, count: 100, newFileLines: newFile)

        XCTAssertEqual(expanded.hunks[0].newStart, 1)
        XCTAssertEqual(expanded.hunks[0].lines.first, DiffLine(kind: .context, content: "line 1", oldLine: 1, newLine: 1))
        XCTAssertEqual(expanded.hiddenLinesAbove(hunk: 0), 0)
    }

    /// A deletion-only hunk (`+N,0`) sits after new line N, so the hidden
    /// lines above it run through N.
    func testDeletionOnlyHunkCountsTheLinesThroughItsAnchor() {
        let patch = """
        diff --git a/b.txt b/b.txt
        --- a/b.txt
        +++ b/b.txt
        @@ -5,1 +4,0 @@
        -gone
        """
        let file = DiffParser.parse(patch)[0]
        let lines = (1...6).map { "line \($0)" }

        XCTAssertEqual(file.hiddenLinesAbove(hunk: 0), 4)
        let expanded = file.expandingContext(aboveHunk: 0, count: 2, newFileLines: lines)
        XCTAssertEqual(expanded.hunks[0].lines.prefix(2).map(\.newLine), [3, 4])
        XCTAssertEqual(expanded.hunks[0].lines.prefix(2).map(\.oldLine), [3, 4])
        XCTAssertEqual(expanded.hiddenLinesAbove(hunk: 0), 2)
    }

    func testExpandingWithTooShortAFileChangesNothing() {
        let original = file()

        XCTAssertEqual(original.expandingContext(aboveHunk: 1, count: 3, newFileLines: ["only"]), original)
    }
}
