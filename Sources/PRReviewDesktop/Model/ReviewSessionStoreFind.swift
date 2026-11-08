import Foundation
import PRReviewKit

/// One occurrence of the find query: a code line and the UTF-16 range in it.
public struct DiffFindMatch: Equatable {
    public let rowID: DiffRowID
    public let range: Range<Int>
}

/// Find in the open file's code, case-insensitive. The current match becomes
/// the selected line (so the diff scrolls to it) and the diff's selected text.
public extension ReviewSessionStore {

    func beginFind() {
        isFinding = true
    }

    func endFind() {
        isFinding = false
        findMatch = nil
    }

    /// Jumps to the first match at or after the selected line.
    func setFindQuery(_ query: String) {
        findQuery = query
        let matches = findMatches
        guard !matches.isEmpty else {
            findMatch = nil
            return
        }
        let rows = selectedFileRowIndexes
        let from = selection.rowID.flatMap { rows[$0] } ?? 0
        show(matches.first { (rows[$0.rowID] ?? 0) >= from } ?? matches[0])
    }

    func findNext() { stepFind(1) }

    func findPrevious() { stepFind(-1) }

    /// 1-based index of the current match and how many there are.
    var findMatchPosition: (index: Int, count: Int)? {
        guard isFinding, !findQuery.isEmpty else { return nil }
        let matches = findMatches
        return ((findMatch.flatMap(matches.firstIndex(of:)) ?? -1) + 1, matches.count)
    }

    var findMatches: [DiffFindMatch] {
        guard !findQuery.isEmpty, let file = selectedFile, let review else { return [] }
        return review.diffRows(for: file).flatMap { row -> [DiffFindMatch] in
            guard case .line(let hunk, let index) = row.row,
                  let content = file.line(at: hunk, index)?.content else { return [] }
            let code = content as NSString
            var matches: [DiffFindMatch] = []
            var searchRange = NSRange(location: 0, length: code.length)
            while true {
                let found = code.range(of: findQuery, options: .caseInsensitive, range: searchRange)
                guard found.location != NSNotFound, found.length > 0 else { break }
                matches.append(DiffFindMatch(rowID: row.id, range: found.location..<NSMaxRange(found)))
                searchRange = NSRange(location: NSMaxRange(found), length: code.length - NSMaxRange(found))
            }
            return matches
        }
    }

    private var selectedFileRowIndexes: [DiffRowID: Int] {
        guard let file = selectedFile, let review else { return [:] }
        return Dictionary(review.diffRows(for: file).enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func stepFind(_ delta: Int) {
        let matches = findMatches
        guard !matches.isEmpty else { return }
        guard let current = findMatch.flatMap(matches.firstIndex(of:)) else {
            show(matches[delta > 0 ? 0 : matches.count - 1])
            return
        }
        show(matches[(current + delta + matches.count) % matches.count])
    }

    private func show(_ match: DiffFindMatch) {
        findMatch = match
        selection.rowID = match.rowID
    }
}
