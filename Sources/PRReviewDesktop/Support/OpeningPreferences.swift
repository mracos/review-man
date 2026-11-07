import Foundation

/// The pane a pull request opens in.
public enum OpeningPane: String, CaseIterable, Identifiable {
    /// Whichever overview, canvas or list, was picked last.
    case lastOverview
    case canvas
    case list
    case firstFile

    public static let key = "PRReview.openingPane"

    public var id: Self { self }

    public var title: String {
        switch self {
        case .lastOverview: return "Last used overview"
        case .canvas: return "Canvas"
        case .list: return "List"
        case .firstFile: return "First file"
        }
    }
}

/// What the sidebar shows when a pull request opens.
public enum OpeningSidebar: String, CaseIterable, Identifiable {
    /// Hidden on the window's first pull request, then as the reviewer left it.
    case unchanged
    case files

    public static let key = "PRReview.openingSidebar"

    public var id: Self { self }

    public var title: String {
        switch self {
        case .unchanged: return "Leave as is"
        case .files: return "Files"
        }
    }
}

/// How the window looks each time a pull request finishes loading.
public struct OpeningPreferences {

    public static let diffLayoutKey = "PRReview.openingDiffLayout"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var pane: OpeningPane {
        defaults.string(forKey: OpeningPane.key).flatMap(OpeningPane.init(rawValue:)) ?? .lastOverview
    }

    public var diffLayout: DiffPresentation {
        defaults.string(forKey: Self.diffLayoutKey).flatMap(DiffPresentation.init(rawValue:)) ?? .unified
    }

    public var sidebar: OpeningSidebar {
        defaults.string(forKey: OpeningSidebar.key).flatMap(OpeningSidebar.init(rawValue:)) ?? .unchanged
    }

    /// The overview to show, or nil to open the selected file.
    public func overview(lastUsed: OverviewMode) -> OverviewMode? {
        switch pane {
        case .lastOverview: return lastUsed
        case .canvas: return .canvas
        case .list: return .list
        case .firstFile: return nil
        }
    }
}
