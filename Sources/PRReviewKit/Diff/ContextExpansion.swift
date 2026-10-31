import Foundation

/// Revealing unchanged lines between hunks ("expand context"), from the
/// head version of the file. Pure: the result is a new `DiffFile` whose hunks
/// grow upward and merge once the gap between them closes.
public extension DiffHunk {
    /// First new-file line the hunk covers. A deletion-only hunk (`+N,0`)
    /// sits after line N, so its first line is N + 1 and its last is N.
    var newTop: Int { newCount == 0 ? newStart + 1 : newStart }
    var newBottom: Int { newCount == 0 ? newStart : newStart + newCount - 1 }
    var oldTop: Int { oldCount == 0 ? oldStart + 1 : oldStart }
}

public extension DiffFile {
    /// New-file lines hidden between hunk `index` and the one above it (or
    /// the top of the file).
    func hiddenLinesAbove(hunk index: Int) -> Int {
        guard hunks.indices.contains(index) else { return 0 }
        let previousBottom = index == 0 ? 0 : hunks[index - 1].newBottom
        return max(0, hunks[index].newTop - previousBottom - 1)
    }

    /// Reveals up to `count` hidden lines directly above hunk `index`, read
    /// from `newFileLines` (the head file, line 1 first). Unchanged when
    /// nothing is hidden or the file is shorter than the hunks claim.
    func expandingContext(aboveHunk index: Int, count: Int, newFileLines: [String]) -> DiffFile {
        let hidden = hiddenLinesAbove(hunk: index)
        let revealedCount = min(count, hidden)
        guard revealedCount > 0 else { return self }
        var hunk = hunks[index]
        let top = hunk.newTop
        let firstLine = top - revealedCount
        guard firstLine >= 1, top - 1 <= newFileLines.count else { return self }

        // Unchanged lines keep the hunk's old/new offset.
        let offset = hunk.oldTop - top
        let revealed = (firstLine..<top).map { line in
            DiffLine(kind: .context, content: newFileLines[line - 1], oldLine: line + offset, newLine: line)
        }
        hunk.lines = revealed + hunk.lines
        hunk.newStart = firstLine
        hunk.newCount += revealedCount
        hunk.oldStart = firstLine + offset
        hunk.oldCount += revealedCount

        var result = self
        if revealedCount == hidden, index > 0 {
            var previous = hunks[index - 1]
            let newTop = previous.newTop
            let oldTop = previous.oldTop
            previous.lines += hunk.lines
            previous.newCount += hunk.newCount
            previous.oldCount += hunk.oldCount
            if previous.newCount > 0 { previous.newStart = newTop }
            if previous.oldCount > 0 { previous.oldStart = oldTop }
            result.hunks[index - 1] = previous
            result.hunks.remove(at: index)
        } else {
            result.hunks[index] = hunk
        }
        return result
    }
}
