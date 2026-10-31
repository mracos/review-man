import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

final class ReviewCommandTests: XCTestCase {

    private let sampleDiff = """
    diff --git a/Src.swift b/Src.swift
    --- a/Src.swift
    +++ b/Src.swift
    @@ -1,3 +1,4 @@
     keep1
    -old2
    +new2
    +new3
    """

    // MARK: - Pure availability

    func testAvailabilityForLoadedWithCommentableSelection() {
        let context = ReviewCommandContext(
            state: .loaded, isDemo: false, hasSelectedFile: true,
            hasCommentableSelection: true, selectedThreadIsActive: false,
            selectedThreadHasRootComment: false, canUndo: true, canRedo: false,
            draftEditorOpen: false, submitHidden: true, isSubmitting: false,
            canSubmit: true, hasPRURL: true
        )
        let a = ReviewCommandAvailability(context: context)
        XCTAssertTrue(a.canAddComment)
        XCTAssertTrue(a.canCopyLine)
        XCTAssertTrue(a.canSubmit)
        XCTAssertTrue(a.canRefresh)
        XCTAssertTrue(a.canOpenInBrowser)
        XCTAssertFalse(a.canReply, "no thread selected")
        XCTAssertFalse(a.canResolve, "no thread selected")
    }

    func testAvailabilityForHiddenReviewerActions() {
        let context = ReviewCommandContext(
            state: .loaded, isDemo: false, hasSelectedFile: false,
            hasCommentableSelection: false, selectedThreadIsActive: false,
            selectedThreadHasRootComment: false, canUndo: false, canRedo: false,
            draftEditorOpen: false, submitHidden: true, isSubmitting: false,
            canSubmit: true, hasPRURL: true,
            hasReviewers: true, hasHiddenReviewers: true
        )
        let a = ReviewCommandAvailability(context: context)
        XCTAssertTrue(a.canHideReviewer)
        XCTAssertTrue(a.canShowHiddenComments)

        // Defaults: no commenters and nothing hidden gate both actions off.
        let none = ReviewCommandAvailability(context: ReviewCommandContext(
            state: .loaded, isDemo: false, hasSelectedFile: false,
            hasCommentableSelection: false, selectedThreadIsActive: false,
            selectedThreadHasRootComment: false, canUndo: false, canRedo: false,
            draftEditorOpen: false, submitHidden: true, isSubmitting: false,
            canSubmit: true, hasPRURL: true
        ))
        XCTAssertFalse(none.canHideReviewer)
        XCTAssertFalse(none.canShowHiddenComments)
    }

    func testAvailabilityGatesByStateAndEditors() {
        // Welcome state disables review actions.
        let welcome = ReviewCommandAvailability(context: ReviewCommandContext(
            state: .welcome, isDemo: false, hasSelectedFile: false,
            hasCommentableSelection: false, selectedThreadIsActive: false,
            selectedThreadHasRootComment: false, canUndo: false, canRedo: false,
            draftEditorOpen: false, submitHidden: true, isSubmitting: false,
            canSubmit: false, hasPRURL: false
        ))
        XCTAssertFalse(welcome.canAddComment)
        XCTAssertFalse(welcome.canSubmit)

        // An open draft editor blocks Add Comment.
        let editing = ReviewCommandAvailability(context: ReviewCommandContext(
            state: .loaded, isDemo: false, hasSelectedFile: true,
            hasCommentableSelection: true, selectedThreadIsActive: false,
            selectedThreadHasRootComment: false, canUndo: false, canRedo: false,
            draftEditorOpen: true, submitHidden: true, isSubmitting: false,
            canSubmit: true, hasPRURL: true
        ))
        XCTAssertFalse(editing.canAddComment, "draft editor open blocks adding another comment")
    }

    // MARK: - Store navigation

    @MainActor
    func testMoveLineSelectionCyclesCommentableLines() {
        let store = makeLoadedStore()
        let file = store.selectedFile!
        let ids = store.commentableLineIDs(in: file)
        XCTAssertFalse(ids.isEmpty, "sample diff has commentable lines")

        store.moveLineSelection(1, in: file)
        XCTAssertEqual(store.selection.rowID, ids.first)

        store.moveLineSelection(1, in: file)
        XCTAssertEqual(store.selection.rowID, ids[1])

        // Moving up from the first wraps/clamps to the first.
        store.selection.rowID = ids[0]
        store.moveLineSelection(-1, in: file)
        XCTAssertEqual(store.selection.rowID, ids[0])
    }

