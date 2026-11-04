import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

final class BulkViewedTests: XCTestCase {

    private func item(_ path: String, _ status: String = "M", added: Int? = 1, deleted: Int? = 1) -> FileSidebarItem {
        FileSidebarItem(path: path, oldPath: nil, statusLetter: status, additions: added, deletions: deleted,
                        isBinary: false, tooLarge: false, threadCount: 0, isViewed: false)
    }

    private lazy var items = [
        item("Sources/App/Main.swift"),
        item("Sources/App/Old.swift", "D", added: 0, deleted: 40),
        item("Sources/AppKit/View.swift"),
        item("Sources/Moved.swift", "R", added: 0, deleted: 0),
        item("Sources/Renamed.swift", "R", added: 2, deleted: 1),
        item("Package.resolved"),
        item("yarn.lock"),
        item("web/yarn.lock"),
        item(".gitignore"),
        item("Makefile"),
    ]

    func testDeletedAndPureRenames() {
        XCTAssertEqual(BulkViewedScope.deleted.paths(in: items), ["Sources/App/Old.swift"])
        XCTAssertEqual(BulkViewedScope.pureRenames.paths(in: items), ["Sources/Moved.swift"])
    }

    func testFolderMatchesWholeSegmentsOnly() {
        XCTAssertEqual(BulkViewedScope.folder("Sources/App").paths(in: items),
                       ["Sources/App/Main.swift", "Sources/App/Old.swift"])
        XCTAssertEqual(BulkViewedScope.folder("Sources").paths(in: items).count, 5)
    }

    func testExtensionIgnoresDotfilesAndExtensionlessNames() {
        XCTAssertEqual(BulkViewedScope.fileExtension("lock").paths(in: items), ["yarn.lock", "web/yarn.lock"])
        XCTAssertNil(BulkViewedScope.fileExtension(of: ".gitignore"))
        XCTAssertNil(BulkViewedScope.fileExtension(of: "Makefile"))
        XCTAssertEqual(BulkViewedScope.fileExtension(of: "a/b.test.ts"), "ts")
    }

    func testExplicitPathsAndAll() {
        XCTAssertEqual(BulkViewedScope.paths(["Makefile", "Gone.swift"]).paths(in: items), ["Makefile"])
        XCTAssertEqual(BulkViewedScope.all.paths(in: items).count, items.count)
    }
}
