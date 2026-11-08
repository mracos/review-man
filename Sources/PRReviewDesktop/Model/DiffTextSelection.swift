import Foundation
import PRReviewKit

/// Text selected across diff rows, from where the drag started to where it
/// is now. Positions are display-row indexes and UTF-16 offsets into each
/// line's code, so the gutter never ends up in the copied text.
struct DiffTextSelection: Equatable {
    struct Position: Comparable {
        var row: Int
        var offset: Int

        static func < (lhs: Position, rhs: Position) -> Bool {
            (lhs.row, lhs.offset) < (rhs.row, rhs.offset)
        }
    }

    var anchor: Position
    var head: Position

    var isEmpty: Bool { anchor == head }

    private var start: Position { min(anchor, head) }
    private var end: Position { max(anchor, head) }

    /// The selected part of a row's code, or nil when the row is outside.
    func range(inRow row: Int, length: Int) -> Range<Int>? {
        guard !isEmpty, row >= start.row, row <= end.row else { return nil }
        let lower = row == start.row ? min(start.offset, length) : 0
        let upper = row == end.row ? min(end.offset, length) : length
        return lower..<max(lower, upper)
    }

    /// The selected code, one line per diff line; hunk headers, comment rows
    /// and other non-code rows are left out.
    func text(rows: [DiffDisplayRow], file: DiffFile) -> String {
        guard !isEmpty else { return "" }
        return (start.row...min(end.row, rows.count - 1)).compactMap { index -> String? in
            guard case .line(let hunk, let lineIndex) = rows[index].row,
                  let content = file.line(at: hunk, lineIndex)?.content else { return nil }
            let code = content as NSString
            guard let range = range(inRow: index, length: code.length) else { return nil }
            return code.substring(with: NSRange(location: range.lowerBound, length: range.count))
        }.joined(separator: "\n")
    }
}
