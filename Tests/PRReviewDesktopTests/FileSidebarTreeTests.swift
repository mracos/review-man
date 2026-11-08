import XCTest
@testable import PRReviewDesktop

final class FileSidebarTreeTests: XCTestCase {

    func testBuildsNaturallySortedFolderHierarchyWithFoldersFirst() throws {
        let tree = FileSidebarTreeNode.build(from: [
            item("README.md"),
            item("Sources/App.swift"),
            item("Sources/Views/ChangeCanvasView.swift"),
            item("Tests/AppTests.swift")
        ])

        XCTAssertEqual(tree.map(\.name), ["Sources", "Tests", "README.md"])

        let sources = try XCTUnwrap(tree.first(where: { $0.path == "Sources" }))
        XCTAssertEqual(sources.fileCount, 2)
        XCTAssertEqual(sources.children.map(\.name), ["Views", "App.swift"])
        XCTAssertEqual(sources.children.first?.children.map(\.name), ["ChangeCanvasView.swift"])
        XCTAssertEqual(
            FileSidebarTreeNode.folderIDs(from: [
                item("README.md"),
                item("Sources/App.swift"),
                item("Sources/Views/ChangeCanvasView.swift"),
                item("Tests/AppTests.swift")
            ]),
            ["folder:Sources", "folder:Sources/Views", "folder:Tests"]
        )
    }

    func testSiblingFoldersShareTheParentAndIncludeTheFolderItself() {
        let items = [
            item("Sources/App/Main.swift"),
            item("Sources/Kit/Client.swift"),
            item("Sources/Kit/Models/PR.swift"),
            item("Sources/README.md"),
            item("Tests/AppTests.swift"),
        ]

        XCTAssertEqual(FileSidebarTreeNode.siblingFolderIDs(of: "Sources/Kit", in: items),
                       ["folder:Sources/App", "folder:Sources/Kit"])
        XCTAssertEqual(FileSidebarTreeNode.siblingFolderIDs(of: "Tests", in: items),
                       ["folder:Sources", "folder:Tests"])
        XCTAssertEqual(FileSidebarTreeNode.siblingFolderIDs(of: "Sources/Kit/Models", in: items),
                       ["folder:Sources/Kit/Models"])
    }

    func testFilteredItemsProduceOnlyTheirContainingFoldersAndCounts() throws {
        let tree = FileSidebarTreeNode.build(from: [
            item("Sources/Views/FileSidebarView.swift"),
            item("Sources/Views/ReviewWindowView.swift")
        ])

        let sources = try XCTUnwrap(tree.first)
        let views = try XCTUnwrap(sources.children.first)
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(sources.fileCount, 2)
        XCTAssertEqual(views.name, "Views")
        XCTAssertEqual(views.fileCount, 2)
        XCTAssertEqual(views.children.map(\.name), ["FileSidebarView.swift", "ReviewWindowView.swift"])
    }

    func testVisibleRowsSkipWhatIsInsideCollapsedFolders() {
        let tree = FileSidebarTreeNode.build(from: [
            item("README.md"),
            item("Sources/App.swift"),
            item("Sources/Views/ChangeCanvasView.swift"),
            item("Tests/AppTests.swift")
        ])

        let expanded = FileSidebarTreeNode.visibleRows(of: tree, collapsed: [])
        let collapsed = FileSidebarTreeNode.visibleRows(of: tree, collapsed: ["folder:Sources/Views", "folder:Tests"])

        XCTAssertEqual(expanded.map(\.id), [
            "folder:Sources", "folder:Sources/Views", "file:Sources/Views/ChangeCanvasView.swift",
            "file:Sources/App.swift", "folder:Tests", "file:Tests/AppTests.swift", "file:README.md"
        ])
        XCTAssertEqual(expanded.map(\.depth), [0, 1, 2, 1, 0, 1, 0])
        XCTAssertEqual(collapsed.map(\.id), [
            "folder:Sources", "folder:Sources/Views", "file:Sources/App.swift", "folder:Tests", "file:README.md"
        ])
    }

    private func item(_ path: String) -> FileSidebarItem {
        FileSidebarItem(
            path: path,
            oldPath: nil,
            statusLetter: "M",
            additions: 1,
            deletions: 1,
            isBinary: false,
            tooLarge: false,
            threadCount: 0,
            isViewed: false
        )
    }
}
