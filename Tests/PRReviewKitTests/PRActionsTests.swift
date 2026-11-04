import XCTest
@testable import PRReviewKit

final class PRActionsTests: XCTestCase {

    private let ep = PREndpoint(owner: "acme", repo: "api", number: 7)

    private func state(
        _ prState: String = "OPEN", draft: Bool = false, mergeable: String = "MERGEABLE",
        permission: String = "WRITE", canUpdate: Bool = true, author: Bool = false,
        methods: [MergeMethod] = [.squash]
    ) -> PRActionState {
        PRActionState(
            state: prState, isDraft: draft, mergeable: mergeable, viewerPermission: permission,
            viewerCanUpdate: canUpdate, viewerDidAuthor: author, allowedMergeMethods: methods
        )
    }

    func testMergeNeedsPushAccessAnOpenReadyPullRequestAndNoConflict() {
        XCTAssertEqual(state().mergeMethods, [.squash])
        XCTAssertEqual(state(permission: "ADMIN", methods: [.squash, .rebase]).mergeMethods, [.squash, .rebase])
        XCTAssertEqual(state(permission: "READ").mergeMethods, [])
        XCTAssertEqual(state(permission: "TRIAGE").mergeMethods, [])
        XCTAssertEqual(state(draft: true).mergeMethods, [])
        XCTAssertEqual(state(mergeable: "CONFLICTING").mergeMethods, [])
        XCTAssertEqual(state(mergeable: "UNKNOWN").mergeMethods, [.squash], "GitHub may still be computing")
        XCTAssertEqual(state("MERGED").mergeMethods, [])
    }

    func testAuthorsCannotApproveTheirOwnPullRequest() {
        XCTAssertTrue(state().canApprove)
        XCTAssertFalse(state(author: true).canApprove)
        XCTAssertFalse(state("CLOSED").canApprove)
    }

    /// Read access still lets an author close or ready their own PR.
    func testUpdatesFollowViewerCanUpdate() {
        let author = state(permission: "READ", canUpdate: true, author: true)
        XCTAssertTrue(author.canClose)
        XCTAssertTrue(author.canConvertToDraft)
        XCTAssertFalse(author.canMarkReady)
        XCTAssertTrue(state(draft: true).canMarkReady)
        XCTAssertTrue(state("CLOSED").canReopen)
        XCTAssertFalse(state(canUpdate: false).canClose)
        XCTAssertFalse(state(permission: "READ", canUpdate: false, author: true).hasAnyAction)
    }

    func testActionsMapToGhArgumentArrays() {
        XCTAssertEqual(PRAction.merge(.squash).arguments(for: ep), ["pr", "merge", "7", "--repo", "acme/api", "--squash"])
        XCTAssertEqual(PRAction.merge(.rebase).arguments(for: ep), ["pr", "merge", "7", "--repo", "acme/api", "--rebase"])
        XCTAssertEqual(PRAction.approve.arguments(for: ep), ["pr", "review", "7", "--repo", "acme/api", "--approve"])
        XCTAssertEqual(PRAction.markReady.arguments(for: ep), ["pr", "ready", "7", "--repo", "acme/api"])
        XCTAssertEqual(PRAction.convertToDraft.arguments(for: ep), ["pr", "ready", "7", "--repo", "acme/api", "--undo"])
        XCTAssertEqual(PRAction.close.arguments(for: ep), ["pr", "close", "7", "--repo", "acme/api"])
        XCTAssertEqual(PRAction.reopen.arguments(for: ep), ["pr", "reopen", "7", "--repo", "acme/api"])
    }
}