    @MainActor
    func testFileAndHunkNavigation() {
        let twoFileDiff = sampleDiff + """

        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -1,1 +1,2 @@
         # Title
        +New line
        """
        let store = makeLoadedStore(diff: twoFileDiff)
        XCTAssertEqual(store.review?.files.count, 2)

        store.selectNextFile()
        XCTAssertEqual(store.selection.filePath, store.review?.files[1].path)
        store.selectPreviousFile()
        XCTAssertEqual(store.selection.filePath, store.review?.files[0].path)

        if let file = store.selectedFile {
            store.selectAdjacentHunk(1, in: file)
            XCTAssertNotNil(store.selection.rowID)
        }
    }

    @MainActor
    func testUnviewedNavigationSkipsViewedFilesAndWraps() {
        let store = makeLoadedStore(diff: threeFileDiff)
        let paths = store.review?.files.map(\.path) ?? []
        XCTAssertEqual(paths.count, 3)
        store.toggleViewed(filePath: paths[1])

        store.select(filePath: paths[0])
        store.selectNextUnviewedFile()
        XCTAssertEqual(store.selection.filePath, paths[2])

        store.selectNextUnviewedFile()
        XCTAssertEqual(store.selection.filePath, paths[0])

        store.selectPreviousUnviewedFile()
        XCTAssertEqual(store.selection.filePath, paths[2])
    }

    @MainActor
    func testMarkViewedAndAdvanceStopsWhenEverythingIsViewed() {
        let store = makeLoadedStore(diff: threeFileDiff)
        let paths = store.review?.files.map(\.path) ?? []
        store.toggleViewed(filePath: paths[1])
        store.select(filePath: paths[0])

        store.markViewedAndAdvance()
        XCTAssertEqual(store.review?.viewed, [paths[0], paths[1]])
        XCTAssertEqual(store.selection.filePath, paths[2])

        store.markViewedAndAdvance()
        XCTAssertEqual(store.review?.viewed, Set(paths))
        XCTAssertEqual(store.selection.filePath, paths[2])

        store.markViewedAndAdvance()
        XCTAssertEqual(store.review?.viewed, Set(paths), "an already viewed file stays viewed")
    }

    private var threeFileDiff: String {
        sampleDiff + """

        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -1,1 +1,2 @@
         # Title
        +New line
        diff --git a/NOTES.md b/NOTES.md
        --- a/NOTES.md
        +++ b/NOTES.md
        @@ -1,1 +1,2 @@
         # Notes
        +Another line
        """
    }

    // MARK: - Escape precedence

    @MainActor
    func testEscapePrecedenceDismissesEditorThenBanner() {
        let store = makeLoadedStore()

        // Draft editor first.
        store.beginDraft(at: DraftStartAnchor(path: "Src.swift", side: "RIGHT", line: 2))
        XCTAssertNotNil(store.draftEditor)
        XCTAssertTrue(store.cancelTransientInteraction())
        XCTAssertNil(store.draftEditor, "Escape cancels the draft editor first")

        // Then the banner.
        store.banner = SessionBanner(text: "hi", isError: false)
        XCTAssertTrue(store.cancelTransientInteraction())
        XCTAssertNil(store.banner, "Escape dismisses the banner")

        XCTAssertFalse(
            store.cancelTransientInteraction(),
            "Escape reports nothing to cancel so views can switch modes"
        )
    }

    // MARK: - Undo history cleared on load

    @MainActor
    func testDraftHistoryClearedOnReload() {
        let store = makeLoadedStore()
        store.beginDraft(at: DraftStartAnchor(path: "Src.swift", side: "RIGHT", line: 2))
        store.draftEditor?.text = "one"
        store.saveDraftEditor()
        XCTAssertTrue(store.canUndo)

        // A replacement load clears history.
        store.openDemo()
        waitFor { store.state == .loaded }
        XCTAssertFalse(store.canUndo, "history must not cross reviews")
        XCTAssertFalse(store.canRedo)
    }

    // MARK: - Helpers

    @MainActor
    private func makeLoadedStore(diff: String? = nil) -> ReviewSessionStore {
        let service = FakeService()
        service.bundle = FetchBundle(
            pr: makePRInfo(), files: DiffParser.parse(diff ?? sampleDiff), threads: []
        )
        let store = ReviewSessionStore(service: service, persistence: InMemoryPersistence())
        store.open(reference: "o/r#1")
        waitFor { store.state == .loaded }
        return store
    }

