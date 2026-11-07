import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

// MARK: - Doubles

private final class FakeService: GitHubServing {
    var bundle: FetchBundle?
    var fetchError: Error?
    var ensureError: Error?
    private(set) var resolveCalls: [String] = []
    private(set) var fetchCount = 0

    func ensureAvailable() async throws {
        if let ensureError { throw ensureError }
    }

    func resolveEndpoint(from argument: String) async throws -> PREndpoint {
        resolveCalls.append(argument)
        return PREndpoint(owner: "o", repo: "r", number: 1)
    }

    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
        fetchCount += 1
        if let fetchError { throw fetchError }
        return bundle ?? FetchBundle(pr: makePR(), files: [], threads: [])
    }

    func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {}
    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {}
    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {}
}

/// Reports a paged fetch, then holds the load open until released.
private final class ProgressReportingService: GitHubServing {
    var bundle: FetchBundle
    var released = false

    init(bundle: FetchBundle) {
        self.bundle = bundle
    }

    func ensureAvailable() async throws {}
    func resolveEndpoint(from argument: String) async throws -> PREndpoint {
        PREndpoint(owner: "o", repo: "r", number: 1)
    }
    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle { bundle }
    func fetchAll(_ ep: PREndpoint, progress: @escaping FetchProgressHandler) async throws -> FetchBundle {
        progress(.size(files: bundle.pr.changedFiles, additions: 10, deletions: 4))
        progress(.diffRefused)
        progress(.filesFetched(bundle.files.count))
        while !released { try await Task.sleep(nanoseconds: 5_000_000) }
        return bundle
    }
    func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {}
    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {}
    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {}
}

