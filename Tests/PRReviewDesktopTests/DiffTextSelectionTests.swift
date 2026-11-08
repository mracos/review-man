import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

final class DiffTextSelectionTests: XCTestCase {

    private let file = DiffParser.parse("""
    diff --git a/A.swift b/A.swift
    --- a/A.swift
    +++ b/A.swift
    @@ -1,3 +1,3 @@
     let one = 1
    -let two = 2
    +let two = 22
     let three = 3
    """)[0]

    private var rows: [DiffDisplayRow] {
        ReviewPresentation(endpoint: nil, pr: nil, files: [file], threads: [], drafts: [], viewed: []).diffRows(for: file)
    }

    private func at(_ row: Int, _ offset: Int) -> DiffTextSelection.Position {
        DiffTextSelection.Position(row: row, offset: offset)
    }

    func testCopiesCodeAcrossLinesSkippingTheHunkHeader() {
        let selection = DiffTextSelection(anchor: at(0, 0), head: at(2, 7))

        XCTAssertEqual(selection.text(rows: rows, file: file), "let one = 1\nlet two")
    }

    func testDraggingBackwardsSelectsTheSameText() {
        let forward = DiffTextSelection(anchor: at(1, 4), head: at(3, 3))
        let backward = DiffTextSelection(anchor: at(3, 3), head: at(1, 4))

        XCTAssertEqual(backward.text(rows: rows, file: file), forward.text(rows: rows, file: file))
        XCTAssertEqual(forward.text(rows: rows, file: file), "one = 1\nlet two = 2\nlet")
    }

    func testRangesClampToTheLineAndEmptySelectionsCopyNothing() {
        let selection = DiffTextSelection(anchor: at(1, 4), head: at(2, 99))

        XCTAssertEqual(selection.range(inRow: 1, length: 11), 4..<11)
        XCTAssertEqual(selection.range(inRow: 2, length: 11), 0..<11)
        XCTAssertNil(selection.range(inRow: 3, length: 11))
        XCTAssertEqual(DiffTextSelection(anchor: at(1, 2), head: at(1, 2)).text(rows: rows, file: file), "")
    }
}
