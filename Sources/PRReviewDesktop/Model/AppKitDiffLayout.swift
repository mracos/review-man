import Foundation
import PRReviewKit

/// Geometry constants for the custom AppKit diff renderer.
/// Normal code rows have a fixed height; comment and status rows have larger
/// fixed estimates until the interaction phase adds measured overlays.
public struct AppKitDiffLayoutMetrics: Equatable {
    public static let `default` = AppKitDiffLayoutMetrics()

    public let lineHeight: CGFloat
    public let hunkHeight: CGFloat
    public let commentHeight: CGFloat
    public let statusHeight: CGFloat
    public let characterWidth: CGFloat
    public let minimumContentWidth: CGFloat
    /// Point size of the monospaced code font every other metric is sized for.
    public let fontSize: CGFloat

    /// Metrics for a code font size, scaling every row height and the
    /// character width; 12 pt gives exactly the defaults.
    public static func forFontSize(_ size: CGFloat) -> AppKitDiffLayoutMetrics {
        let scale = size / 12
        return AppKitDiffLayoutMetrics(
            lineHeight: (18 * scale).rounded(),
            hunkHeight: (24 * scale).rounded(),
            commentHeight: (38 * scale).rounded(),
            statusHeight: (24 * scale).rounded(),
            characterWidth: 7.2 * scale,
            fontSize: size
        )
    }

    public init(
        lineHeight: CGFloat = 18,
        hunkHeight: CGFloat = 24,
        commentHeight: CGFloat = 38,
        statusHeight: CGFloat = 24,
        characterWidth: CGFloat = 7.2,
        minimumContentWidth: CGFloat = 900,
        fontSize: CGFloat = 12
    ) {
        self.lineHeight = lineHeight
        self.hunkHeight = hunkHeight
        self.commentHeight = commentHeight
        self.statusHeight = statusHeight
        self.characterWidth = characterWidth
        self.minimumContentWidth = minimumContentWidth
        self.fontSize = fontSize
    }

    public func height(for row: Row) -> CGFloat {
        switch row {
        case .hunkHeader: return hunkHeight
        case .line: return lineHeight
        case .thread, .draft: return commentHeight
        case .outdatedHeader, .orphanedHeader, .empty: return statusHeight
        }
    }

    public func contentWidth(file: DiffFile, rows: [DiffDisplayRow]) -> CGFloat {
        let maximumCharacters = file.hunks.reduce(0) { current, hunk in
            max(current, hunk.lines.reduce(0) { max($0, $1.content.count) })
        }
        let gutterWidth = CGFloat(file.gutterDigits * 2 + 3) * characterWidth + 14
        let codeWidth = CGFloat(maximumCharacters) * characterWidth + 24
        let attachedRowWidth: CGFloat = rows.contains { displayRow in
            switch displayRow.row {
            case .thread, .draft: return true
            default: return false
            }
        } ? 240 : 0
        return max(minimumContentWidth, gutterWidth + codeWidth, attachedRowWidth)
    }
}

/// Immutable row geometry for one file. The index is authoritative for
/// drawing and scrolling; row lookup uses binary search over cumulative Y
/// offsets rather than scanning from the top of a large file.
public struct AppKitDiffLayout {
    public struct PositionedRow {
        public let row: DiffDisplayRow
        public let originY: CGFloat
        public let height: CGFloat

        public var id: DiffRowID { row.id }
        public var maxY: CGFloat { originY + height }
    }

    public let metrics: AppKitDiffLayoutMetrics
    public let rows: [PositionedRow]
    public let contentWidth: CGFloat
    public let contentHeight: CGFloat

    private let indexByID: [DiffRowID: Int]