private func makePR(title: String = "PR", changedFiles: Int = 1) -> PRInfo {
    PRInfo(
        number: 1, title: title, body: nil, author: "a", state: "OPEN",
        isDraft: false, headRefOid: "sha1", headRefName: "head", baseRefName: "base",
        additions: 10, deletions: 4, changedFiles: changedFiles, reviewDecision: nil,
        url: "https://github.com/o/r/pull/1"
    )
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
final class ReviewSessionStoreTests: XCTestCase {

    private func waitFor(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Demo load

    func testDemoLoadProducesLoadedPresentationWithSidebarAndSelection() async {
        let store = ReviewSessionStore(
            service: FakeService(),
            persistence: InMemoryPersistence()
        )
        store.openDemo()
        await waitFor { store.state == .loaded }

        XCTAssertEqual(store.state, .loaded)
        let review = try! XCTUnwrap(store.review)
        XCTAssertEqual(review.files.count, 4)
        XCTAssertEqual(review.sidebarItems.count, 4)
        XCTAssertEqual(store.selection.filePath, review.files.first?.path)
        // Demo has active + outdated threads; sidebar counts them.
        XCTAssertTrue(review.sidebarItems.contains { $0.threadCount > 0 })
        XCTAssertFalse(review.diffRows(for: review.files[0]).isEmpty)
    }

    // MARK: - Real load

    func testRealLoadRestoresPersistedStateAndRevalidatesDrafts() async {
        let service = FakeService()
        service.bundle = FetchBundle(
            pr: makePR(), files: DiffParser.parse(sampleDiff), threads: []
        )
        let persistence = InMemoryPersistence()
        let invalid = DraftComment(path: "Src.swift", line: 999, side: "RIGHT", body: "lost")
        try? await persistence.saveDrafts([invalid], for: PREndpoint(owner: "o", repo: "r", number: 1), headSHA: "sha1")
        try? await persistence.saveViewed(["Src.swift"], for: PREndpoint(owner: "o", repo: "r", number: 1), headSHA: "sha1")

        let store = ReviewSessionStore(service: service, persistence: persistence)
        store.open(reference: "https://github.com/o/r/pull/1")
        await waitFor { store.state == .loaded }

        let review = try! XCTUnwrap(store.review)
        XCTAssertEqual(review.drafts.first?.isOrphaned, true, "invalid anchor becomes orphaned")
        XCTAssertEqual(review.viewed, ["Src.swift"], "persisted viewed marks restored")
        XCTAssertEqual(service.resolveCalls, ["https://github.com/o/r/pull/1"])
    }

    func testBareNumberIsRejectedInFinderUI() async {
        let store = ReviewSessionStore(service: FakeService(), persistence: InMemoryPersistence())
        store.open(reference: "123")
        await waitFor { if case .loading = store.state { return false }; return true }

        guard case .failed(let message) = store.state else {
            return XCTFail("expected failed state, got \(store.state)")
        }
        XCTAssertTrue(message.contains("Bare numbers"))
    }

    func testFetchFailureShowsFailedState() async {
        let service = FakeService()
        service.fetchError = GitHubError.api("boom")
        let store = ReviewSessionStore(service: service, persistence: InMemoryPersistence())
        store.open(reference: "o/r#1")
        await waitFor { if case .loading = store.state { return false }; return true }

        guard case .failed = store.state else {
            return XCTFail("expected failed state")
        }
        XCTAssertTrue(store.banner?.isError ?? false)
    }

    // MARK: - Stale load rejection

    func testSupersededLoadCannotOverwriteNewerResult() async {
        let gated = GatedService()
        gated.bundle = FetchBundle(pr: makePR(), files: DiffParser.parse(sampleDiff), threads: [])
        let store = ReviewSessionStore(service: gated, persistence: InMemoryPersistence())

        // First load blocks at fetch; second load supersedes and completes.
        store.open(reference: "o/r#1")
        await waitFor { gated.fetchCalls >= 1 }
        gated.autoComplete = true
        store.open(reference: "o/r#2")
        await waitFor { store.state == .loaded }

        // Release the stale first fetch: it must NOT overwrite the newer load.
        gated.releaseFirstFetch()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.review?.pr?.title, "PR")
    }

    func testLoadPublishesProgressWhileFetching() async {
        let service = ProgressReportingService(bundle: FetchBundle(
            pr: makePR(changedFiles: 1), files: DiffParser.parse(sampleDiff), threads: []
        ))
        let store = ReviewSessionStore(service: service, persistence: InMemoryPersistence())

        store.open(reference: "o/r#1")
        await waitFor { store.loadProgress.fetchedFiles == 1 }

        XCTAssertEqual(store.loadProgress.stage, .fetching)
        XCTAssertEqual(store.loadProgress.headline, "Fetching files: 1 of 1")
        service.released = true
        await waitFor { store.state == .loaded }
        XCTAssertEqual(store.state, .loaded)
    }

    func testLoadSaysWhenGitHubLeftFilesOut() async {
        var tooLarge = DiffFile()
        tooLarge.newPath = "huge.json"
        tooLarge.tooLarge = true
        let service = FakeService()
        service.bundle = FetchBundle(
            pr: makePR(changedFiles: 3_200),
            files: DiffParser.parse(sampleDiff) + [tooLarge],
            threads: []
        )
        let store = ReviewSessionStore(service: service, persistence: InMemoryPersistence())

        store.open(reference: "o/r#1")
        await waitFor { store.state == .loaded }

        let banner = try? XCTUnwrap(store.banner)
        XCTAssertEqual(banner?.isError, false)
        XCTAssertTrue(banner?.text.contains("only 2 of \(3_200.formatted()) files") ?? false, banner?.text ?? "no banner")
        XCTAssertTrue(banner?.text.contains("1 file is too large") ?? false, banner?.text ?? "no banner")
    }

    func testCompleteLoadShowsNoBanner() async {
        let service = FakeService()
        service.bundle = FetchBundle(pr: makePR(), files: DiffParser.parse(sampleDiff), threads: [])
        let store = ReviewSessionStore(service: service, persistence: InMemoryPersistence())

        store.open(reference: "o/r#1")
        await waitFor { store.state == .loaded }

        XCTAssertNil(store.banner)
    }

    func testCancelLoadDiscardsInFlightResult() async {
        let gated = GatedService()
        let store = ReviewSessionStore(service: gated, persistence: InMemoryPersistence())

        store.open(reference: "o/r#1")
        await waitFor { gated.fetchCalls >= 1 }
        store.cancelLoad()
        XCTAssertEqual(store.state, .welcome)

        // The in-flight (cancelled) load must not apply when it finally returns.
        gated.releaseFirstFetch()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.state, .welcome, "cancelled load must not apply")
        XCTAssertNil(store.review)
    }

    func testRetryReferenceIsRetainedAfterFailure() async {
        let service = FakeService()
        service.fetchError = GitHubError.api("boom")
        let store = ReviewSessionStore(service: service, persistence: InMemoryPersistence())

        store.open(reference: "o/r#1")
        await waitFor { if case .loading = store.state { return false }; return true }
        XCTAssertEqual(store.lastRequestedReference, "o/r#1")

        // A successful retry uses the retained reference.
        service.fetchError = nil
        service.bundle = FetchBundle(pr: makePR(), files: DiffParser.parse(sampleDiff), threads: [])
        store.open(reference: store.lastRequestedReference ?? "")
        await waitFor { store.state == .loaded }
        XCTAssertEqual(service.resolveCalls.count, 2)
    }

    func testNonFirstSelectionRetainedAcrossReload() async {
        let store = ReviewSessionStore(service: FakeService(), persistence: InMemoryPersistence())
        store.openDemo()
        await waitFor { store.state == .loaded }

        let second = store.review!.files[1].path
        store.select(filePath: second)
        store.openDemo()
        await waitFor { store.state == .loaded }

        XCTAssertEqual(store.selection.filePath, second, "non-first selection retained across reload")
    }

    func testOutdatedThreadsRenderUnderOutdatedHeader() async {
        let store = ReviewSessionStore(service: FakeService(), persistence: InMemoryPersistence())
        store.openDemo()
        await waitFor { store.state == .loaded }

        let appSwift = store.review!.files.first { $0.path.contains("App.swift") }!
        let rows = store.review!.diffRows(for: appSwift)
        XCTAssertTrue(rows.contains { $0.row == .outdatedHeader })
        // The demo has one outdated thread (demo-thread-2) rendered inline.
        XCTAssertTrue(rows.contains { displayRow in
            if case .thread(let id) = displayRow.row { return id == "demo-thread-2" }
            return false
        }, "outdated thread card must render under the outdated header")
    }

    // MARK: - Sidebar

    func testSidebarSearchFiltersAndSelectionFallback() async {
        let store = ReviewSessionStore(service: FakeService(), persistence: InMemoryPersistence())
        store.openDemo()
        await waitFor { store.state == .loaded }

        let all = store.filteredSidebarItems.count
        store.sidebarSearch = "README"
        XCTAssertLessThan(store.filteredSidebarItems.count, all)
        XCTAssertTrue(store.filteredSidebarItems.allSatisfy { $0.path.contains("README") })

        store.sidebarSearch = ""
        // Select a path, then reload: retained if present.
        store.select(filePath: store.review!.files[0].path)
        let kept = store.selection.filePath
        store.openDemo()
        await waitFor { store.state == .loaded }
        XCTAssertEqual(store.selection.filePath, kept, "selection retained across reload")

        // A vanished path falls back to the first file.
        store.select(filePath: "does-not-exist.swift")
        XCTAssertEqual(store.selection.filePath, store.review?.files.first?.path)
    }

    func testHidingViewedFilesLeavesOnlyWhatIsLeftToReview() async {
        let store = ReviewSessionStore(service: FakeService(), persistence: InMemoryPersistence())
        store.openDemo()
        await waitFor { store.state == .loaded }
        let paths = store.review!.files.map(\.path)
        store.toggleViewed(filePath: paths[0])

        let viewed = store.review!.viewed

        store.hideViewedFiles = true

        XCTAssertEqual(store.filteredSidebarItems.map(\.path), paths.filter { !viewed.contains($0) })
        store.sidebarSearch = paths[0]
        XCTAssertTrue(store.filteredSidebarItems.isEmpty, "the search only looks among unviewed files")
        store.sidebarSearch = ""
        store.hideViewedFiles = false
        XCTAssertEqual(store.filteredSidebarItems.map(\.path), paths)
    }

    // MARK: - Row identity

    /// Closing a review window releases the store AND its rendered-line cache:
    /// the store holds the only strong reference to the cache, and the load
    /// tasks capture the store weakly, so nothing pins either after the last
    /// view reference drops. (In the app, the view hierarchy holds the store;
    /// here we drop it directly.)
    func testStoreAndLineCacheAreReleasedWhenDropped() async {
        weak var weakStore: ReviewSessionStore?
        weak var weakCache: DiffLineCache?
        autoreleasepool {
            let store = ReviewSessionStore(service: FakeService(), persistence: InMemoryPersistence())
            // Fill the line cache so the dealloc assertion actually exercises
            // the node links (the retain-cycle regression).
            let langID = Highlighter.languageID(for: "a.swift")
            for i in 0..<50 {
                _ = store.diffLineCache.attributedString(
                    for: DiffLine(kind: .added, content: "line \(i) content", oldLine: nil, newLine: i),
                    languageID: langID, palette: SemanticTheme.light,
                    isDark: false, highContrast: false
                )
            }
            weakStore = store
            weakCache = store.diffLineCache
            XCTAssertTrue(store.diffLineCache.entryCount > 0, "cache must be populated before the dealloc check")
        }
        // Flush autorelease pools / let the main run loop settle.
        var drained = 0
        while (weakStore != nil || weakCache != nil) && drained < 30 {
            drained += 1
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(weakStore, "store must deallocate when the last view reference drops")
        XCTAssertNil(weakCache, "store must release its line cache (no retain cycle)")
    }

    func testDiffRowIDsAreStableAndDistinguishAnchors() throws {
        let files = DiffParser.parse(sampleDiff)
        let a = ReviewPresentation(endpoint: nil, pr: nil, files: files, threads: [], drafts: [], viewed: [])
        let b = ReviewPresentation(endpoint: nil, pr: nil, files: files, threads: [], drafts: [], viewed: [])

        let rowsA = a.diffRows(for: files[0])
        let rowsB = b.diffRows(for: files[0])
        XCTAssertEqual(rowsA.map(\.id), rowsB.map(\.id), "row IDs are stable across builds")

        let ids = Set(rowsA.map(\.id))
        XCTAssertEqual(ids.count, rowsA.count, "row IDs must be unique within a file")
        XCTAssertTrue(rowsA.contains { row in
            if case .line(_, _, _, let old, let new) = row.id { return old != nil && new != nil }
            return false
        }, "line rows carry both old and new anchors")
    }
}

// MARK: - Gated service for stale-load testing

@MainActor
private final class GatedService: GitHubServing {
    private(set) var fetchCalls = 0
    private var firstGate: CheckedContinuation<Void, Never>?
    var autoComplete = false
    var bundle = FetchBundle(pr: makePR(), files: DiffParser.parse(sampleDiff), threads: [])

    func ensureAvailable() async throws {}

    func resolveEndpoint(from argument: String) async throws -> PREndpoint {
        PREndpoint(owner: "o", repo: "r", number: 1)
    }

    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
        fetchCalls += 1
        if fetchCalls == 1 && !autoComplete {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                firstGate = cont
            }
        }
        return bundle
    }

    func releaseFirstFetch() {
        firstGate?.resume()
        firstGate = nil
    }

    func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {}
    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {}
    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {}
}

