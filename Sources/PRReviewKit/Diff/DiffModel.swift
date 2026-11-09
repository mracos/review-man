import Foundation

public enum FileStatus: String, Equatable, CaseIterable {
    case added
    case deleted
    case modified
    case renamed

    public var letter: String {
        switch self {
        case .added: return "A"
        case .deleted: return "D"
        case .modified: return "M"
        case .renamed: return "R"
        }
    }
}

public struct DiffLine: Equatable {
    public enum Kind: Equatable {
        case context
        case added
        case removed
    }

    public var kind: Kind
    public var content: String
    public var oldLine: Int?
    public var newLine: Int?
    /// Character-offset range into `content` that changed (word diff).
    public var emphasis: Range<Int>?

    public init(kind: Kind, content: String, oldLine: Int?, newLine: Int?, emphasis: Range<Int>? = nil) {
        self.kind = kind
        self.content = content
        self.oldLine = oldLine
        self.newLine = newLine
        self.emphasis = emphasis
    }
}

public struct DiffHunk: Equatable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var context: String
    public var lines: [DiffLine]

    public var header: String {
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
            + (context.isEmpty ? "" : " " + context)
    }

    public var additions: Int { lines.filter { $0.kind == .added }.count }
    public var deletions: Int { lines.filter { $0.kind == .removed }.count }
}

public struct DiffFile: Equatable {
    public var oldPath: String?
    public var newPath: String?
    public var status: FileStatus = .modified
    public var hunks: [DiffHunk] = []
    public var isBinary = false
    /// True when the diff payload could not be fetched (too-large fallback).
    public var tooLarge = false

    public init() {}

    public var path: String { newPath ?? oldPath ?? "" }

    public var additions: Int {
        hunks.reduce(0) { $0 + $1.additions }
    }

    public var deletions: Int {
        hunks.reduce(0) { $0 + $1.deletions }
    }

    public var lineCount: Int {
        hunks.reduce(0) { $0 + $1.lines.count }
    }

    /// Number of columns needed for the widest old or new line number.
    public var gutterDigits: Int {
        var maxV = 0
        for hunk in hunks {
            maxV = max(maxV, hunk.oldStart + hunk.oldCount, hunk.newStart + hunk.newCount)
        }
        return max(3, String(maxV).count)
    }

    public func line(at hunkIndex: Int, _ lineIndex: Int) -> DiffLine? {
        guard hunkIndex >= 0, hunkIndex < hunks.count else { return nil }
        let h = hunks[hunkIndex]
        guard lineIndex >= 0, lineIndex < h.lines.count else { return nil }
        return h.lines[lineIndex]
    }
}
