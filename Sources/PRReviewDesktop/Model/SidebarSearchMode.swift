import Foundation

/// What the sidebar's file filter matches against.
public enum SidebarSearchMode: String, CaseIterable, Identifiable {
    /// A case-insensitive piece of the path.
    case paths
    /// A regular expression searched for in the path.
    case pathRegex
    /// A regular expression searched for in the lines a file adds or removes.
    case changedLines

    public var id: Self { self }

    public var title: String {
        switch self {
        case .paths: return "Paths"
        case .pathRegex: return "Paths (Regex)"
        case .changedLines: return "Changed Lines (Regex)"
        }
    }

    public var placeholder: String {
        switch self {
        case .paths: return "Filter files"
        case .pathRegex: return "Regex on paths"
        case .changedLines: return "Regex on changed lines"
        }
    }

    public var isRegex: Bool { self != .paths }
}