// MARK: - In-memory persistence

private final class InMemoryPersistence: ReviewPersisting {
    private var drafts: [String: [DraftComment]] = [:]
    private var present = Set<String>()
    private var viewed: [String: Set<String>] = [:]
    private var hidden: [String: Set<String>] = [:]

    func loadDraftState(for endpoint: PREndpoint, headSHA: String) async throws -> PersistedDraftState {
        let k = "\(endpoint.owner)/\(endpoint.repo)#\(endpoint.number)@\(headSHA)"
        if present.contains(k) { return .present(drafts[k] ?? []) }
        return .missing
    }

    func saveDrafts(_ drafts: [DraftComment], for endpoint: PREndpoint, headSHA: String) async throws {
        let k = "\(endpoint.owner)/\(endpoint.repo)#\(endpoint.number)@\(headSHA)"
        self.drafts[k] = drafts
        present.insert(k)
    }

    func loadViewed(for endpoint: PREndpoint, headSHA: String) async throws -> Set<String> {
        let k = "\(endpoint.owner)/\(endpoint.repo)#\(endpoint.number)@\(headSHA)"
        return viewed[k] ?? []
    }

    func saveViewed(_ viewed: Set<String>, for endpoint: PREndpoint, headSHA: String) async throws {
        let k = "\(endpoint.owner)/\(endpoint.repo)#\(endpoint.number)@\(headSHA)"
        self.viewed[k] = viewed
    }

    func loadHiddenReviewers(for endpoint: PREndpoint) async throws -> Set<String> {
        hidden[prKey(endpoint)] ?? []
    }

    func saveHiddenReviewers(_ hiddenReviewers: Set<String>, for endpoint: PREndpoint) async throws {
        hidden[prKey(endpoint)] = hiddenReviewers
    }

    private func prKey(_ endpoint: PREndpoint) -> String {
        "\(endpoint.owner)/\(endpoint.repo)#\(endpoint.number)"
    }
}
