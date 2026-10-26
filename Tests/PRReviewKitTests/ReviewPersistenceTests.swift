import XCTest
@testable import PRReviewKit

final class ReviewPersistenceTests: XCTestCase {

    private let ep = PREndpoint(owner: "octocat", repo: "demo-repo", number: 42)

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prr-persist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The legacy filename contract: `drafts-owner_repo_number_sha.json` and
    /// `viewed-owner_repo_number_sha.json`, with `/` replaced by `_`.
    func testLegacyFilenamesAndKeyNormalization() {
        let persistence = ReviewPersistence(directory: URL(fileURLWithPath: "/tmp/unused"))
        XCTAssertEqual(
            persistence.draftsFileName(ep, sha: "abc123"),
            "drafts-octocat_demo-repo_42_abc123.json"
        )
        XCTAssertEqual(
            persistence.viewedFileName(ep, sha: "abc123"),
            "viewed-octocat_demo-repo_42_abc123.json"
        )
        XCTAssertEqual(
            persistence.hiddenReviewersFileName(ep),
            "hidden-reviewers-octocat_demo-repo_42.json",
            "hidden reviewers are keyed per PR, with no SHA"
        )
        XCTAssertEqual(
            persistence.key(PREndpoint(owner: "o", repo: "r/n", number: 1), sha: "s"),
            "o_r_n_1_s"
        )
    }

    /// Drafts round-trip with the legacy field names and numeric dates, and
    /// `isOrphaned` is never emitted to disk.
    func testDraftRoundTripAndIsOrphanedNotPersisted() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = ReviewPersistence(directory: dir)

        let drafts = [
            DraftComment(path: "a.swift", line: 5, side: "RIGHT", body: "one", isOrphaned: true),
            DraftComment(path: "b.swift", line: 10, side: "LEFT", body: "two",
                         startLine: 8, startSide: "LEFT"),
        ]
        try await persistence.saveDrafts(drafts, for: ep, headSHA: "shash")

