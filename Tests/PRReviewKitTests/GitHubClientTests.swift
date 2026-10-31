import XCTest
@testable import PRReviewKit

/// A scripted asynchronous command runner: plays back queued results/errors
/// and records every invocation for assertions.
private final class ScriptedCommandRunner: CommandRunning {
    var results: [GH.Result] = []
    var errors: [Error] = []
    var calls: [[String]] = []

    func run(_ args: [String], timeout: TimeInterval) async throws -> GH.Result {
        calls.append(args)
        if !errors.isEmpty {
            throw errors.removeFirst()
        }
        if results.isEmpty {
            return GH.Result(data: Data(), stderr: "")
        }
        return results.removeFirst()
    }
}

final class GitHubClientTests: XCTestCase {

    private let ep = PREndpoint(owner: "o", repo: "r", number: 3)

    private func filesPayload() -> String {
        """
        [
          {
            "filename": "a.txt", "status": "modified",
            "additions": 1, "deletions": 1, "changes": 2,
            "patch": "@@ -1 +1 @@\\n-x\\n+x\\n"
          },
          {
            "filename": "b.txt", "status": "renamed", "previous_filename": "a-old.txt",
            "additions": 0, "deletions": 0, "changes": 0,
            "patch": "@@ -1,1 +1,1 @@\\n-rename me\\n+renamed\\n"
          }
        ]
        """
    }

    /// When the raw diff endpoint fails, the client must fall back to the
    /// per-file endpoint and parse the patches there.
    func testFetchDiffFallsBackWhenRawDiffCommandFails() async throws {
        let runner = ScriptedCommandRunner()
        runner.errors = [GitHubError.commandFailed(command: "gh api ...", stderr: "406")]
        runner.results = [GH.Result(data: Data(filesPayload().utf8), stderr: "")]

        let client = GitHubClient(commandRunner: runner)
        let files = try await client.fetchDiff(ep)

        // First call: raw diff; second call: per-file fallback.
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertTrue(runner.calls[0].joined(separator: " ").contains("pulls/3"))
        XCTAssertFalse(runner.calls[0].joined(separator: " ").contains("pulls/3/files"))
        XCTAssertTrue(runner.calls[1].joined(separator: " ").contains("pulls/3/files"))

        XCTAssertEqual(files.count, 2)
        // Modified file parsed from its patch.
        XCTAssertEqual(files[0].status, .modified)
        XCTAssertEqual(files[0].newPath, "a.txt")
        XCTAssertEqual(files[0].hunks.count, 1)
        // Renamed file keeps its old path and parses its patch.
        XCTAssertEqual(files[1].status, .renamed)
        XCTAssertEqual(files[1].oldPath, "a-old.txt")
        XCTAssertEqual(files[1].newPath, "b.txt")
        XCTAssertEqual(files[1].hunks.count, 1)
    }

