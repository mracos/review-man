import Foundation

/// Whether viewed marks are mirrored to GitHub's own "viewed" state. Off by
/// default: turning it on makes toggling a file a write to github.com.
public final class ViewedSyncPreference {

    public static let key = "PRReview.syncViewedWithGitHub"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
