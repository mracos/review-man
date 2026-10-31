import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

// MARK: - Doubles

/// Mutable session view used by tests to seed threads/drafts.
private struct WorkflowSession {
    var endpoint: PREndpoint?
    var pr: PRInfo?
    var files: [DiffFile]
    var threads: [PRThread]
    var drafts: [DraftComment]
    var viewed: Set<String>
}

private final class WorkflowService: GitHubServing {
    var bundle: FetchBundle?
    var fetchError: Error?
    var resolveError: Error?
    var replyError: Error?
    var viewedOnGitHub: Set<String> = []
    private(set) var submitCalls: [(commitID: String, event: String, draftCount: Int)] = []
    private(set) var setViewedCalls: [String] = []

    func ensureAvailable() async throws {}
    func resolveEndpoint(from argument: String) async throws -> PREndpoint {
        PREndpoint(owner: "o", repo: "r", number: 1)
    }
    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
        if let fetchError { throw fetchError }
        return bundle ?? FetchBundle(pr: makePRInfo(), files: [], threads: [])
    }
    func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {
        submitCalls.append((commitID, event, drafts.count))
    }
    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {
        if let replyError { throw replyError }
    }
    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {
        if let resolveError { throw resolveError }
    }
    func fetchViewedFiles(_ ep: PREndpoint) async throws -> Set<String> {
        viewedOnGitHub
    }
    func setFileViewed(pullRequestID: String, path: String, viewed: Bool) async throws {
        setViewedCalls.append("\(pullRequestID) \(path) \(viewed)")
    }
}

private final class WorkflowPersistence: ReviewPersisting {
    private var drafts: [String: [DraftComment]] = [:]
    private var present = Set<String>()
    private var viewed: [String: Set<String>] = [:]
    private var hiddenByPR: [String: Set<String>] = [:]
    private(set) var draftSaveCount = 0

    private func key(_ ep: PREndpoint, _ sha: String) -> String {
        "\(ep.owner)/\(ep.repo)#\(ep.number)@\(sha)"
    }
    func loadDraftState(for endpoint: PREndpoint, headSHA: String) async throws -> PersistedDraftState {
        let k = key(endpoint, headSHA)
        return present.contains(k) ? .present(drafts[k] ?? []) : .missing
    }
    func saveDrafts(_ drafts: [DraftComment], for endpoint: PREndpoint, headSHA: String) async throws {
        draftSaveCount += 1
        self.drafts[key(endpoint, headSHA)] = drafts
        present.insert(key(endpoint, headSHA))
    }
    func loadViewed(for endpoint: PREndpoint, headSHA: String) async throws -> Set<String> {
        viewed[key(endpoint, headSHA)] ?? []
    }
    func saveViewed(_ viewed: Set<String>, for endpoint: PREndpoint, headSHA: String) async throws {
        viewedSaveCount += 1
        self.viewed[key(endpoint, headSHA)] = viewed
    }
    func savedViewed(for ep: PREndpoint, sha: String) -> Set<String>? {
        viewed[key(ep, sha)]
    }
    private(set) var viewedSaveCount = 0

    func loadHiddenReviewers(for endpoint: PREndpoint) async throws -> Set<String> {
        hiddenByPR[prKey(endpoint)] ?? []
    }
    func saveHiddenReviewers(_ hidden: Set<String>, for endpoint: PREndpoint) async throws {
        hiddenSaveCount += 1
        hiddenByPR[prKey(endpoint)] = hidden
    }
    func savedHiddenReviewers(for ep: PREndpoint) -> Set<String>? {
        hiddenByPR[prKey(ep)]
    }
    private(set) var hiddenSaveCount = 0

    private func prKey(_ ep: PREndpoint) -> String {
        "\(ep.owner)/\(ep.repo)#\(ep.number)"
    }
}

private func makePRInfo(sha: String = "sha1") -> PRInfo {
    PRInfo(number: 1, title: "PR", body: nil, author: "a", state: "OPEN", isDraft: false,
           headRefOid: sha, headRefName: "head", baseRefName: "base",
           additions: 10, deletions: 4, changedFiles: 1, reviewDecision: nil,
           url: "https://github.com/o/r/pull/1", nodeID: "PR_1")
}

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