        let url = dir.appendingPathComponent(persistence.draftsFileName(ep, sha: "shash"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Orphan state is derived, never serialized.
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("isOrphaned"), "orphan flag must not be persisted: \(raw)")

        let loaded = try await persistence.loadDrafts(for: ep, headSHA: "shash")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, drafts[0].id)
        XCTAssertEqual(loaded[0].isOrphaned, false, "orphan flag is not persisted")
        XCTAssertEqual(loaded[1].id, drafts[1].id)
        XCTAssertEqual(loaded[1].startLine, 8)
        XCTAssertEqual(loaded[1].startSide, "LEFT")
    }

    /// A legacy file omitting the optional range fields decodes with nil
    /// values and the numeric date representation stays compatible.
    func testLegacyDraftFileWithoutRangeFieldsDecodes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = ReviewPersistence(directory: dir)

        let legacyID = UUID().uuidString
        let legacyJSON = """
        [{"id":"\(legacyID)","path":"c.swift","line":3,"side":"RIGHT","body":"legacy","createdAt":\(Date().timeIntervalSinceReferenceDate)}]
        """
        try legacyJSON.write(
            to: dir.appendingPathComponent(persistence.draftsFileName(ep, sha: "s")),
            atomically: true, encoding: .utf8
        )

        let state = try await persistence.loadDraftState(for: ep, headSHA: "s")
        guard case .present(let drafts) = state else {
            return XCTFail("expected present state")
        }
        XCTAssertEqual(drafts.count, 1)
        XCTAssertNil(drafts[0].startLine)
        XCTAssertNil(drafts[0].startSide)
    }

    /// Missing draft file vs an intentionally saved empty array are distinct.
    func testMissingVersusEmptyDraftState() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = ReviewPersistence(directory: dir)

        let missing = try await persistence.loadDraftState(for: ep, headSHA: "absent")
        guard case .missing = missing else {
            return XCTFail("expected missing for an absent file")
        }

        try await persistence.saveDrafts([], for: ep, headSHA: "empty")
        let present = try await persistence.loadDraftState(for: ep, headSHA: "empty")
        guard case .present(let drafts) = present else {
            return XCTFail("expected present for a saved empty array")
        }
        XCTAssertTrue(drafts.isEmpty)
    }

    /// Malformed JSON throws instead of silently returning empty state.
    func testMalformedDraftFileThrows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = ReviewPersistence(directory: dir)

        try "not json".write(
            to: dir.appendingPathComponent(persistence.draftsFileName(ep, sha: "bad")),
            atomically: true, encoding: .utf8
        )

        do {
            _ = try await persistence.loadDraftState(for: ep, headSHA: "bad")
            XCTFail("expected a load failure")
        } catch {
            // expected
        }
    }

    /// Viewed marks round-trip as a JSON string array.
    func testViewedRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = ReviewPersistence(directory: dir)

        try await persistence.saveViewed(["b.swift", "a.swift"], for: ep, headSHA: "v")
        let url = dir.appendingPathComponent(persistence.viewedFileName(ep, sha: "v"))
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.hasPrefix("["), "viewed marks must be a JSON array, got \(raw)")

        let loaded = try await persistence.loadViewed(for: ep, headSHA: "v")
        XCTAssertEqual(loaded, ["a.swift", "b.swift"])
    }

    /// Drafts hold private comment bodies and file paths, so only the user may
    /// read them: new files, overwritten files and a created directory alike.
    func testFilesAreOwnerOnly() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("store")
        let persistence = ReviewPersistence(directory: dir)
        let fm = FileManager.default
        func mode(_ url: URL) throws -> Int {
            try (fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }

        try await persistence.saveViewed(["a.swift"], for: ep, headSHA: "v")
        let viewed = dir.appendingPathComponent(persistence.viewedFileName(ep, sha: "v"))
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: viewed.path)
        try await persistence.saveViewed(["b.swift"], for: ep, headSHA: "v")
        try await persistence.saveHiddenReviewers(["u"], for: ep)

        XCTAssertEqual(try mode(dir), 0o700)
        XCTAssertEqual(try mode(viewed), 0o600)
        for name in try fm.contentsOfDirectory(atPath: dir.path) {
            XCTAssertEqual(try mode(dir.appendingPathComponent(name)), 0o600, name)
        }
    }

    /// Hidden reviewers round-trip as a JSON string array, keyed per PR: the
    /// same file serves every head of the pull request (no SHA in the name).
    func testHiddenReviewersRoundTripIsPRScoped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = ReviewPersistence(directory: dir)

        try await persistence.saveHiddenReviewers(["bob", "jane"], for: ep)
        let url = dir.appendingPathComponent(persistence.hiddenReviewersFileName(ep))
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.hasPrefix("["), "hidden reviewers must be a JSON array, got \(raw)")

        let loaded = try await persistence.loadHiddenReviewers(for: ep)
        XCTAssertEqual(loaded, ["bob", "jane"])
    }

    /// A missing hidden-reviewers file reads as an empty set.
    func testHiddenReviewersMissingFileReadsEmpty() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = ReviewPersistence(directory: dir)
        let loaded = try await persistence.loadHiddenReviewers(for: ep)
        XCTAssertTrue(loaded.isEmpty)
    }

    /// An injected commit failure leaves the previous valid document intact,
    /// reports the error, and leaves no temporary artifact behind.
    func testAtomicReplaceFailurePreservesTargetAndCleansTemp() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let commitError = PersistenceError.saveFailed("injected commit failure")
        let persistence = ReviewPersistence(directory: dir) { _, _ in
            throw commitError
        }

        // Seed a valid document via a separate successful instance.
        let good = ReviewPersistence(directory: dir)
        try await good.saveDrafts([DraftComment(path: "x", line: 1, side: "RIGHT", body: "kept")], for: ep, headSHA: "s")

        do {
            try await persistence.saveDrafts([], for: ep, headSHA: "s")
            XCTFail("expected the injected commit failure")
        } catch {
            // expected
        }

        // The previous document is untouched and decodable.
        let state = try await good.loadDraftState(for: ep, headSHA: "s")
        guard case .present(let drafts) = state, drafts.count == 1 else {
            return XCTFail("previous document must be preserved")
        }
        XCTAssertEqual(drafts[0].body, "kept")

        // No temp artifacts remain.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "temporary files must be cleaned up: \(leftovers)")
    }

    /// Concurrent saves through one repository instance never corrupt the
    /// final document (the actor serializes them).
    func testConcurrentSavesProduceCompleteDocument() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = ReviewPersistence(directory: dir)

        async let a: Void = persistence.saveDrafts(
            [DraftComment(path: "a", line: 1, side: "RIGHT", body: "A")], for: ep, headSHA: "s"
        )
        async let b: Void = persistence.saveDrafts(
            [DraftComment(path: "b", line: 2, side: "RIGHT", body: "B"),
             DraftComment(path: "c", line: 3, side: "RIGHT", body: "C")], for: ep, headSHA: "s"
        )
        _ = try await (a, b)

        // Whatever won the race, the file must decode as a complete array.
        let state = try await persistence.loadDraftState(for: ep, headSHA: "s")
        guard case .present(let drafts) = state else {
            return XCTFail("expected a complete saved document")
        }
        XCTAssertTrue(drafts.count == 1 || drafts.count == 2)
    }
}
