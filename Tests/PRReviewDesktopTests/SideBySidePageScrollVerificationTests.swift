import XCTest
import AppKit
import SwiftUI
@testable import PRReviewKit
@testable import PRReviewDesktop

/// Verifies Page Up / Page Down behaviour in the Side by Side diff panes.
///
/// The panes are SwiftUI `ScrollView`s backed by `NSScrollView`, whose native
/// keyboard paging only applies while the scroll content is first responder.
/// `SideBySideKeyboardMonitor` routes these keys through the shared
/// `SideBySideScrollCoordinator` instead, so paging must work regardless of
/// keyboard focus. These tests drive real `keyDown` events through an
/// `NSWindow` hosting the live `SideBySideDiffView` and read the actual
/// clip-view bounds of both panes.
@MainActor
final class SideBySidePageScrollVerificationTests: XCTestCase {

    func testPageUpDownScrollsAndSyncsBothPanes() throws {
        var diff = "diff --git a/Big.swift b/Big.swift\n--- a/Big.swift\n+++ b/Big.swift\n"
        diff += "@@ -1,400 +1,400 @@\n"
        for i in 1...400 { diff += " line \(i): let value\(i) = \(i)\n" }
        let file = DiffParser.parse(diff)[0]

        let service = FakeService(bundle: FetchBundle(
            pr: FakeService.prInfo(), files: [file], threads: []
        ))
        let store = ReviewSessionStore(service: service, persistence: InMemoryPersistence())
        store.open(reference: "o/r#1")
        pump(seconds: 2)
        guard store.review != nil else { return XCTFail("no review loaded") }

        // Never shown: the keyboard monitor only checks that an event belongs
        // to the hosting window, so the window needs to exist and lay out,
        // not to be on screen, key, or give the test runner a Dock icon.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        // Owned by this test under ARC; the AppKit default would release it a
        // second time when it goes away.
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SideBySideDiffView(store: store, file: file))
        window.contentView = hosting
        // Creates the shared application (NSApp) for event dispatch without
        // changing its activation policy.
        _ = NSApplication.shared
        layOut(window, seconds: 3)

        let scrollViews = findScrollViews(in: hosting)
        XCTAssertEqual(scrollViews.count, 2, "expected two side-by-side panes")
        let oldPane = scrollViews.min { $0.frame.minX < $1.frame.minX }!
        let newPane = scrollViews.max { $0.frame.minX < $1.frame.minX }!

        // Page Down with no first responder inside the panes — exactly the
        // state after simply clicking a diff row. Paging must still work.
        sendKeyDown(code: 121, chars: "\u{F72D}", to: window)
        pump(seconds: 1)
        let afterFirstPageDownOld = oldPane.contentView.bounds.origin.y
        let afterFirstPageDownNew = newPane.contentView.bounds.origin.y

        XCTAssertGreaterThan(afterFirstPageDownOld, 10, "Page Down did not scroll the Before pane")
        XCTAssertGreaterThan(afterFirstPageDownNew, 10, "Page Down did not scroll the After pane")
        XCTAssertEqual(afterFirstPageDownOld, afterFirstPageDownNew, accuracy: 2,
                       "panes diverged after Page Down")

        // Control: scrolling the left pane must mirror onto the right pane
        // via the shared scroll coordinator.
        oldPane.contentView.scroll(to: NSPoint(x: 0, y: afterFirstPageDownOld + 200))
        pump(seconds: 0.5)
        XCTAssertEqual(oldPane.contentView.bounds.origin.y, newPane.contentView.bounds.origin.y, accuracy: 2,
                       "panes not synced after left-pane scroll")
        pump(seconds: 0.5)
        XCTAssertEqual(oldPane.contentView.bounds.origin.y, newPane.contentView.bounds.origin.y, accuracy: 2,
                       "panes not synced after left-pane scroll")
        oldPane.contentView.scroll(to: NSPoint(x: 0, y: oldPane.contentView.bounds.origin.y))
        pump(seconds: 0.3)

