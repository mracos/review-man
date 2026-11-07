import Foundation

public enum BulkViewedScope: Equatable {
    case all
    case deleted
    /// Renames and moves that change no lines.
    case pureRenames
    case folder(String)
    case fileExtension(String)
    case paths([String])

    public func paths(in items: [FileSidebarItem]) -> [String] {
        if case .paths(let paths) = self {
            // A sidebar selection can hold thousands of paths.
            let wanted = Set(paths)
            return items.lazy.map(\.path).filter(wanted.contains)
        }
        return items.filter(matches).map(\.path)
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

    /// Nil for names without one (`Makefile`) and for dotfiles (`.gitignore`).
    public static func fileExtension(of path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        return ext.isEmpty ? nil : String(ext)
    }
}
