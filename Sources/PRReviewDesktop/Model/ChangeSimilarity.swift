import Foundation
import PRReviewKit

/// Compares what files change, so a change repeated across many files (an
/// import rewrite, a renamed call) can be marked viewed in one go.
public enum ChangeSimilarity {

    /// Share of changed lines two files must have in common to count as a
    /// similar change: one extra line next to a two-line rewrite still is.
    public static let similarThreshold = 0.6

    /// The file's removed and added lines, whitespace-trimmed, without blank
    /// lines or context. Nil when there is nothing to compare (binary, too
    /// large, or a pure rename).
    public static func signature(of file: DiffFile) -> Set<String>? {
        var lines: Set<String> = []
        for hunk in file.hunks {
            for line in hunk.lines where line.kind != .context {
                let text = line.content.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                lines.insert((line.kind == .added ? "+" : "-") + text)
            }
        }
        return lines.isEmpty ? nil : lines
    }

    /// Jaccard similarity: shared lines over all distinct lines.
    public static func similarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs).count
        return union == 0 ? 0 : Double(lhs.intersection(rhs).count) / Double(union)
    }

    /// Paths whose change is at least `minimum` similar to `path`'s, the
    /// file itself included, in `signatures` order.
    public static func paths(
        similarTo path: String,
        minimum: Double,
        signatures: [(path: String, signature: Set<String>)]
    ) -> [String] {
        guard let reference = signatures.first(where: { $0.path == path })?.signature else { return [] }
        if minimum >= 1 {
            return signatures.filter { $0.signature == reference }.map(\.path)
        }
        return signatures.filter { similarity(reference, $0.signature) >= minimum }.map(\.path)
    }
}