@MainActor
final class ReviewWorkflowTests: XCTestCase {

    private let ep = PREndpoint(owner: "o", repo: "r", number: 1)

    private func makeRealStore(
        viewedOnGitHub: Set<String> = [],
        syncViewed: Bool = false
    ) -> (service: WorkflowService, persistence: WorkflowPersistence, store: ReviewSessionStore) {
        let service = WorkflowService()
        service.bundle = FetchBundle(pr: makePRInfo(), files: DiffParser.parse(sampleDiff), threads: [])
        service.viewedOnGitHub = viewedOnGitHub
        let persistence = WorkflowPersistence()
        let defaults = UserDefaults(suiteName: "viewed-sync-\(UUID().uuidString)")!
        let viewedSync = ViewedSyncPreference(defaults: defaults)
        viewedSync.isEnabled = syncViewed
        let store = ReviewSessionStore(service: service, persistence: persistence, viewedSync: viewedSync)
        store.open(reference: "o/r#1")
        waitSync { store.state == .loaded }
        return (service, persistence, store)
    }

    private func waitSync(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private func thread(_ id: String, commentID: Int) -> PRThread {
        PRThread(
            id: id, path: "Src.swift", line: 2, originalLine: 2, side: "RIGHT",
            startLine: nil, startSide: nil, isOutdated: false, isResolved: false,
            comments: [PRComment(databaseId: commentID, author: "a", body: "hi", createdAt: Date())]
        )
    }

    /// A thread with one comment per listed author (exercises the "hide by
    /// any comment author" rule, replies included).
    private func threadWithAuthors(_ id: String, _ authors: [String]) -> PRThread {
        PRThread(
            id: id, path: "Src.swift", line: 2, originalLine: 2, side: "RIGHT",
            startLine: nil, startSide: nil, isOutdated: false, isResolved: false,
            comments: authors.enumerated().map { i, author in
                PRComment(databaseId: 100 + i, author: author, body: "hi from \(author)", createdAt: Date())
            }
        )
    }

    private func mutate(_ store: ReviewSessionStore, _ body: (inout WorkflowSession) -> Void) {
        var session = WorkflowSession(
            endpoint: store.review?.endpoint, pr: store.review?.pr,
            files: store.review?.files ?? [], threads: store.review?.threads ?? [],
            drafts: store.review?.drafts ?? [], viewed: store.review?.viewed ?? []
        )
        body(&session)
        store.review = ReviewPresentation(
            endpoint: session.endpoint, pr: session.pr, files: session.files,
            threads: session.threads, drafts: session.drafts, viewed: session.viewed
        )
    }

    // MARK: - Drafts

    func testAddEditDeleteDraftUpdatesPresentationAndPersists() {
        let (_, persistence, store) = makeRealStore()

        store.beginDraft(at: DraftStartAnchor(path: "Src.swift", side: "RIGHT", line: 2))
        store.draftEditor?.text = "looks good"
        store.saveDraftEditor()
        XCTAssertNil(store.draftEditor)
        XCTAssertEqual(store.review?.drafts.count, 1)
        XCTAssertEqual(store.review?.drafts.first?.body, "looks good")
        waitSync { persistence.draftSaveCount > 0 }

        store.beginDraft(at: DraftStartAnchor(path: "Src.swift", side: "RIGHT", line: 3))
        store.draftEditor?.text = "   "
        store.saveDraftEditor()
        XCTAssertEqual(store.review?.drafts.count, 1, "empty new draft is discarded")

        let draft = store.review!.drafts[0]
        store.editDraft(draft)
        store.draftEditor?.text = "updated"
        store.saveDraftEditor()
        XCTAssertEqual(store.review?.drafts.first?.body, "updated")

        store.editDraft(store.review!.drafts[0])
        store.draftEditor?.text = ""
        store.saveDraftEditor()
        XCTAssertTrue(store.review?.drafts.isEmpty ?? false, "empty edit deletes the draft")
    }

    // MARK: - Undo / redo

    func testUndoRedoDraftLifecycle() {
        let (_, _, store) = makeRealStore()

        store.beginDraft(at: DraftStartAnchor(path: "Src.swift", side: "RIGHT", line: 2))
        store.draftEditor?.text = "one"
        store.saveDraftEditor()
        XCTAssertTrue(store.canUndo)

        store.undoDraft()
        XCTAssertTrue(store.review?.drafts.isEmpty ?? false)
        XCTAssertTrue(store.canRedo)

        store.redoDraft()
        XCTAssertEqual(store.review?.drafts.first?.body, "one")

        store.beginDraft(at: DraftStartAnchor(path: "Src.swift", side: "RIGHT", line: 3))
        store.draftEditor?.text = "two"
        store.saveDraftEditor()
        XCTAssertFalse(store.canRedo, "a new mutation clears redo")
    }

    func testUndoRedoCoversEditAndDelete() {
        let (_, _, store) = makeRealStore()

        store.beginDraft(at: DraftStartAnchor(path: "Src.swift", side: "RIGHT", line: 2))
        store.draftEditor?.text = "v1"
        store.saveDraftEditor()
        let draft = store.review!.drafts[0]

        // Edit, then undo the edit.
        store.editDraft(draft)
        store.draftEditor?.text = "v2"
        store.saveDraftEditor()
        XCTAssertEqual(store.review?.drafts.first?.body, "v2")
        store.undoDraft()
        XCTAssertEqual(store.review?.drafts.first?.body, "v1", "undo restores the edited body")

        // Delete, then undo the delete.
        store.deleteDraft(store.review!.drafts[0])
        XCTAssertTrue(store.review?.drafts.isEmpty ?? false)
        store.undoDraft()
        XCTAssertEqual(store.review?.drafts.count, 1, "undo restores the deleted draft")
    }

    // MARK: - Refresh selection preservation

    func testRefreshPreservesSelectedPath() {
        let service = WorkflowService()
        let twoFileDiff = sampleDiff + """

        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -1,1 +1,2 @@
         # Title
        +New line
        """
        service.bundle = FetchBundle(
            pr: makePRInfo(), files: DiffParser.parse(twoFileDiff), threads: []
        )
        let store = ReviewSessionStore(service: service, persistence: WorkflowPersistence())
        store.open(reference: "o/r#1")
        waitSync { store.state == .loaded }

        let target = store.review!.files[1].path
        store.select(filePath: target)
        store.refresh()
        waitSync { !store.isBusy }
        XCTAssertEqual(store.selection.filePath, target, "selected path preserved across refresh")
    }

    // MARK: - Submit cancellation

    func testSubmitCancellationLeavesUncertainState() async {
        let service = GatedSubmitService()
        service.bundle = FetchBundle(pr: makePRInfo(), files: DiffParser.parse(sampleDiff), threads: [])
        let persistence = WorkflowPersistence()
        let store = ReviewSessionStore(service: service, persistence: persistence)
        store.open(reference: "o/r#1")
        await waitAsync { store.state == .loaded && store.review != nil }

        // A draft exists before submission; cancellation must retain it.
        store.beginDraft(at: DraftStartAnchor(path: "Src.swift", side: "RIGHT", line: 2))
        store.draftEditor?.text = "precious draft"
        store.saveDraftEditor()
        XCTAssertEqual(store.review?.drafts.count, 1)

        store.beginSubmit()
        store.submitBody = "ship it"
        store.submitReview()
        // Wait until the gated service has actually INSTALLED the gate, so
        // cancellation provably resumes a registered continuation.
        await waitAsync { store.submitState == .submitting && service.gateInstalled }
        store.cancelSubmit()

        // Cancellation must reach the in-flight submit (gate released with
        // CancellationError). Once it has, the success path — the only path
        // that removes drafts — is impossible, so retention is deterministic.
        await waitAsync { service.gateReleased }
        XCTAssertTrue(service.gateReleased, "cancellation must reach the in-flight submit")
        try? await Task.sleep(nanoseconds: 30_000_000)
        guard case .uncertain = store.submitState else {
            return XCTFail("expected uncertain state, got \(store.submitState)")
        }
        XCTAssertEqual(store.review?.drafts.count, 1, "cancelled submission retains drafts")
    }

    // MARK: - Resolve

    func testOptimisticResolveAndRollbackOnFailure() {
        let (service, _, store) = makeRealStore()
        mutate(store) { $0.threads = [thread("t1", commentID: 1)] }

        store.toggleResolved(threadID: "t1")
        XCTAssertEqual(store.review?.threads.first?.isResolved, true, "optimistic update")

        service.resolveError = GitHubError.api("boom")
        waitSync { store.review?.threads.first?.isResolved == false }
        XCTAssertTrue(store.banner?.isError ?? false, "failure rolls back and shows a banner")
    }

    /// A stale resolve failure (from a superseded toggle) must not roll back a
    /// newer state. Resolve #1 is released with an error AFTER resolve #2
    /// superseded it; the generation guard must ignore the stale failure.
    /// A stale resolve failure (from a superseded toggle) must not roll back a
    /// newer state. THREE toggles make rollback observable: the current state
    /// (true after toggle 3) differs from resolve #1's rollback value (false),
    /// so an unconditional stale rollback would flip the state.
    func testStaleResolveFailureDoesNotRollBackNewerState() async {
        let service = GatedResolveService()
        service.bundle = FetchBundle(pr: makePRInfo(), files: DiffParser.parse(sampleDiff), threads: [])
        let store = ReviewSessionStore(service: service, persistence: WorkflowPersistence())
        store.open(reference: "o/r#1")
        await waitAsync { store.state == .loaded && store.review != nil }
        mutate(store) { $0.threads = [thread("t1", commentID: 1)] }

        store.toggleResolved(threadID: "t1")   // gen 1: false → true,  rollback value false
        await waitAsync { service.pendingCount >= 1 }
        store.toggleResolved(threadID: "t1")   // gen 2: true → false,  rollback value true
        await waitAsync { service.pendingCount >= 2 }
        store.toggleResolved(threadID: "t1")   // gen 3: false → true (current)
        await waitAsync { service.pendingCount >= 3 }

        // Release the STALE gen-1 resolve with an error, then consume ALL
        // remaining gates. Wait until the store has PROCESSED every released
        // resolve (resolveHandlingCount == 3) before asserting: a broken
        // generation guard would roll the state back to false.
        service.releaseFirst(withError: GitHubError.api("boom"))
        service.releaseAll()
        await waitAsync { store.resolveHandlingCount >= 3 }
        XCTAssertEqual(store.resolveHandlingCount, 3, "all released resolves were handled")
        XCTAssertEqual(store.review?.threads.first?.isResolved, true,
                       "stale rollback (→ false) must not overwrite the current state (true)")
        XCTAssertFalse(store.banner?.isError ?? false, "stale failure must not surface a banner")
    }

    /// Async wait loop that suspends, letting the main-actor executor run
    /// (RunLoop.main.run does not, inside @MainActor async tests). Fails the
    /// test if the condition is not met within the timeout.
    private func waitAsync(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    // MARK: - Reply

    func testReplyFailureRetainsBodyForRetry() {
        let (service, _, store) = makeRealStore()
        mutate(store) { $0.threads = [thread("t1", commentID: 42)] }

        service.replyError = GitHubError.api("boom")
        store.beginReply(threadID: "t1")
        store.updateReply(threadID: "t1", body: "my reply")
        store.sendReply(threadID: "t1")
        waitSync { store.replyEditors["t1"]?.retryFailed == true }
        XCTAssertEqual(store.replyEditors["t1"]?.body, "my reply", "failed reply keeps the body")

        service.replyError = nil
        store.sendReply(threadID: "t1")
        waitSync { store.replyEditors["t1"] == nil }
        XCTAssertNil(store.replyEditors["t1"], "successful retry clears the editor")
    }

    // MARK: - Viewed

    func testViewedTogglePersists() {
        let (_, persistence, store) = makeRealStore()
        store.toggleViewed(filePath: "Src.swift")
        XCTAssertTrue(store.review?.viewed.contains("Src.swift") ?? false)
        waitSync { (persistence.savedViewed(for: ep, sha: "sha1") ?? []).contains("Src.swift") }
    }

    func testViewedSyncOffNeverTouchesGitHub() {
        let (service, _, store) = makeRealStore(viewedOnGitHub: ["Src.swift"])

        store.toggleViewed(filePath: "Src.swift")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(store.review?.viewed, ["Src.swift"], "GitHub marks are not merged when sync is off")
        XCTAssertTrue(service.setViewedCalls.isEmpty)
    }

    func testViewedSyncMergesGitHubMarksOnLoadAndPushesToggles() {
        let (service, _, store) = makeRealStore(viewedOnGitHub: ["Src.swift"], syncViewed: true)
        waitSync { store.review?.viewed.contains("Src.swift") ?? false }
        XCTAssertEqual(store.review?.viewed, ["Src.swift"])

        store.toggleViewed(filePath: "Src.swift")

        waitSync { !service.setViewedCalls.isEmpty }
        XCTAssertEqual(service.setViewedCalls, ["PR_1 Src.swift false"])
    }

    /// Rapid viewed toggles coalesce into one debounced disk write: the last
    /// snapshot wins and intermediate writes are skipped.
    func testViewedTogglesCoalesceIntoOnePersistedWrite() {
        let (_, persistence, store) = makeRealStore()
        for i in 0..<5 {
            store.toggleViewed(filePath: "Src.swift")
            store.toggleViewed(filePath: "Other.swift\(i)")
        }
        // Both writes are debounced; the final disk state reflects the LAST
        // in-memory snapshot exactly once.
        waitSync { (persistence.savedViewed(for: ep, sha: "sha1") ?? []).contains("Src.swift") }
        XCTAssertEqual(persistence.viewedSaveCount, 1, "all rapid toggles coalesce into a single write")
        XCTAssertTrue(store.review?.viewed.contains("Other.swift4") ?? false)
    }

    // MARK: - Hidden reviewers

    func testHideReviewerHidesThreadsByAnyAuthorAndPersists() {
        let (_, persistence, store) = makeRealStore()
        mutate(store) { session in
            session.threads = [
                threadWithAuthors("t1", ["jane", "bob"]),   // jane is a REPLY author
                threadWithAuthors("t2", ["bob"]),
                threadWithAuthors("t3", ["carol"]),
            ]
        }
        XCTAssertEqual(store.review?.sidebarItems.first?.threadCount, 3)

        store.hideReviewer("jane")

        XCTAssertEqual(store.hiddenReviewers, ["jane"])
        XCTAssertFalse(store.review?.rows(for: "Src.swift").contains(.thread(threadID: "t1")) ?? true)
        XCTAssertTrue(store.review?.rows(for: "Src.swift").contains(.thread(threadID: "t2")) ?? false)
        XCTAssertTrue(store.review?.rows(for: "Src.swift").contains(.thread(threadID: "t3")) ?? false)
        XCTAssertEqual(store.review?.sidebarItems.first?.threadCount, 2)
        waitSync { (persistence.savedHiddenReviewers(for: ep) ?? []).contains("jane") }
    }

    func testUnhideAllReviewersRestoresThreads() {
        let (_, _, store) = makeRealStore()
        mutate(store) { session in
            session.threads = [threadWithAuthors("t1", ["jane"]), threadWithAuthors("t2", ["bob"])]
        }
        store.hideReviewer("jane")
        store.hideReviewer("bob")
        let hiddenRows = store.review?.rows(for: "Src.swift") ?? []
        XCTAssertFalse(hiddenRows.contains(.thread(threadID: "t1")))
        XCTAssertFalse(hiddenRows.contains(.thread(threadID: "t2")), "all thread cards hidden")

        store.unhideAllReviewers()

        XCTAssertTrue(store.hiddenReviewers.isEmpty)
        XCTAssertTrue(store.review?.rows(for: "Src.swift").contains(.thread(threadID: "t1")) ?? false)
        XCTAssertTrue(store.review?.rows(for: "Src.swift").contains(.thread(threadID: "t2")) ?? false)
    }

    func testHideReviewerClearsSelectionAndReplyEditors() {
        let (_, _, store) = makeRealStore()
        mutate(store) { session in
            session.threads = [threadWithAuthors("t1", ["jane"])]
        }
        store.selection.rowID = .thread(id: "t1")
        store.beginReply(threadID: "t1")
        XCTAssertFalse(store.replyEditors.isEmpty)

        store.hideReviewer("jane")

        XCTAssertNil(store.selection.rowID, "selection pointing at a hidden thread is cleared")
        XCTAssertTrue(store.replyEditors.isEmpty, "reply editor on a hidden thread is dismissed")
    }

    /// Refreshing (same head) keeps the in-memory hidden set: migration
    /// carries the PR-scoped state through unchanged.
    func testHiddenReviewersSurviveRefresh() {
        let (service, _, store) = makeRealStore()
        mutate(store) { session in
            session.threads = [threadWithAuthors("t1", ["jane"])]
        }
        store.hideReviewer("jane")

        service.bundle = FetchBundle(
            pr: makePRInfo(),
            files: DiffParser.parse(sampleDiff),
            threads: [threadWithAuthors("t1", ["jane"])]
        )
        store.refresh()
        waitSync { store.banner != nil }

        XCTAssertEqual(store.hiddenReviewers, ["jane"], "refresh keeps PR-scoped hidden reviewers")
        XCTAssertFalse(store.review?.rows(for: "Src.swift").contains(.thread(threadID: "t1")) ?? true)
    }

    // MARK: - Submit

    func testSubmitValidationAndOrphanExclusion() {
        let (service, _, store) = makeRealStore()
        mutate(store) {
            $0.drafts = [
                DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "ok"),
                DraftComment(path: "Src.swift", line: 999, side: "RIGHT", body: "lost", isOrphaned: true),
            ]
        }

        store.beginSubmit()
        store.submitEvent = .approve
        store.submitBody = ""
        store.submitReview()
        XCTAssertNotNil(store.submitValidationMessage, "approval with comments and no summary is rejected")

        store.submitBody = "LGTM"
        store.submitReview()
        waitSync { store.submitState == .hidden }
        XCTAssertEqual(service.submitCalls.last?.draftCount, 1, "orphan excluded from submission")
        XCTAssertEqual(store.review?.drafts.count, 1, "orphan retained after submit")
    }
}

// MARK: - Gated submit service

/// Blocks submitReview until released; simulates cancellation by throwing
/// CancellationError when the awaiting task is cancelled.
private final class GatedSubmitService: GitHubServing {
    var bundle: FetchBundle?
    private(set) var submitCalls = 0
    private var gate: CheckedContinuation<Void, Error>?
    private(set) var gateReleased = false
    /// True once the continuation has been installed (cancellation can then
    /// provably resume it).
    var gateInstalled: Bool { gate != nil }

