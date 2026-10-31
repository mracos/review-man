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

/// Answers the thread page once, then each per-thread comment page after a
/// short delay, recording how many comment fetches were in flight at once.
private final class ConcurrencyTrackingRunner: CommandRunning, @unchecked Sendable {
    let threadsPage: Data
    let commentsPage: Data
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxInFlight = 0

    init(threadsPage: Data, commentsPage: Data) {
        self.threadsPage = threadsPage
        self.commentsPage = commentsPage
    }

    func run(_ args: [String], timeout: TimeInterval) async throws -> GH.Result {
        guard args.contains(where: { $0.hasPrefix("threadID=") }) else {
            return GH.Result(data: threadsPage, stderr: "")
        }
        lock.withLock {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        lock.withLock { inFlight -= 1 }
        return GH.Result(data: commentsPage, stderr: "")
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
        node: [String: Any]? = nil,
        nodes: [[String: Any]] = []
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
                            "nodes": node.map { [$0] } ?? nodes,
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

    /// A page of long threads used to spawn one `gh` per thread at once.
    func testThreadCommentFetchesAreBoundedAndKeepOrder() async throws {
        let ids = (1...12).map { "t\($0)" }
        let runner = ConcurrencyTrackingRunner(
            threadsPage: graphQLData(threadsPage(
                hasNext: false,
                endCursor: nil,
                nodes: ids.map { threadNode(id: $0, commentsHasNext: true, commentsCursor: "c-\($0)") }
            )),
            commentsPage: graphQLData(commentsPage(nodes: [], hasNext: false, endCursor: nil))
        )

        let threads = try await GitHubClient(commandRunner: runner).fetchThreads(ep)

        XCTAssertEqual(threads.map(\.id), ids)
        XCTAssertLessThanOrEqual(runner.maxInFlight, GitHubClient.maxConcurrentThreadCommentFetches)
        XCTAssertGreaterThan(runner.maxInFlight, 1)
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

    func testFetchPRInfoSummarizesChecksFromTheSameCall() async throws {
        let runner = ScriptedCommandRunner()
        let rollup: [[String: Any]] = [
            ["__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"],
            ["__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SKIPPED"],
            ["__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE"],
            ["__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""],
            ["__typename": "StatusContext", "state": "SUCCESS"],
            ["__typename": "StatusContext", "state": "PENDING"],
            ["__typename": "StatusContext", "state": "ERROR"],
        ]
        let pr: [String: Any] = [
            "number": 3, "title": "t", "body": "why", "state": "OPEN", "isDraft": false,
            "headRefOid": "abc", "headRefName": "h", "baseRefName": "main",
            "additions": 1, "deletions": 0, "changedFiles": 1, "reviewDecision": "APPROVED",
            "url": "https://github.com/o/r/pull/3", "author": ["login": "u"],
            "statusCheckRollup": rollup,
        ]
        runner.results = [GH.Result(data: graphQLData(pr), stderr: "")]

        let info = try await GitHubClient(commandRunner: runner).fetchPRInfo(ep)

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertTrue(runner.calls[0].joined(separator: " ").contains("statusCheckRollup"))
        XCTAssertEqual(info.checks, PRChecksSummary(passed: 3, failed: 2, pending: 2))
    }

    func testFetchPRInfoWithoutChecksHasNoSummary() async throws {
        let runner = ScriptedCommandRunner()
        let pr: [String: Any] = [
            "number": 3, "title": "t", "state": "OPEN", "isDraft": false,
            "headRefOid": "abc", "headRefName": "h", "baseRefName": "main",
            "additions": 1, "deletions": 0, "changedFiles": 1,
            "url": "https://github.com/o/r/pull/3", "author": ["login": "u"],
            "statusCheckRollup": [[String: Any]](),
        ]
        runner.results = [GH.Result(data: graphQLData(pr), stderr: "")]

        let info = try await GitHubClient(commandRunner: runner).fetchPRInfo(ep)

        XCTAssertNil(info.checks)
    }

    func testFetchViewedFilesKeepsOnlyViewedAcrossPages() async throws {
        func page(_ nodes: [(String, String)], next: String?) -> Data {
            graphQLData([
                "data": ["repository": ["pullRequest": ["files": [
                    "nodes": nodes.map { ["path": $0.0, "viewerViewedState": $0.1] },
                    "pageInfo": ["hasNextPage": next != nil, "endCursor": next as Any],
                ]]]],
            ])
        }
        let runner = ScriptedCommandRunner()
        runner.results = [
            GH.Result(data: page([("a.swift", "VIEWED"), ("b.swift", "DISMISSED")], next: "cursor-1"), stderr: ""),
            GH.Result(data: page([("c.swift", "VIEWED"), ("d.swift", "UNVIEWED")], next: nil), stderr: ""),
        ]

        let viewed = try await GitHubClient(commandRunner: runner).fetchViewedFiles(ep)

        XCTAssertEqual(viewed, ["a.swift", "c.swift"])
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertTrue(runner.calls[0].contains("cursor=null"))
        XCTAssertTrue(runner.calls[1].contains("cursor=cursor-1"))
        XCTAssertTrue(runner.calls[0].contains("owner=o"))
    }

    func testSetFileViewedUsesTheMatchingMutationWithVariables() async throws {
        let runner = ScriptedCommandRunner()
        runner.results = [
            GH.Result(data: Data(#"{"data":{}}"#.utf8), stderr: ""),
            GH.Result(data: Data(#"{"data":{}}"#.utf8), stderr: ""),
        ]
        let client = GitHubClient(commandRunner: runner)

        try await client.setFileViewed(pullRequestID: "PR_1", path: "a.swift", viewed: true)
        try await client.setFileViewed(pullRequestID: "PR_1", path: "a.swift", viewed: false)

        let mark = runner.calls[0].first(where: { $0.hasPrefix("query=") }) ?? ""
        let unmark = runner.calls[1].first(where: { $0.hasPrefix("query=") }) ?? ""
        XCTAssertTrue(mark.contains("markFileAsViewed") && !mark.contains("unmarkFileAsViewed"))
        XCTAssertTrue(unmark.contains("unmarkFileAsViewed"))
        for call in runner.calls {
            XCTAssertTrue(call.contains("pullRequestId=PR_1"))
            XCTAssertTrue(call.contains("path=a.swift"))
            XCTAssertFalse((call.first(where: { $0.hasPrefix("query=") }) ?? "").contains("a.swift"))
        }
    }

    func testFetchFileLinesReadsTheRawFileAtACommit() async throws {
        let runner = ScriptedCommandRunner()
        runner.results = [GH.Result(data: Data("one\ntwo\n\nfour\n".utf8), stderr: "")]

        let lines = try await GitHubClient(commandRunner: runner)
            .fetchFileLines(ep, path: "src/a b/c#d.swift", ref: "0123abcd")

        XCTAssertEqual(lines, ["one", "two", "", "four"])
        XCTAssertEqual(runner.calls[0], [
            "api", "-H", "Accept: application/vnd.github.raw",
            "repos/o/r/contents/src/a%20b/c%23d.swift?ref=0123abcd",
        ])
    }

    func testFetchFileLinesRefusesPathsAndRefsThatCouldSteerTheRequest() async {
        let runner = ScriptedCommandRunner()
        let client = GitHubClient(commandRunner: runner)

        for (path, ref) in [("../secrets", "0123abcd"), ("a/./b", "0123abcd"), ("ok.swift", "main?x=1"), ("", "0123abcd")] {
            do {
                _ = try await client.fetchFileLines(ep, path: path, ref: ref)
                XCTFail("expected refusal for \(path) @ \(ref)")
            } catch let error as GitHubError {
                guard case .parse = error else { return XCTFail("expected parse, got \(error)") }
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testResolveEndpointAcceptsURLsAndShorthand() async throws {
        let client = GitHubClient(commandRunner: ScriptedCommandRunner())
        let expected = PREndpoint(owner: "o", repo: "r", number: 7)

        for arg in ["https://github.com/o/r/pull/7", "https://www.github.com/o/r/pull/7/files", "o/r#7", " o/r#7 "] {
            let resolved = try await client.resolveEndpoint(from: arg)
            XCTAssertEqual(resolved, expected, arg)
        }
    }

    /// Owner and repo reach `gh` as `-F owner=...` and REST path segments, so
    /// an `@file` or `..` must be refused before any command runs.
    func testResolveEndpointRejectsNamesGhWouldInterpret() async {
        let runner = ScriptedCommandRunner()
        let client = GitHubClient(commandRunner: runner)

        for arg in ["@etc/r#1", "o/..#1", "https://github.com/%40o/r/pull/1", "https://github.com/o/r"] {
            do {
                _ = try await client.resolveEndpoint(from: arg)
                XCTFail("expected parse error for \(arg)")
            } catch let error as GitHubError {
                guard case .parse = error else { return XCTFail("expected parse, got \(error)") }
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testResolveEndpointRejectsInvalidCurrentRepositoryName() async {
        let runner = ScriptedCommandRunner()
        runner.results = [GH.Result(data: Data("@etc/r\n".utf8), stderr: "")]
        let client = GitHubClient(commandRunner: runner)

        do {
            _ = try await client.resolveEndpoint(from: "5")
            XCTFail("expected parse error")
        } catch let error as GitHubError {
            guard case .parse = error else { return XCTFail("expected parse, got \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
