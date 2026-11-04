import Foundation

/// A group of files to mark viewed (or unviewed) in one go.
public enum BulkViewedScope: Equatable {
    case all
    /// Files the pull request deletes.
    case deleted
    /// Renames and moves that change no lines.
    case pureRenames
    /// Every file under a folder, at any depth.
    case folder(String)
    /// Every file sharing an extension, such as `lock` or `snap`.
    case fileExtension(String)
    /// The given paths, such as the sidebar's current filter results.
    case paths([String])

    public func paths(in items: [FileSidebarItem]) -> [String] {
        items.filter(matches).map(\.path)
    }

    private func matches(_ item: FileSidebarItem) -> Bool {
        switch self {
        case .all:
            return true
        case .deleted:
            return item.statusLetter == "D"
        case .pureRenames:
            return item.statusLetter == "R" && item.additions == 0 && item.deletions == 0
        case .folder(let folder):
            return item.path.hasPrefix(folder + "/")
        case .fileExtension(let ext):
            return Self.fileExtension(of: item.path) == ext
        case .paths(let paths):
            return paths.contains(item.path)
        }
    }

    /// The extension after the last dot of the file name, or nil for names
    /// without one (`Makefile`) or dotfiles (`.gitignore`).
    public static func fileExtension(of path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        return ext.isEmpty ? nil : String(ext)
    }
}