    func ensureAvailable() async throws {}
    func resolveEndpoint(from argument: String) async throws -> PREndpoint {
        PREndpoint(owner: "o", repo: "r", number: 1)
    }
    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
        bundle ?? FetchBundle(pr: makePRInfo(), files: DiffParser.parse(sampleDiff), threads: [])
    }
    func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {
        submitCalls += 1
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                gate = cont
            }
        }, onCancel: {
            gate?.resume(throwing: CancellationError())
            gate = nil
            gateReleased = true
        })
    }
    func release() { gate?.resume(); gate = nil }
    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {}
    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {}
}

// MARK: - Gated resolve service

/// Blocks each resolveThread call; lets the test release them per-call, with
/// optional errors, so stale-completion protection is exercised deterministically.
private final class GatedResolveService: GitHubServing {
    var bundle: FetchBundle?
    private(set) var resolveCalls = 0
    private var gates: [CheckedContinuation<Void, Error>] = []
    var pendingCount: Int { gates.count }

    func ensureAvailable() async throws {}
    func resolveEndpoint(from argument: String) async throws -> PREndpoint {
        PREndpoint(owner: "o", repo: "r", number: 1)
    }
    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
        bundle ?? FetchBundle(pr: makePRInfo(), files: DiffParser.parse(sampleDiff), threads: [])
    }
    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {
        resolveCalls += 1
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            gates.append(cont)
        }
    }
    func releaseFirst(withError error: Error) {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume(throwing: error)
    }
    func releaseAll() {
        while !gates.isEmpty { gates.removeFirst().resume() }
    }
    func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {}
    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {}
}