    private func waitFor(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }
}

// MARK: - Doubles (file-local)

private final class FakeService: GitHubServing {
    var bundle: FetchBundle?
    func ensureAvailable() async throws {}
    func resolveEndpoint(from argument: String) async throws -> PREndpoint {
        PREndpoint(owner: "o", repo: "r", number: 1)
    }
    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
        bundle ?? FetchBundle(pr: makePRInfo(), files: [], threads: [])
    }
    func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {}
    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {}
    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {}
}

private final class InMemoryPersistence: ReviewPersisting {
    func loadDraftState(for endpoint: PREndpoint, headSHA: String) async throws -> PersistedDraftState { .missing }
    func saveDrafts(_ drafts: [DraftComment], for endpoint: PREndpoint, headSHA: String) async throws {}
    func loadViewed(for endpoint: PREndpoint, headSHA: String) async throws -> Set<String> { [] }
    func saveViewed(_ viewed: Set<String>, for endpoint: PREndpoint, headSHA: String) async throws {}
    func loadHiddenReviewers(for endpoint: PREndpoint) async throws -> Set<String> { [] }
    func saveHiddenReviewers(_ hidden: Set<String>, for endpoint: PREndpoint) async throws {}
}

private func makePRInfo() -> PRInfo {
    PRInfo(number: 1, title: "PR", body: nil, author: "a", state: "OPEN", isDraft: false,
           headRefOid: "sha1", headRefName: "head", baseRefName: "base",
           additions: 10, deletions: 4, changedFiles: 1, reviewDecision: nil,
           url: "https://github.com/o/r/pull/1")
}

// MARK: - URL routing

final class ReviewURLCoordinatorTests: XCTestCase {

    func testParsesLauncherURLsStrictly() {
        XCTAssertEqual(
            ReviewURLCoordinator.reference(for: URL(string: "pr-review://open/octocat/hello-world/42")!),
            "octocat/hello-world#42"
        )
        // GitHub URLs map to the same key as launcher URLs, so one PR is one window.
        XCTAssertEqual(
            ReviewURLCoordinator.reference(for: URL(string: "https://github.com/o/r/pull/7")!),
            "o/r#7"
        )
        XCTAssertEqual(
            ReviewURLCoordinator.reference(for: URL(string: "https://github.com/o/r/pull/7/files#discussion_r1")!),
            "o/r#7"
        )
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "https://github.com/o/r")!))
        // Names gh or a REST path would interpret are rejected.
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "pr-review://open/%40foo/r/1")!))
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "pr-review://open/o/../1")!))
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "pr-review://open/o/r%3Fx/1")!))
        // Strict validation: negative/zero numbers, missing parts, other schemes.
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "pr-review://open/o/r/0")!))
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "pr-review://open/o/r/-1")!))
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "pr-review://open/o/r")!))
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "ftp://example.com")!))
        // Query/fragment/trailing slash on launcher URLs are rejected.
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "pr-review://open/o/r/1?x=1")!))
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "pr-review://open/o/r/1#frag")!))
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "pr-review://open/o/r/1/")!))
        // Empty path segments (extra slashes) are rejected.
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "pr-review://open//o/r/1")!))
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "pr-review://open/o//r/1")!))
        // Only GitHub hosts are routed as web URLs.
        XCTAssertNil(ReviewURLCoordinator.reference(for: URL(string: "https://example.com/o/r/pull/1")!))
        XCTAssertEqual(
            ReviewURLCoordinator.reference(for: URL(string: "https://www.github.com/o/r/pull/1")!),
            "o/r#1"
        )
    }
}

// MARK: - Body-only submit availability

@MainActor
final class ReviewSubmitAvailabilityTests: XCTestCase {
    func testBodyOnlySubmitIsAvailableWithoutDrafts() {
        let service = FakeService()
        service.bundle = FetchBundle(pr: makePRInfo(), files: [], threads: [])
        let store = ReviewSessionStore(service: service, persistence: InMemoryPersistence())
        store.open(reference: "o/r#1")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, store.state != .loaded {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertEqual(store.state, .empty, "a PR with no changed files shows the empty state")
        XCTAssertTrue(store.review?.drafts.isEmpty ?? false)
        let availability = ReviewCommandAvailability(context: store.commandContext())
        XCTAssertTrue(availability.canSubmit, "a summary-only review with no drafts is valid")
    }
}
