import Foundation
import PRReviewKit

/// How far a pull request load has got, for the loading screen. Big pull
/// requests take many requests, and without this the window only spins.
public struct LoadProgress: Equatable {

    public enum Stage: Int, Comparable, Sendable {
        case connecting
        case fetching
        case preparing

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Event: Equatable, Sendable {
        case stage(Stage)
        case fetch(FetchProgress)
    }

    public private(set) var stage: Stage = .connecting
    public private(set) var changedFiles: Int?
    public private(set) var additions: Int?
    public private(set) var deletions: Int?
    public private(set) var fetchedFiles = 0
    public private(set) var diffRefused = false
    public let startedAt: Date

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    /// Events arrive from concurrent fetches, so neither the stage nor the
    /// file count ever moves backwards.
    public mutating func apply(_ event: Event) {
        switch event {
        case .stage(let next):
            stage = max(stage, next)
        case .fetch(.size(let files, let added, let deleted)):
            changedFiles = files
            additions = added
            deletions = deleted
        case .fetch(.diffRefused):
            diffRefused = true
        case .fetch(.filesFetched(let count)):
            fetchedFiles = max(fetchedFiles, count)
        }
    }

    public var headline: String {
        switch stage {
        case .connecting:
            return "Connecting to GitHub"
        case .fetching where diffRefused:
            if let total = changedFiles {
                return "Fetching files: \(fetchedFiles.formatted()) of \(min(total, GitHubClient.maxListedFiles).formatted())"
            }
            return "Fetching files: \(fetchedFiles.formatted())"
        case .fetching:
            return "Fetching the diff"
        case .preparing:
            return "Preparing \(changedFiles.map { "\($0.formatted()) files" } ?? "the review")"
        }
    }

    /// The pull request's size, once known.
    public var sizeSummary: String? {
        guard let changedFiles, let additions, let deletions else { return nil }
        return "\(changedFiles.formatted()) \(changedFiles == 1 ? "file" : "files") · +\(additions.formatted()) −\(deletions.formatted())"
    }

    public var note: String? {
        guard diffRefused else { return nil }
        return "Too big for GitHub to send as one diff, so files come 100 at a time."
    }

    /// Determinate only while paging through files of a known total.
    public var fractionCompleted: Double? {
        guard stage == .fetching, diffRefused, let total = changedFiles, total > 0 else { return nil }
        return min(1, Double(fetchedFiles) / Double(min(total, GitHubClient.maxListedFiles)))
    }
}
