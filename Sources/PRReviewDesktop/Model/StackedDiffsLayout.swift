import Foundation
import PRReviewKit

/// Rules for the stacked "List" overview, which renders every file's diff in
/// one scroll.
public enum StackedDiffsLayout {
    /// Files with more diff lines than this start collapsed, so opening a
    /// large pull request does not lay out every line up front.
    public static let rowBudget = 400

    /// Viewed, binary, too-large and very long files start collapsed.
    public static func isCollapsedByDefault(_ file: DiffFile, isViewed: Bool) -> Bool {
        isViewed || file.isBinary || file.tooLarge || file.lineCount > rowBudget
    }
}
