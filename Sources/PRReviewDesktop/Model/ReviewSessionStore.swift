import Foundation
import Combine
import PRReviewKit

/// A nonmodal status banner (message + whether it is an error).
public struct SessionBanner: Equatable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// Where a command asks the window to move focus.
public enum ReviewFocusTarget: Equatable {
    case sidebarSearch
    case diff
    case submitSheet
    case none
}

/// The desktop session store: owns the GitHub service, persistence, a
/// per-window syntax token cache, and the load lifecycle. All state is
/// published on the main actor. Phase 5 is read-only; Phase 6 adds review
/// operations through a shared core service rather than the TUI controller.
@MainActor
public final class ReviewSessionStore: ObservableObject {

    @Published public var state: PresentationState = .welcome
    @Published public var review: ReviewPresentation?
    @Published public var selection = ReviewSelection()
    @Published public var sidebarSearch = ""
    /// Files picked together in the sidebar with Shift or Command. Empty
    /// unless more than one is picked; any single selection clears it.
    @Published public var selectedFilePaths: Set<String> = []
    @Published public var banner: SessionBanner?
    @Published public var isBusy = false
    @Published public var persistenceFailure: PersistenceFailure?
    /// One-shot focus request consumed by the window (commands route here).
    @Published public var requestFocus: ReviewFocusTarget = .none
    // Phase 8 dependency health.
    @Published public var _dependencyStatus: GitHubDependencyStatus?
    @Published public var isCheckingDependency = false
    var didStartDependencyCheck = false
    var suppressDependencyCheck = false
    var dependencyGeneration = 0
    // Phase 6 workflow state.
    @Published public var draftEditor: DraftEditorState?
    @Published public var replyEditors: [String: ReplyEditorState] = [:]
    @Published public var submitState: SubmitPresentationState = .hidden
    @Published public var submitEvent: ReviewEvent = .comment
    @Published public var submitBody = ""
    @Published public var submitValidationMessage: String?

    /// The single hovered diff row, observed ONLY by diff-row views. Keeping
    /// hover outside the store's own @Published surface stops constant mouse
    /// movement from invalidating the sidebar, header, toolbar, and editors.
    public let hover = ReviewHoverModel()

    public let service: GitHubServing
    public let persistence: ReviewPersisting
    /// Rendered diff lines, cached so file switches in large PRs don't
    /// re-tokenize / re-attribute the viewport. Bounded LRU, per window.
    public let diffLineCache = DiffLineCache()
    /// Phase 1 baseline monitor for file-selection and editor presentation
    /// latency. It owns no review state and can remain enabled during profiling.
    public let performance = ReviewPerformanceMonitor()

    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?
    /// The most recent requested reference (or "demo"), retained for retry.
    public private(set) var lastRequestedReference: String?
    var demoSession = false
    var resolveGenerations: [String: Int] = [:]
    var refreshTask: Task<Void, Never>?
    var refreshGeneration = 0
    var submitTask: Task<Void, Never>?
    var undoStack: [DraftMutation] = []
    var redoStack: [DraftMutation] = []
    /// Test diagnostics: how many resolve completions (success or failure) the
    /// store has processed. Lets tests wait until every released resolve has
    /// been handled before asserting rollback behavior.
    var resolveHandlingCount = 0
    let preference: GitHubExecutablePreference
    let dependencyRunner: CommandRunning?

    /// Per-file caches for keyboard navigation, lazily built and cleared on
    /// every load. Recomputing these on every arrow key is the dominant cost
    /// of holding a key on very large files.
    var commentableCache: [String: [DiffRowID]] = [:]
    var hunkIDsCache: [String: [DiffRowID]] = [:]
    var linePositionCache: [String: [DiffRowID: (hunk: Int, lineIndex: Int)]] = [:]
    /// Debounced persistence tasks (see `ReviewSessionStoreWorkflows`): rapid
    /// mutations cancel the pending write and schedule a fresh one, so only
    /// the final snapshot reaches disk.
    var pendingDraftSave: Task<Void, Never>?
    var pendingViewedSave: Task<Void, Never>?
    var pendingHiddenReviewersSave: Task<Void, Never>?

    public init(
        service: GitHubServing,
        persistence: ReviewPersisting,
        preference: GitHubExecutablePreference = GitHubExecutablePreference(),
        dependencyRunner: CommandRunning? = nil
    ) {
        self.service = service
        self.persistence = persistence
        self.preference = preference
        self.dependencyRunner = dependencyRunner
    }

    /// When a window closes and releases its store, cancel every in-flight
    /// task so no ghost work continues after the session is gone. All task
    /// closures capture `self` weakly, so cancellation is the only cleanup
    /// needed here.
    deinit {
        loadTask?.cancel()
        refreshTask?.cancel()
        submitTask?.cancel()
        pendingDraftSave?.cancel()
        pendingViewedSave?.cancel()
        pendingHiddenReviewersSave?.cancel()
    }