        // A second Page Down from wherever the control scroll left off.
        let beforeSecondPageDownOld = oldPane.contentView.bounds.origin.y
        sendKeyDown(code: 121, chars: "\u{F72D}", to: window)
        pump(seconds: 1)
        let afterSecondPageDownOld = oldPane.contentView.bounds.origin.y
        let afterSecondPageDownNew = newPane.contentView.bounds.origin.y

        XCTAssertGreaterThan(afterSecondPageDownOld, beforeSecondPageDownOld + 10,
                             "second Page Down did not scroll further")
        XCTAssertGreaterThan(afterSecondPageDownNew, 10, "Page Down did not scroll the After pane")
        XCTAssertEqual(afterSecondPageDownOld, afterSecondPageDownNew, accuracy: 2,
                       "panes diverged after Page Down")

        sendKeyDown(code: 116, chars: "\u{F72C}", to: window)
        pump(seconds: 1)
        let afterPageDownOld = oldPane.contentView.bounds.origin.y
        let afterPageDownNew = newPane.contentView.bounds.origin.y

        XCTAssertGreaterThan(afterPageDownOld, 10, "Page Down did not scroll the Before pane")
        XCTAssertGreaterThan(afterPageDownNew, 10, "Page Down did not scroll the After pane")
        XCTAssertEqual(afterPageDownOld, afterPageDownNew, accuracy: 2, "panes diverged after Page Down")

        sendKeyDown(code: 116, chars: "\u{F72C}", to: window)
        pump(seconds: 1)
        let afterPageUpOld = oldPane.contentView.bounds.origin.y
        let afterPageUpNew = newPane.contentView.bounds.origin.y

        XCTAssertLessThan(afterPageUpOld, afterSecondPageDownOld - 10, "Page Up did not scroll back")
        XCTAssertEqual(afterPageUpOld, afterPageUpNew, accuracy: 2, "panes diverged after Page Up")
        window.close()
    }

    private func findScrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        for sub in view.subviews {
            if let sv = sub as? NSScrollView { found.append(sv) }
            found.append(contentsOf: findScrollViews(in: sub))
        }
        return found
    }

    private func sendKeyDown(code: UInt16, chars: String, to window: NSWindow) {
        if let e = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code
        ) {
            // Route through the application so app-level local event
            // monitors (as installed by SideBySideKeyboardMonitor) fire.
            NSApp.sendEvent(e)
        }
    }

    /// Lays the off-screen window out while pumping the run loop, standing in
    /// for the display cycle an on-screen window would get.
    private func layOut(_ window: NSWindow, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func pump(seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

private final class FakeService: GitHubServing {
    let bundle: FetchBundle?
    init(bundle: FetchBundle?) { self.bundle = bundle }
    func ensureAvailable() async throws {}
    func resolveEndpoint(from argument: String) async throws -> PREndpoint {
        PREndpoint(owner: "o", repo: "r", number: 1)
    }
    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
        bundle ?? FetchBundle(pr: FakeService.prInfo(), files: [], threads: [])
    }
    func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {}
    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {}
    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {}

    static func prInfo() -> PRInfo {
        PRInfo(number: 1, title: "PR", body: nil, author: "a", state: "OPEN", isDraft: false,
               headRefOid: "sha1", headRefName: "head", baseRefName: "base",
               additions: 10, deletions: 4, changedFiles: 1, reviewDecision: nil,
               url: "https://github.com/o/r/pull/1")
    }
}

private final class InMemoryPersistence: ReviewPersisting {
    func loadDraftState(for endpoint: PREndpoint, headSHA: String) async throws -> PersistedDraftState { .missing }
    func saveDrafts(_ drafts: [DraftComment], for endpoint: PREndpoint, headSHA: String) async throws {}
    func loadViewed(for endpoint: PREndpoint, headSHA: String) async throws -> Set<String> { [] }
    func saveViewed(_ viewed: Set<String>, for endpoint: PREndpoint, headSHA: String) async throws {}
    func loadHiddenReviewers(for endpoint: PREndpoint) async throws -> Set<String> { [] }
    func saveHiddenReviewers(_ hidden: Set<String>, for endpoint: PREndpoint) async throws {}
}
