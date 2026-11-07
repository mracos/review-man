import XCTest
@testable import PRReviewDesktop

final class OpeningPreferencesTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "OpeningPreferencesTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsKeepTheLastOverviewUnifiedAndTheSidebarAsIs() {
        let preferences = OpeningPreferences(defaults: defaults)

        XCTAssertEqual(preferences.overview(lastUsed: .list), .list)
        XCTAssertEqual(preferences.diffLayout, .unified)
        XCTAssertEqual(preferences.sidebar, .unchanged)
    }

    func testAChosenPaneWinsOverTheLastOverview() {
        defaults.set(OpeningPane.canvas.rawValue, forKey: OpeningPane.key)
        XCTAssertEqual(OpeningPreferences(defaults: defaults).overview(lastUsed: .list), .canvas)

        defaults.set(OpeningPane.firstFile.rawValue, forKey: OpeningPane.key)
        XCTAssertNil(OpeningPreferences(defaults: defaults).overview(lastUsed: .canvas))
    }

    func testStoredLayoutAndSidebarAreRead() {
        defaults.set(DiffPresentation.sideBySide.rawValue, forKey: OpeningPreferences.diffLayoutKey)
        defaults.set(OpeningSidebar.files.rawValue, forKey: OpeningSidebar.key)

        let preferences = OpeningPreferences(defaults: defaults)

        XCTAssertEqual(preferences.diffLayout, .sideBySide)
        XCTAssertEqual(preferences.sidebar, .files)
    }

    func testUnknownStoredValuesFallBackToDefaults() {
        defaults.set("bogus", forKey: OpeningPane.key)
        defaults.set("bogus", forKey: OpeningPreferences.diffLayoutKey)

        let preferences = OpeningPreferences(defaults: defaults)

        XCTAssertEqual(preferences.pane, .lastOverview)
        XCTAssertEqual(preferences.diffLayout, .unified)
    }
}
