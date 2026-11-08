import XCTest
import AppKit
import SwiftUI
@testable import PRReviewKit
@testable import PRReviewDesktop

/// Renders the review UI to PNGs for pull request descriptions, off screen
/// and with offline demo data. Skipped unless `PR_REVIEW_SCREENSHOTS` names
/// an output directory.
@MainActor
final class ScreenshotRenderTests: XCTestCase {

    private var outputDirectory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["PR_REVIEW_SCREENSHOTS"] else {
            throw XCTSkip("Set PR_REVIEW_SCREENSHOTS=<dir> to render screenshots")
        }
        outputDirectory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: DiffTextSize.key)
        UserDefaults.standard.removeObject(forKey: OverviewMode.key)
    }

    // MARK: - PR 2: review flow

    func testFocusedFileBar() throws {
        let store = try loadedStore()
        store.select(filePath: "Sources/Inbox/InboxStore.swift")
        try render("focused-file-bar", size: CGSize(width: 900, height: 330)) {
            VStack(spacing: 0) {
                FocusedFileBar(store: store, file: store.selectedFile!)
                Divider()
                DiffView(store: store, file: store.selectedFile!, presentation: .constant(.unified))
            }
        }
    }

    func testPullRequestHeader() throws {
        let store = try loadedStore()
        try render("pr-header", size: CGSize(width: 900, height: 90)) {
            PullRequestHeaderView(review: store.review!)
        }
    }

    func testExpandHiddenLinesUnified() throws {
        let store = try loadedStore()
        let file = store.review!.files.first { $0.path == "Sources/Inbox/SearchQuery.swift" }!
        try render("expand-hidden-lines-unified", size: CGSize(width: 900, height: 230)) {
            DiffView(store: store, file: file, presentation: .constant(.unified))
        }
    }

    func testExpandHiddenLinesSideBySide() throws {
        let store = try loadedStore()
        let file = store.review!.files.first { $0.path == "Sources/Inbox/SearchQuery.swift" }!
        try render("expand-hidden-lines-split", size: CGSize(width: 1000, height: 250)) {
            DiffView(store: store, file: file, presentation: .constant(.sideBySide))
        }
    }

    func testTextSize() throws {
        let store = try loadedStore()
        let file = store.review!.files.first { $0.path == "Sources/Inbox/InboxStore.swift" }!
        for size in [12.0, 18.0] {
            UserDefaults.standard.set(size, forKey: DiffTextSize.key)
            try render("text-size-\(Int(size))pt", size: CGSize(width: 900, height: 260)) {
                DiffView(store: store, file: file, presentation: .constant(.unified))
            }
        }
        UserDefaults.standard.removeObject(forKey: DiffTextSize.key)
    }

    func testListOverview() throws {
        let store = try loadedStore()
        store.toggleViewed(filePath: "README.md")
        try render("list-overview", size: CGSize(width: 1000, height: 560)) {
            StackedDiffsView(store: store, files: store.review!.files, presentation: .unified, showCanvas: .constant(true))
        }
    }

    func testViewedSyncSetting() throws {
        try render("settings-viewed-sync", size: CGSize(width: 420, height: 130)) {
            GitHubSettingsView()
        }
    }

    // MARK: - PR 4: inbox

    func testInbox() throws {
        let inbox = try loadedInbox(grouped: true)
        let store = try loadedStore()
        try render("inbox-grouped", size: CGSize(width: 340, height: 980)) {
            InboxSidebarView(inbox: inbox, store: store)
        }
    }

    func testInboxFlat() throws {
        let inbox = try loadedInbox(grouped: false)
        let store = try loadedStore()
        try render("inbox-flat", size: CGSize(width: 340, height: 520)) {
            InboxSidebarView(inbox: inbox, store: store)
        }
    }

    func testWelcomeWindowWithInbox() throws {
        let inbox = try loadedInbox(grouped: true)
        let store = ReviewSessionStore(service: ScreenshotService(), persistence: ScreenshotPersistence())
        try render("window-welcome-inbox", size: CGSize(width: 1100, height: 700)) {
            ReviewWindowView(store: store, inbox: inbox)
        }
    }

    // MARK: - Fixtures

    // MARK: - Bulk viewed

    func testBulkViewedFolder() throws {
        let store = try loadedStore()
        try render("bulk-viewed-before", size: CGSize(width: 320, height: 240)) {
            FileSidebarView(store: store, showCanvas: .constant(false), focusSearch: .constant(false))
        }
        store.setViewed(.folder("Sources/Inbox"), viewed: true)
        try render("bulk-viewed-after", size: CGSize(width: 320, height: 240)) {
            FileSidebarView(store: store, showCanvas: .constant(false), focusSearch: .constant(false))
        }
    }

    // MARK: - Load progress

    func testLoadingWindowShowsProgress() throws {
        let defaults = UserDefaults(suiteName: "screenshots-\(UUID().uuidString)")!
        let inbox = InboxStore(service: ScreenshotService(), defaults: defaults, refreshesOnChange: false)
        let store = ReviewSessionStore(service: SlowLoadService(), persistence: ScreenshotPersistence())
        store.open(reference: "acme/review-app#42")
        pump { store.loadProgress.sizeSummary != nil }
        try render("loading-progress", size: CGSize(width: 900, height: 420)) {
            ReviewWindowView(store: store, inbox: inbox)
        }
        store.cancelLoad()
    }

    func testLoadingFromAnOpenPullRequest() throws {
        let defaults = UserDefaults(suiteName: "screenshots-\(UUID().uuidString)")!
        let inbox = InboxStore(service: ScreenshotService(), defaults: defaults, refreshesOnChange: false)
        let service = SlowLoadService()
        service.quickFirstLoad = true
        let store = ReviewSessionStore(service: service, persistence: ScreenshotPersistence())
        store.open(reference: "acme/review-app#41")
        pump { store.state == .loaded || store.state == .empty }
        let size = CGSize(width: 900, height: 420)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: ReviewWindowView(store: store, inbox: inbox)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = hosting
        try snapshot(hosting, window, "reopen-loaded", size)
        store.open(reference: "acme/review-app#42")
        pump { store.loadProgress.sizeSummary != nil }
        try snapshot(hosting, window, "reopen-loading", size)
        store.cancelLoad()
    }

    func testDragSelectsCode() throws {
        let store = try loadedStore()
        store.select(filePath: "Sources/Inbox/InboxStore.swift")
        let size = CGSize(width: 900, height: 330)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: DiffView(store: store, file: store.selectedFile!, presentation: .constant(.unified))
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = hosting
        try snapshot(hosting, window, "select-before", size)
        func find(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("AppKitDiffSurfaceNSView") { return view }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        let surface = try XCTUnwrap(find(hosting))
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: surface.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        surface.mouseDown(with: event(.leftMouseDown, NSPoint(x: 140, y: 40)))
        surface.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 260, y: 100)))
        try snapshot(hosting, window, "select-after", size)
    }

    func testFindInFile() throws {
        let store = try loadedStore()
        store.select(filePath: "Sources/Inbox/InboxStore.swift")
        store.beginFind()
        store.setFindQuery("isRefreshing")
        store.findNext()
        try render("find-in-file", size: CGSize(width: 900, height: 330)) {
            VStack(spacing: 0) {
                FindBar(store: store)
                Divider()
                DiffView(store: store, file: store.selectedFile!, presentation: .constant(.unified))
            }
        }
    }

    private func loadedStore() throws -> ReviewSessionStore {
        let store = ReviewSessionStore(service: ScreenshotService(), persistence: ScreenshotPersistence())
        store.open(reference: "acme/review-app#42")
        pump { store.state == .loaded }
        guard store.review != nil else { throw XCTSkip("demo review did not load") }
        return store
    }

    private func loadedInbox(grouped: Bool) throws -> InboxStore {
        let defaults = UserDefaults(suiteName: "screenshots-\(UUID().uuidString)")!
        let inbox = InboxStore(service: ScreenshotService(), defaults: defaults, refreshesOnChange: false)
        inbox.setSection(.team, enabled: true)
        inbox.toggleTeamOrganization("acme")
        inbox.toggleRepositoryCollapsed("acme/legacy-api")
        inbox.setGroupByRepository(grouped)
        let done = expectation(description: "inbox refreshed")
        Task { await inbox.refresh(); done.fulfill() }
        wait(for: [done], timeout: 5)
        return inbox
    }

    private func render<Content: View>(_ name: String, size: CGSize, @ViewBuilder content: () -> Content) throws {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        // An unshown window is inactive; render as the active window people see.
        // Opaque: anything SwiftUI leaves unpainted would otherwise come out
        // transparent and show the viewer's own background through it.
        let hosting = NSHostingView(rootView: content()
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key))
        window.contentView = hosting
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw XCTSkip("no bitmap") }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(Self.flattenedPNG(bitmap))
        try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    private func snapshot(_ hosting: NSView, _ window: NSWindow, _ name: String, _ size: CGSize) throws {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(Self.flattenedPNG(bitmap)).write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    /// Composites the render onto the window background and drops the alpha
    /// channel, so viewers never show their own background through it.
    private static func flattenedPNG(_ bitmap: NSBitmapImageRep) -> Data? {
        guard let image = bitmap.cgImage,
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        let background = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .white
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flat = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:])
    }

    private func pump(timeout: TimeInterval = 3, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

// MARK: - Demo data

private let inboxStoreLines: [String] = [
    "import Foundation",
    "",
    "/// The app-wide pull request inbox.",
    "@MainActor",
    "public final class InboxStore: ObservableObject {",
    "    @Published public private(set) var sections: [InboxSection]",
    "    @Published public private(set) var isRefreshing = false",
    "",
    "    public func refresh() async {",
    "        guard !isRefreshing else { return }",
    "        isRefreshing = true",
    "        defer { isRefreshing = false }",
    "        await fetchSections()",
    "    }",
    "}",
]

private let searchQueryLines: [String] = (1...60).map { line in
    switch line {
    case 48: return "    public func searchQuery(filter: InboxFilter) -> String? {"
    case 49: return "        var terms = [\"is:pr\", \"archived:false\"]"
    case 50: return "        terms += filter.labels.map { \"label:\\\"\\($0)\\\"\" }"
    case 51: return "        terms.append(\"sort:updated-desc\")"
    case 52: return "        return terms.joined(separator: \" \")"
    case 53: return "    }"
    default: return "    // search qualifiers, line \(line)"
    }
}

private func demoDiff() -> String {
    """
    diff --git a/Sources/Inbox/InboxStore.swift b/Sources/Inbox/InboxStore.swift
    --- a/Sources/Inbox/InboxStore.swift
    +++ b/Sources/Inbox/InboxStore.swift
    @@ -6,9 +6,10 @@ public final class InboxStore: ObservableObject {
         @Published public private(set) var sections: [InboxSection]
    -    @Published public var isRefreshing = false
    +    @Published public private(set) var isRefreshing = false

         public func refresh() async {
    -        isRefreshing = true
    +        guard !isRefreshing else { return }
    +        isRefreshing = true
             defer { isRefreshing = false }
             await fetchSections()
         }
    diff --git a/Sources/Inbox/SearchQuery.swift b/Sources/Inbox/SearchQuery.swift
    --- a/Sources/Inbox/SearchQuery.swift
    +++ b/Sources/Inbox/SearchQuery.swift
    @@ -47,6 +47,7 @@ extension InboxSection {
         // search qualifiers, line 47
         public func searchQuery(filter: InboxFilter) -> String? {
             var terms = ["is:pr", "archived:false"]
    +        terms += filter.labels.map { "label:\\"\\($0)\\"" }
             terms.append("sort:updated-desc")
             return terms.joined(separator: " ")
         }
    diff --git a/README.md b/README.md
    --- a/README.md
    +++ b/README.md
    @@ -1,3 +1,4 @@
     # Review
    +- **Inbox**: pull requests across your repositories.
     - **Read the diff** with fixed gutters.
     - **Comment inline** on any line.
    """
}

private func row(_ number: Int, _ repository: String, _ title: String, author: String, checks: String?, decision: String?, labels: [(String, String)] = [], draft: Bool = false, state: String = "OPEN") -> PRSummary {
    PRSummary(
        id: "PR_\(number)", number: number, title: title, repository: repository, author: author,
        url: "https://github.com/\(repository)/pull/\(number)", state: state, isDraft: draft,
        reviewDecision: decision, checksState: checks,
        labels: labels.map { PRLabel(name: $0.0, color: $0.1) },
        updatedAt: Date(), additions: 12, deletions: 3
    )
}

private final class ScreenshotService: GitHubServing, @unchecked Sendable {
    func ensureAvailable() async throws {}
    func resolveEndpoint(from argument: String) async throws -> PREndpoint {
        PREndpoint(owner: "acme", repo: "review-app", number: 42)
    }
    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
        let pr = PRInfo(
            number: 42, title: "Inbox of pull requests across repositories", body: """
            Adds an inbox to the sidebar so reviews start from a list instead of a pasted URL.

            - sections for review requests, my PRs and the team
            - label filter applied in the search query
            """,
            author: "octocat", state: "OPEN", isDraft: false, headRefOid: "0123456789abcdef0123456789abcdef01234567",
            headRefName: "feat/inbox", baseRefName: "main", additions: 14, deletions: 2, changedFiles: 3,
            reviewDecision: "REVIEW_REQUIRED", url: "https://github.com/acme/review-app/pull/42",
            checks: PRChecksSummary(passed: 11, failed: 1, pending: 2), nodeID: "PR_42"
        )
        return FetchBundle(pr: pr, files: DiffParser.parse(demoDiff()), threads: [])
    }
    func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {}
    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {}
    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {}
    func fetchFileLines(_ endpoint: PREndpoint, path: String, ref: String) async throws -> [String] {
        path.hasSuffix("SearchQuery.swift") ? searchQueryLines : inboxStoreLines
    }
    func fetchViewerScope() async throws -> InboxScope {
        InboxScope(login: "octocat", organizations: ["acme", "tools"])
    }
    func searchPullRequests(query: String, first: Int) async throws -> [PRSummary] {
        let agentic = ("agentic-workflows", "7057ff")
        if query.contains("review-requested:@me") {
            return [
                row(5971, "acme/sales", "Quote flow: reuse the cached rates", author: "ana", checks: "SUCCESS", decision: "REVIEW_REQUIRED", labels: [agentic]),
                row(5958, "acme/sales", "Retry webhook deliveries with backoff", author: "luis", checks: "PENDING", decision: "REVIEW_REQUIRED"),
                row(67, "acme/data-notebooks", "Monthly cohort notebook", author: "mila", checks: "SUCCESS", decision: "APPROVED", labels: [("data", "0e8a16")]),
                row(12, "acme/legacy-api", "Bump the TLS minimum", author: "ops-bot", checks: "FAILURE", decision: "CHANGES_REQUESTED"),
            ]
        }
        if query.contains("is:open archived:false author:@me") {
            return [
                row(506, "acme/app", "Open a PR preview on a staging build", author: "octocat", checks: "SUCCESS", decision: "APPROVED", labels: [agentic, ("ota", "fbca04")]),
                row(504, "acme/app", "Land on the screen a link names", author: "octocat", checks: "FAILURE", decision: "REVIEW_REQUIRED", draft: true),
            ]
        }
        if query.contains("org:acme") {
            return [
                row(5972, "acme/sales", "Agentic: summarize claim notes", author: "bot-agent", checks: "SUCCESS", decision: "REVIEW_REQUIRED", labels: [agentic]),
                row(301, "acme/infra", "Rotate the runner tokens", author: "ops", checks: "PENDING", decision: nil),
            ]
        }
        return [
            row(499, "acme/app", "Read member announcements from the backend", author: "octocat", checks: "SUCCESS", decision: "APPROVED", state: "MERGED"),
        ]
    }
}