    public init(
        file: DiffFile,
        rows: [DiffDisplayRow],
        metrics: AppKitDiffLayoutMetrics = .default,
        rowHeightOverrides: [DiffRowID: CGFloat] = [:]
    ) {
        self.metrics = metrics
        contentWidth = metrics.contentWidth(file: file, rows: rows)

        var positioned: [PositionedRow] = []
        positioned.reserveCapacity(rows.count)
        var indexByID: [DiffRowID: Int] = [:]
        indexByID.reserveCapacity(rows.count)
        var originY: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let height = max(1, rowHeightOverrides[row.id] ?? metrics.height(for: row.row))
            positioned.append(PositionedRow(row: row, originY: originY, height: height))
            indexByID[row.id] = index
            originY += height
        }
        self.rows = positioned
        contentHeight = originY
        self.indexByID = indexByID
    }

    /// Returns the row containing the given document-space Y coordinate.
    public func row(atY y: CGFloat) -> PositionedRow? {
        guard y >= 0, y < contentHeight else { return nil }
        let index = firstRowIndex(whoseMaxYIsGreaterThan: y)
        guard rows.indices.contains(index) else { return nil }
        return rows[index]
    }

    public func rowIndex(for id: DiffRowID) -> Int? {
        indexByID[id]
    }

    public func row(for id: DiffRowID) -> PositionedRow? {
        guard let index = indexByID[id] else { return nil }
        return rows[index]
    }

    public func frame(for id: DiffRowID) -> CGRect? {
        guard let row = row(for: id) else { return nil }
        return CGRect(x: 0, y: row.originY, width: contentWidth, height: row.height)
    }

    /// Returns the rows intersecting a visible rectangle, with optional
    /// document-space overscan on both sides.
    public func visibleRange(in rect: CGRect, overscan: CGFloat = 0) -> Range<Int> {
        guard !rows.isEmpty, contentHeight > 0 else { return 0..<0 }
        let padding = max(0, overscan)
        let lowerY = max(0, rect.minY - padding)
        let upperY = min(contentHeight, rect.maxY + padding)
        guard upperY > lowerY else { return 0..<0 }

        let start = firstRowIndex(whoseMaxYIsGreaterThan: lowerY)
        let end = firstRowIndex(whoseOriginYIsAtLeast: upperY)
        let boundedStart = min(start, rows.count)
        let boundedEnd = min(max(end, boundedStart + 1), rows.count)
        return boundedStart..<boundedEnd
    }

    /// Calculates a document-space vertical origin for a row. `alignment` is
    /// 0 for top, 0.5 for center and 1 for bottom alignment.
    public func scrollOrigin(
        for id: DiffRowID,
        viewportHeight: CGFloat,
        alignment: CGFloat = 0.5
    ) -> CGFloat? {
        guard let row = row(for: id) else { return nil }
        let clampedAlignment = min(max(alignment, 0), 1)
        let desired = row.originY - max(0, viewportHeight - row.height) * clampedAlignment
        let maximumOrigin = max(0, contentHeight - max(0, viewportHeight))
        return min(max(0, desired), maximumOrigin)
    }

    private func firstRowIndex(whoseMaxYIsGreaterThan y: CGFloat) -> Int {
        var lowerBound = 0
        var upperBound = rows.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if rows[middle].maxY <= y {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private func firstRowIndex(whoseOriginYIsAtLeast y: CGFloat) -> Int {
        var lowerBound = 0
        var upperBound = rows.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if rows[middle].originY < y {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }
}

/// Immutable input handed to either AppKit prototype. Keeping the file,
/// display rows and geometry together prevents the two renderers from
/// calculating different positions for the same diff.
public struct AppKitDiffRenderSnapshot {
    public let file: DiffFile
    public let rows: [DiffDisplayRow]
    public let languageID: Int?
    public let layout: AppKitDiffLayout

    public init(
        file: DiffFile,
        rows: [DiffDisplayRow],
        metrics: AppKitDiffLayoutMetrics = .default,
        rowHeightOverrides: [DiffRowID: CGFloat] = [:]
    ) {
        self.file = file
        self.rows = rows
        languageID = Highlighter.languageID(for: file.path)
        layout = AppKitDiffLayout(
            file: file,
            rows: rows,
            metrics: metrics,
            rowHeightOverrides: rowHeightOverrides
        )
    }

    public func applyingRowHeightOverrides(_ overrides: [DiffRowID: CGFloat]) -> AppKitDiffRenderSnapshot {
        AppKitDiffRenderSnapshot(
            file: file,
            rows: rows,
            metrics: layout.metrics,
            rowHeightOverrides: overrides
        )
    }
}
