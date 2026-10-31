import SwiftUI

/// The diff's code font size, app-wide and remembered across launches.
/// Cmd-+ / Cmd-- change it while a file is open (they zoom the canvas
/// otherwise); Cmd-0 goes back to `defaultSize`.
public enum DiffTextSize {
    public static let key = "PRReview.diffFontSize"
    public static let defaultSize: CGFloat = 12
    public static let minimum: CGFloat = 9
    public static let maximum: CGFloat = 24

    public static func stepped(_ size: CGFloat, by delta: CGFloat) -> CGFloat {
        min(maximum, max(minimum, size + delta))
    }
}

private struct DiffFontSizeKey: EnvironmentKey {
    static let defaultValue = DiffTextSize.defaultSize
}

extension EnvironmentValues {
    /// Point size for diff code text in the SwiftUI renderers.
    var diffFontSize: CGFloat {
        get { self[DiffFontSizeKey.self] }
        set { self[DiffFontSizeKey.self] = newValue }
    }
}
