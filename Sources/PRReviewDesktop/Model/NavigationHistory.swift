import Foundation

/// Where a review window is looking: the change canvas or one file's diff.
public enum ReviewLocation: Equatable {
    case canvas
    case file(String)
}

/// Back/forward over visited locations, browser-style: visiting after going
/// back drops the forward entries, and the oldest entries fall off past
/// `limit`.
public struct NavigationHistory<Location: Equatable> {
    private(set) var entries: [Location] = []
    private(set) var index = -1
    let limit: Int

    public init(limit: Int = 100) {
        self.limit = limit
    }

    public var current: Location? { entries.indices.contains(index) ? entries[index] : nil }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count - 1 }

    public mutating func visit(_ location: Location) {
        guard location != current else { return }
        entries.removeSubrange((index + 1)..<entries.count)
        entries.append(location)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        index = entries.count - 1
    }

    public mutating func back() -> Location? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    public mutating func forward() -> Location? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }

    public mutating func reset() {
        entries = []
        index = -1
    }
}