    /// A non-empty raw diff that fails to parse must also trigger the
    /// fallback; files without patches are marked too-large.
    func testFetchDiffFallsBackWhenRawDiffIsNonemptyButUnparseable() async throws {
        let runner = ScriptedCommandRunner()
        runner.results = [
            GH.Result(data: Data("not a diff at all".utf8), stderr: ""),
            GH.Result(data: Data("""
            [{"filename":"big.bin","status":"added","additions":9999,"deletions":0,"changes":9999}]
            """.utf8), stderr: ""),
        ]

        let client = GitHubClient(commandRunner: runner)
        let files = try await client.fetchDiff(ep)

        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .added)
        XCTAssertEqual(files[0].newPath, "big.bin")
        XCTAssertEqual(files[0].tooLarge, true)
        XCTAssertEqual(files[0].hunks.count, 0)
    }

    /// An empty raw diff is a valid "no changes" answer and must not trigger
    /// the fallback.
    func testFetchDiffUsesRawEmptyDiffWithoutFallback() async throws {
        let runner = ScriptedCommandRunner()
        runner.results = [GH.Result(data: Data(), stderr: "")]

        let client = GitHubClient(commandRunner: runner)
        let files = try await client.fetchDiff(ep)

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertTrue(files.isEmpty)
    }

    // MARK: - GraphQL variables (no interpolation of IDs or cursors)

    private func threadsPage(
        hasNext: Bool,
        endCursor: String?,
        node: [String: Any]? = nil
    ) -> [String: Any] {
        [
            "data": [
                "repository": [
                    "pullRequest": [
                        "reviewThreads": [
                            "pageInfo": [
                                "hasNextPage": hasNext,
                                "endCursor": endCursor as Any,
                            ],
                            "nodes": node.map { [$0] } ?? [],
                        ],
                    ],
                ],
            ],
        ]
    }

    private func commentsPage(nodes: [[String: Any]], hasNext: Bool, endCursor: String?) -> [String: Any] {
        [
            "data": [
                "node": [
                    "comments": [
                        "nodes": nodes,
                        "pageInfo": ["hasNextPage": hasNext, "endCursor": endCursor as Any],
                    ],
                ],
            ],
        ]
    }

    private func threadNode(id: String, commentsHasNext: Bool, commentsCursor: String?) -> [String: Any] {
        [
            "id": id,
            "isResolved": false,
            "isOutdated": false,
            "path": "a.swift",
            "line": 5,
            "originalLine": 5,
            "diffSide": "RIGHT",
            "startLine": NSNull(),
            "originalStartLine": NSNull(),
            "comments": [
                "nodes": [
                    [
                        "id": "c1",
                        "databaseId": 1,
                        "body": "hi",
                        "author": ["login": "u"],
                        "createdAt": "2026-01-01T00:00:00Z",
                    ],
                ],
                "pageInfo": ["hasNextPage": commentsHasNext, "endCursor": commentsCursor as Any],
            ],
        ]
    }

    private func graphQLData(_ obj: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: obj)
    }

    /// The thread and cursor values must travel as `-F` GraphQL variables, not
    /// interpolated into query strings, and the first thread page passes an
    /// explicit null cursor.
    func testGraphQLThreadQueriesUseVariablesNotInterpolation() async throws {
        let runner = ScriptedCommandRunner()
        runner.results = [
            GH.Result(data: graphQLData(threadsPage(
                hasNext: false,
                endCursor: nil,
                node: threadNode(id: "thread-1", commentsHasNext: true, commentsCursor: "comment-cursor-1")
            )), stderr: ""),
            GH.Result(data: graphQLData(commentsPage(
                nodes: [
                    [
                        "id": "c2",
                        "databaseId": 2,
                        "body": "reply",
                        "author": ["login": "u"],
                        "createdAt": "2026-01-01T00:00:00Z",
                    ],
                ],
                hasNext: false,
                endCursor: nil
            )), stderr: ""),
        ]

        let client = GitHubClient(commandRunner: runner)
        let threads = try await client.fetchThreads(ep)

        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].comments.count, 2)
        XCTAssertEqual(runner.calls.count, 2)

        // First page: explicit null cursor.
        let firstArgs = runner.calls[0].joined(separator: " ")
        XCTAssertTrue(firstArgs.contains("cursor=null"))

        // Second call: thread ID and cursor as -F variables.
        let secondArgs = runner.calls[1].joined(separator: " ")
        XCTAssertTrue(secondArgs.contains("threadID=thread-1"))
        XCTAssertTrue(secondArgs.contains("cursor=comment-cursor-1"))

        // Neither query string contains the actual ID or cursor values.
        for args in runner.calls {
            let query = args.first(where: { $0.hasPrefix("query=") }) ?? ""
            XCTAssertTrue(query.contains("$cursor"))
            XCTAssertFalse(query.contains("thread-1"), "ID must not be interpolated into the query")
            XCTAssertFalse(query.contains("comment-cursor-1"), "cursor must not be interpolated into the query")
        }
        XCTAssertTrue(runner.calls[1].first(where: { $0.hasPrefix("query=") })?.contains("$threadID") ?? false)
    }

    /// A second thread page passes the returned cursor as a variable.
    func testGraphQLThreadPaginationPassesCursorVariable() async throws {
        let runner = ScriptedCommandRunner()
        runner.results = [
            GH.Result(data: graphQLData(threadsPage(
                hasNext: true,
                endCursor: "cursor-A",
                node: threadNode(id: "t1", commentsHasNext: false, commentsCursor: nil)
            )), stderr: ""),
            GH.Result(data: graphQLData(threadsPage(hasNext: false, endCursor: nil)), stderr: ""),
        ]

        let client = GitHubClient(commandRunner: runner)
        let threads = try await client.fetchThreads(ep)

        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(runner.calls.count, 2)
        let second = runner.calls[1].joined(separator: " ")
        XCTAssertTrue(second.contains("cursor=cursor-A"))
        XCTAssertFalse(runner.calls[1].first(where: { $0.hasPrefix("query=") })?.contains("cursor-A") ?? false)
    }

    /// A failed submit must still remove its private payload file.
    func testSubmitReviewRemovesPayloadFileOnCommandFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prr-payload-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = ScriptedCommandRunner()
        runner.errors = [GitHubError.commandFailed(command: "gh api", stderr: "422 head moved")]
        let client = GitHubClient(commandRunner: runner, payloadDirectory: dir)

        do {
            try await client.submitReview(
                ep, commitID: "abc", body: "", event: "COMMENT", drafts: []
            )
            XCTFail("expected the submit to fail")
        } catch {
            // expected
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "payload file must be removed after a failed submit")
    }

    /// Cancellation during the raw diff fetch must propagate and must NOT
    /// trigger the per-file fallback.
    func testFetchDiffPropagatesCancellationWithoutFallback() async throws {
        let runner = ScriptedCommandRunner()
        runner.errors = [CancellationError()]
        let client = GitHubClient(commandRunner: runner)

        do {
            _ = try await client.fetchDiff(ep)
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(runner.calls.count, 1, "fallback must not run after cancellation")
    }

    /// A broken `gh --version` maps to the actionable ghUnavailable message.
    func testEnsureAvailableMapsFailuresToActionableError() async throws {
        let runner = ScriptedCommandRunner()
        runner.errors = [GitHubError.commandFailed(command: "gh cli", stderr: "boom")]
        let client = GitHubClient(commandRunner: runner)

        do {
            try await client.ensureAvailable()
            XCTFail("expected ghUnavailable")
        } catch let error as GitHubError {
            guard case .ghUnavailable(let message) = error else {
                return XCTFail("expected ghUnavailable, got \(error)")
            }
            XCTAssertTrue(message.contains("brew install gh"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Cancellation of the availability probe propagates untouched.
    func testEnsureAvailablePropagatesCancellation() async throws {
        let runner = ScriptedCommandRunner()
        runner.errors = [CancellationError()]
        let client = GitHubClient(commandRunner: runner)

        do {
            try await client.ensureAvailable()
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }


    func testSearchPullRequestsDecodesRowsAndSkipsNonPullRequests() async throws {
        let runner = ScriptedCommandRunner()
        let pr: [String: Any] = [
            "id": "PR_1", "number": 7, "title": "Add inbox", "url": "https://github.com/acme/api/pull/7",
            "isDraft": true, "state": "OPEN", "reviewDecision": "REVIEW_REQUIRED",
            "updatedAt": "2026-10-30T12:00:00Z", "additions": 10, "deletions": 2,
            "author": ["login": "u"], "repository": ["nameWithOwner": "acme/api"],
            "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "FAILURE"]]]]],
            "labels": ["nodes": [["name": "agentic-workflows", "color": "7057ff"]]],
        ]
        let noChecks: [String: Any] = [
            "id": "PR_2", "number": 8, "title": "Docs", "url": "https://github.com/acme/web/pull/8",
            "isDraft": false, "state": "MERGED", "reviewDecision": NSNull(),
            "updatedAt": "2026-10-29T12:00:00Z", "additions": 1, "deletions": 1,
            "author": NSNull(), "repository": ["nameWithOwner": "acme/web"],
            "commits": ["nodes": [["commit": ["statusCheckRollup": NSNull()]]]],
        ]
        runner.results = [GH.Result(
            data: graphQLData(["data": ["search": ["nodes": [pr, [String: Any](), noChecks]]]]),
            stderr: ""
        )]

        let rows = try await GitHubClient(commandRunner: runner).searchPullRequests(query: "is:pr author:@me", first: 25)

        XCTAssertEqual(rows.map(\.number), [7, 8])
        XCTAssertEqual(rows[0].repository, "acme/api")
        XCTAssertEqual(rows[0].checksState, "FAILURE")
        XCTAssertEqual(rows[0].labels, [PRLabel(name: "agentic-workflows", color: "7057ff")])
        XCTAssertEqual(rows[1].labels, [])
        XCTAssertTrue(rows[0].isDraft)
        XCTAssertEqual(rows[1].author, "ghost")
        XCTAssertNil(rows[1].checksState)
        let args = runner.calls[0]
        XCTAssertTrue(args.contains("q=is:pr author:@me"))
        XCTAssertTrue(args.contains("first=25"))
        XCTAssertFalse((args.first(where: { $0.hasPrefix("query=") }) ?? "").contains("author:@me"))
    }

    func testFetchViewerScopeReadsLoginAndOrganizations() async throws {
        let runner = ScriptedCommandRunner()
        runner.results = [GH.Result(data: graphQLData([
            "data": ["viewer": ["login": "octocat", "organizations": ["nodes": [["login": "acme"], ["login": "tools"]]]]],
        ]), stderr: "")]

        let scope = try await GitHubClient(commandRunner: runner).fetchViewerScope()

        XCTAssertEqual(scope, InboxScope(login: "octocat", organizations: ["acme", "tools"]))
    }
}
