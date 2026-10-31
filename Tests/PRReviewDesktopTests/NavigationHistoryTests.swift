import XCTest
@testable import PRReviewDesktop

final class NavigationHistoryTests: XCTestCase {

    func testBackAndForwardWalkVisitedLocations() {
        var history = NavigationHistory<ReviewLocation>()
        history.visit(.canvas)
        history.visit(.file("a.swift"))
        history.visit(.file("b.swift"))

        XCTAssertEqual(history.back(), .file("a.swift"))
        XCTAssertEqual(history.back(), .canvas)
        XCTAssertNil(history.back())
        XCTAssertEqual(history.forward(), .file("a.swift"))
        XCTAssertEqual(history.forward(), .file("b.swift"))
        XCTAssertNil(history.forward())
    }

    func testVisitingAfterGoingBackDropsTheForwardEntries() {
        var history = NavigationHistory<ReviewLocation>()
        history.visit(.file("a.swift"))
        history.visit(.file("b.swift"))
        _ = history.back()

        history.visit(.file("c.swift"))

        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.back(), .file("a.swift"))
    }

    func testRevisitingTheCurrentLocationIsNotANewEntry() {
        var history = NavigationHistory<ReviewLocation>()
        history.visit(.file("a.swift"))
        history.visit(.file("a.swift"))

        XCTAssertFalse(history.canGoBack)
    }

    func testOldestEntriesFallOffPastTheLimit() {
        var history = NavigationHistory<ReviewLocation>(limit: 3)
        for name in ["a", "b", "c", "d"] {
            history.visit(.file(name))
        }

        XCTAssertEqual(history.back(), .file("c"))
        XCTAssertEqual(history.back(), .file("b"))
        XCTAssertNil(history.back())
    }
}
