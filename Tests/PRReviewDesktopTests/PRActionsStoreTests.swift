import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

private final class ActionService: GitHubServing {
    private let lock = NSLock()
    private var _performed: [PRAction] = []
    private var _fetches = 0
    var actionState: PRActionState?
    var performError: Error?

    var performed: [PRAction] { locked { _performed } }
    var fetches: Int { locked { _fetches } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func ensureAvailable() async throws {}
    func resolveEndpoint(from argument: String) async throws -> PREndpoint {
        PREndpoint(owner: "o", repo: "r", number: 1)
    }
    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
        locked { _fetches += 1 }
        return FetchBundle(
            pr: PRInfo(number: 1, title: "PR", body: nil, author: "a", state: "OPEN", isDraft: false,
                       headRefOid: "sha1", headRefName: "head", baseRefName: "base",
                       additions: 1, deletions: 0, changedFiles: 1, reviewDecision: nil,
                       url: "https://github.com/o/r/pull/1"),
            files: DiffParser.parse("diff --git a/A.swift b/A.swift\n--- a/A.swift\n+++ b/A.swift\n@@ -1 +1 @@\n-a\n+b\n"),
            threads: []
        )
    }
    func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {}
    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {}
    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {}
    func fetchActionState(_ ep: PREndpoint) async throws -> PRActionState? { actionState }
    func perform(_ action: PRAction, on ep: PREndpoint) async throws {
        if let performError { throw performError }
        locked { _performed.append(action) }
    }
}

private final class NoPersistence: ReviewPersisting {
    func loadDraftState(for endpoint: PREndpoint, headSHA: String) async throws -> PersistedDraftState { .missing }
    func saveDrafts(_ drafts: [DraftComment], for endpoint: PREndpoint, headSHA: String) async throws {}
    func loadViewed(for endpoint: PREndpoint, headSHA: String) async throws -> Set<String> { [] }
    func saveViewed(_ viewed: Set<String>, for endpoint: PREndpoint, headSHA: String) async throws {}
    func loadHiddenReviewers(for endpoint: PREndpoint) async throws -> Set<String> { [] }
    func saveHiddenReviewers(_ hidden: Set<String>, for endpoint: PREndpoint) async throws {}
}

@MainActor
final class PRActionsStoreTests: XCTestCase {

    private let writer = PRActionState(
        state: "OPEN", isDraft: false, mergeable: "MERGEABLE", viewerPermission: "WRITE",
        viewerCanUpdate: true, viewerDidAuthor: false, allowedMergeMethods: [.squash]
    )

    private func waitSync(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("condition not met within \(timeout)s")
    }

    private func loadedStore(_ service: ActionService) -> ReviewSessionStore {
        let store = ReviewSessionStore(service: service, persistence: NoPersistence())
        store.open(reference: "o/r#1")
        waitSync { store.state == .loaded && store.actionState != nil }
        return store
    }

    func testLoadFetchesWhatTheViewerMayDo() {
        let service = ActionService()
        service.actionState = writer

        let store = loadedStore(service)

        XCTAssertEqual(store.actionState?.mergeMethods, [.squash])
    }

    func testMergeRunsTheActionAndRefreshes() {
        let service = ActionService()
        service.actionState = writer
        let store = loadedStore(service)

        store.perform(.merge(.squash))
        waitSync { service.fetches == 2 && store.runningAction == nil }

        XCTAssertEqual(service.performed, [.merge(.squash)])
        XCTAssertEqual(store.banner?.text, "Merged.")
    }

    func testFailedActionSurfacesAnErrorBanner() {
        let service = ActionService()
        service.actionState = writer
        service.performError = GitHubError.api("Base branch was modified")
        let store = loadedStore(service)

        store.perform(.close)
        waitSync { store.banner?.isError == true }

        XCTAssertNil(store.runningAction)
        XCTAssertTrue(store.banner?.text.contains("Base branch was modified") ?? false)
        XCTAssertEqual(service.fetches, 1)
    }

    func testDemoHasNoActions() {
        let store = ReviewSessionStore(service: ActionService(), persistence: NoPersistence())

        store.openDemo()
        waitSync { store.state == .loaded }

        XCTAssertNil(store.actionState)
    }

    func testApproveWithUnsentDraftsOpensTheSubmitSheetSetToApprove() {
        let service = ActionService()
        service.actionState = writer
        let store = loadedStore(service)
        store.review = store.review?.withDrafts([DraftComment(path: "A.swift", line: 1, side: "RIGHT", body: "nit")])

        store.approve()

        XCTAssertEqual(store.submitState, .editing)
        XCTAssertEqual(store.submitEvent, .approve)
        XCTAssertEqual(service.performed, [])
    }
}
