import Foundation
import PRReviewKit

/// Read-only load sequence for a review window: resolve, fetch, restore local
/// state, revalidate drafts, and build the presentation. Extracted so both the
/// demo and real paths share one implementation (and so Phase 6 can extend it
/// with the head-SHA migration shared with the TUI controller).
public struct ReviewSessionLoader {

    public let service: GitHubServing
    public let persistence: ReviewPersisting

    public init(service: GitHubServing, persistence: ReviewPersisting) {
        self.service = service
        self.persistence = persistence
    }

    /// Loads the built-in demo PR at the given scale (or custom file/line
    /// counts). Generation, parsing, draft revalidation, AND presentation
    /// assembly (rows, indexes, sidebar aggregation) all run off the main
    /// actor, so even a load-test-scale demo never freezes the window.
    public func loadDemo(scale: DemoScale = .small, files: Int? = nil, lines: Int? = nil) async throws -> ReviewPresentation {
        AppLog.info("load", "Starting demo load; scale=\(scale); requestedFiles=\(files.map(String.init) ?? "default"); requestedLines=\(lines.map(String.init) ?? "default")")
        let startedAt = Date()
        let presentation = await Task.detached(priority: .userInitiated) {
            let demo: DemoBundle = PerformanceLog.measure(
                name: "DemoFixtureBuild",
                label: "demo-fixture scale=\(scale)"
            ) {
                if let files, let lines {
                    return DemoData.makeDemoBundle(files: files, lines: lines)
                }
                return DemoData.makeDemoBundle(scale: scale)
            }
            let drafts = DraftAnchorValidator.revalidated(demo.drafts, against: demo.files)
            return PerformanceLog.measure(
                name: "PresentationBuild",
                label: "presentation-build files=\(demo.files.count) lines=\(demo.files.reduce(0) { $0 + $1.lineCount })",
                logDuration: true
            ) {
                ReviewPresentation(
                    endpoint: demo.endpoint,
                    pr: demo.pr,
                    files: demo.files,
                    threads: demo.threads,
                    drafts: drafts,
                    viewed: demo.viewed
                )
            }
        }.value
        AppLog.info("load", "Completed demo load; files=\(presentation.files.count); threads=\(presentation.threads.count); elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))")
        return presentation
    }

    /// Loads a qualified reference (full URL or `owner/repo#number`). Bare
    /// numbers are rejected: their resolution depends on the process current
    /// directory, which is unreliable for Finder-launched windows.
    public func load(
        reference: String,
        progress: @escaping @Sendable (LoadProgress.Event) -> Void = { _ in }
    ) async throws -> ReviewPresentation {
        AppLog.info("load", "Starting PR load for \(reference)")
        let startedAt = Date()
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LoadError.invalidReference
        }
        let looksBare = trimmed.allSatisfy { $0.isNumber }
        guard !looksBare else {
            throw LoadError.bareNumberNotSupported
        }

        try await service.ensureAvailable()
        let endpoint = try await service.resolveEndpoint(from: trimmed)
        AppLog.info("load", "Resolved load reference to \(endpoint)")
        progress(.stage(.fetching))
        let bundle = try await service.fetchAll(endpoint) { progress(.fetch($0)) }
        progress(.stage(.preparing))
        AppLog.info("load", "Fetched PR bundle for \(endpoint); files=\(bundle.files.count); threads=\(bundle.threads.count)")

        let drafts = try await persistence.loadDrafts(for: endpoint, headSHA: bundle.pr.headRefOid)
        let viewed = try await persistence.loadViewed(for: endpoint, headSHA: bundle.pr.headRefOid)
        // PR-scoped: hidden-reviewer state is shared across head changes.
        let hiddenReviewers = try await persistence.loadHiddenReviewers(for: endpoint)
        AppLog.info("load", "Restored local state for \(endpoint); drafts=\(drafts.count); viewed=\(viewed.count); hiddenReviewers=\(hiddenReviewers.count)")

        // Draft revalidation + presentation assembly happen off the main actor;
        // only the completed immutable snapshot is handed back.
        let presentation = await Task.detached(priority: .userInitiated) {
            let validated = DraftAnchorValidator.revalidated(drafts, against: bundle.files)
            return PerformanceLog.measure(
                name: "PresentationBuild",
                label: "presentation-build files=\(bundle.files.count) lines=\(bundle.files.reduce(0) { $0 + $1.lineCount })",
                logDuration: true
            ) {
                ReviewPresentation(
                    endpoint: endpoint,
                    pr: bundle.pr,
                    files: bundle.files,
                    threads: bundle.threads,
                    drafts: validated,
                    viewed: viewed,
                    hiddenReviewers: hiddenReviewers
                )
            }
        }.value
        AppLog.info("load", "Completed PR load for \(endpoint); files=\(presentation.files.count); orphanedDrafts=\(presentation.drafts.filter(\.isOrphaned).count); elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))")
        return presentation
    }

    public enum LoadError: Error, LocalizedError {
        case invalidReference
        case bareNumberNotSupported

        public var errorDescription: String? {
            switch self {
            case .invalidReference:
                return "Enter a full GitHub PR URL or owner/repo#number."
            case .bareNumberNotSupported:
                return "Bare numbers work from the terminal launcher (which knows the repository); use a full URL or owner/repo#number here."
            }
        }
    }
}