private final class ScreenshotPersistence: ReviewPersisting {
    func loadDraftState(for endpoint: PREndpoint, headSHA: String) async throws -> PersistedDraftState { .missing }
    func saveDrafts(_ drafts: [DraftComment], for endpoint: PREndpoint, headSHA: String) async throws {}
    func loadViewed(for endpoint: PREndpoint, headSHA: String) async throws -> Set<String> { [] }
    func saveViewed(_ viewed: Set<String>, for endpoint: PREndpoint, headSHA: String) async throws {}
    func loadHiddenReviewers(for endpoint: PREndpoint) async throws -> Set<String> { [] }
    func saveHiddenReviewers(_ hidden: Set<String>, for endpoint: PREndpoint) async throws {}
}

/// Reports the pull request's size and the first page of files, then never
/// finishes, so the window stays on its loading screen.
private final class SlowLoadService: GitHubServing {
    var quickFirstLoad = false
    private var loads = 0
    func ensureAvailable() async throws {}
    func resolveEndpoint(from argument: String) async throws -> PREndpoint { PREndpoint(owner: "acme", repo: "review-app", number: 42) }
    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle { try await fetchAll(ep) { _ in } }
    func fetchAll(_ ep: PREndpoint, progress: @escaping FetchProgressHandler) async throws -> FetchBundle {
        loads += 1
        if quickFirstLoad && loads == 1 { return try await ScreenshotService().fetchAll(ep) }
        progress(.size(files: 1840, additions: 52_310, deletions: 9_412))
        progress(.diffRefused)
        progress(.filesFetched(600))
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }
    func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {}
    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {}
    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {}
}