    // MARK: - Loading

    public func openDemo(scale: DemoScale = .small, files: Int? = nil, lines: Int? = nil) {
        AppLog.info("store", "Open demo requested; scale=\(scale)")
        suppressDependencyCheck = true
        startLoad(reference: nil, demo: true, scale: scale, files: files, lines: lines)
    }

    /// Opens a qualified reference (full URL or `owner/repo#number`).
    public func open(reference: String) {
        AppLog.info("store", "Open PR requested for \(reference)")
        startLoad(reference: reference, demo: false, scale: .small)
    }

    public func cancelLoad() {
        AppLog.warning("store", "Cancelling load; currentReference=\(self.lastRequestedReference ?? "none")")
        // Invalidate the generation so even a cancellation-uncooperative load
        // cannot apply a stale result after the user cancelled.
        loadGeneration += 1
        loadTask?.cancel()
        if case .loading = state {
            state = .welcome
        }
        isBusy = false
        resetDerivedCaches()
    }

    private func startLoad(reference: String?, demo: Bool, scale: DemoScale, files: Int? = nil, lines: Int? = nil) {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()

        selectedFilePaths = []
        // A new review invalidates everything derived from the previous one:
        // rendered lines, navigation indexes, and per-file lookups. The old
        // cache contents would only pin memory for lines that can never be
        // requested again.
        resetDerivedCaches()

        lastRequestedReference = demo ? "demo" : reference
        let label = demo ? "demo-\(scale)" : (reference ?? "")
        AppLog.info("store", "Starting load generation=\(generation); reference=\(label); demo=\(demo)")
        state = .loading(reference: label)
        isBusy = true
        banner = nil

        let loader = ReviewSessionLoader(service: service, persistence: persistence)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let presentation: ReviewPresentation
                if demo {
                    presentation = try await loader.loadDemo(scale: scale, files: files, lines: lines)
                } else {
                    presentation = try await loader.load(reference: reference ?? "")
                }
                try Task.checkCancellation()
                guard generation == self.loadGeneration else { return }
                self.review = presentation
                self.demoSession = demo
                self.submitState = .hidden
                self.draftEditor = nil
                self.replyEditors = [:]
                self.clearDraftHistory()
                // Retain the previously selected path when it still exists.
                let kept = self.selection.filePath
                let stillPresent = kept.map { keptPath in
                    presentation.files.contains { $0.path == keptPath }
                } ?? false
                let path = stillPresent ? kept : presentation.files.first?.path
                self.selection = ReviewSelection(filePath: path)
                self.state = presentation.files.isEmpty ? .empty : .loaded
                self.isBusy = false
                AppLog.info("store", "Load generation=\(generation) succeeded; files=\(presentation.files.count); state=\(presentation.files.isEmpty ? "empty" : "loaded")")
            } catch is CancellationError {
                AppLog.warning("store", "Load generation=\(generation) cancelled")
                // Superseded or explicitly cancelled: leave state as set.
            } catch {
                guard generation == self.loadGeneration else { return }
                AppLog.failure("store", context: "Load generation=\(generation) failed", error: error)
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                self.banner = SessionBanner(text: message, isError: true)
                self.state = .failed(message: message)
                self.isBusy = false
            }
        }
    }

    // MARK: - Sidebar selection

    /// Applies a sidebar selection, retaining it if the file still exists.
    public func select(filePath: String?) {
        let previousPath = selection.filePath
        selectedFilePaths = []
        if let path = filePath, let review,
           review.fileIndexByPath[path] != nil {
            selection.filePath = path
        } else {
            selection.filePath = review?.files.first?.path
        }
        selection.rowID = nil
        if previousPath != selection.filePath {
            let lineCount = selection.filePath.flatMap { path in review?.files.first(where: { $0.path == path })?.lineCount } ?? 0
            if let path = selection.filePath {
                performance.beginFileSelection(path: path, lineCount: lineCount)
            }
            AppLog.info("selection", "Selected file path=\(self.selection.filePath ?? "none"); previous=\(previousPath ?? "none"); diffLines=\(lineCount)")
        }
    }

    public var selectedFile: DiffFile? {
        guard let path = selection.filePath, let review,
              let index = review.fileIndexByPath[path] else { return nil }
        return review.files[index]
    }

    public var filteredSidebarItems: [FileSidebarItem] {
        guard let review else { return [] }
        let query = sidebarSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return review.sidebarItems }
        return review.sidebarItems.filter { item in
            // Precomputed lowercase search text (path + status letter) avoids
            // re-lowercasing every path on every keystroke.
            item.searchable.contains(query)
        }
    }

    /// Resets per-review derived caches (rendered lines + navigation indexes).
    private func resetDerivedCaches() {
        diffLineCache.removeAll()
        commentableCache.removeAll()
        hunkIDsCache.removeAll()
        linePositionCache.removeAll()
    }
}
