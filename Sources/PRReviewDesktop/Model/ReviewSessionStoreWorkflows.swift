import Foundation
import AppKit
import PRReviewKit

// MARK: - Workflow state types

/// Inline draft editor state.
public struct DraftEditorState: Equatable {
    public let draftID: UUID?
    public let path: String
    public let side: String
    public let line: Int
    public let startLine: Int?
    public let startSide: String?
    public var text: String

    public init(
        draftID: UUID?, path: String, side: String, line: Int,
        startLine: Int? = nil, startSide: String? = nil, text: String = ""
    ) {
        self.draftID = draftID
        self.path = path
        self.side = side
        self.line = line
        self.startLine = startLine
        self.startSide = startSide
        self.text = text
    }
}

/// Reply editor state, retained for retry after a failure.
public struct ReplyEditorState: Equatable {
    public let threadID: String
    public let commentID: Int
    public var body: String
    public var retryFailed = false

    public init(threadID: String, commentID: Int, body: String = "", retryFailed: Bool = false) {
        self.threadID = threadID
        self.commentID = commentID
        self.body = body
        self.retryFailed = retryFailed
    }
}

/// Submit sheet state.
public enum SubmitPresentationState: Equatable {
    case hidden
    case editing
    case submitting
    case failed(message: String)
    /// The remote result is unknown (timeout/cancellation after dispatch);
    /// drafts are retained and resubmission must be deliberate.
    case uncertain(message: String)
}

/// A commentable line anchor for starting a draft.
public struct DraftStartAnchor: Equatable {
    public let path: String
    public let side: String
    public let line: Int
    public let startLine: Int?
    public let startSide: String?

    public init(path: String, side: String, line: Int, startLine: Int? = nil, startSide: String? = nil) {
        self.path = path
        self.side = side
        self.line = line
        self.startLine = startLine
        self.startSide = startSide
    }
}

// MARK: - Workflow store extension

extension ReviewSessionStore {

    /// Mutable session data backing the immutable published presentation.
    private struct SessionData {
        var endpoint: PREndpoint?
        var isDemo = false
        var pr: PRInfo?
        var files: [DiffFile] = []
        var threads: [PRThread] = []
        var drafts: [DraftComment] = []
        var viewed: Set<String> = []
        var hiddenReviewers: Set<String> = []
        var headSHA = ""
    }

    private var session: SessionData {
        guard let review else { return SessionData() }
        return SessionData(
            endpoint: review.endpoint, isDemo: isDemoMode, pr: review.pr,
            files: review.files, threads: review.threads,
            drafts: review.drafts, viewed: review.viewed,
            hiddenReviewers: review.hiddenReviewers,
            headSHA: review.pr?.headRefOid ?? ""
        )
    }

    private var isDemoMode: Bool {
        demoSession
    }

    // MARK: - Drafts

    /// Starts a new draft editor anchored at the given line.
    public func beginDraft(at anchor: DraftStartAnchor) {
        performance.beginDraftEditor(path: anchor.path, line: anchor.line)
        AppLog.info("draft", "Opening draft editor; path=\(anchor.path); side=\(anchor.side); line=\(anchor.line)")
        draftEditor = DraftEditorState(
            draftID: nil, path: anchor.path, side: anchor.side, line: anchor.line,
            startLine: anchor.startLine, startSide: anchor.startSide
        )
    }

    /// Opens an existing draft for editing.
    public func editDraft(_ draft: DraftComment) {
        performance.beginDraftEditor(path: draft.path, line: draft.line)
        AppLog.info("draft", "Editing draft; path=\(draft.path); side=\(draft.side); line=\(draft.line)")
        draftEditor = DraftEditorState(
            draftID: draft.id, path: draft.path, side: draft.side, line: draft.line,
            startLine: draft.startLine, startSide: draft.startSide, text: draft.body
        )
    }

    /// Cancels the editor without changes.
    public func cancelDraftEditor() {
        AppLog.info("draft", "Cancelled draft editor")
        draftEditor = nil
    }

    /// Saves the editor: creates or updates the draft, persists, records
    /// history. Empty text on a new draft discards it; empty text on an
    /// existing draft deletes it.
    public func saveDraftEditor() {
        guard let editor = draftEditor else { return }
        let trimmed = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editor.draftID {
            // Edit or delete existing.
            guard let index = session.drafts.firstIndex(where: { $0.id == id }) else {
                draftEditor = nil
                return
            }
            let before = session.drafts[index]
            if trimmed.isEmpty {
                var drafts = session.drafts
                drafts.remove(at: index)
                applyDraftMutation(DraftMutation(draftID: id, before: before, after: nil), drafts: drafts)
            } else {
                var updated = before
                updated.body = trimmed
                var drafts = session.drafts
                drafts[index] = updated
                applyDraftMutation(DraftMutation(draftID: id, before: before, after: updated), drafts: drafts)
            }
        } else {
            guard !trimmed.isEmpty else {
                draftEditor = nil // empty new draft is discarded
                return
            }
            let draft = DraftComment(
                path: editor.path, line: editor.line, side: editor.side, body: trimmed,
                startLine: editor.startLine, startSide: editor.startSide
            )
            var drafts = session.drafts
            drafts.append(draft)
            applyDraftMutation(DraftMutation(draftID: draft.id, before: nil, after: draft), drafts: drafts)
        }
        draftEditor = nil
    }

    /// Deletes a draft (records history).
    public func deleteDraft(_ draft: DraftComment) {
        guard let index = session.drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        var drafts = session.drafts
        drafts.remove(at: index)
        applyDraftMutation(DraftMutation(draftID: draft.id, before: draft, after: nil), drafts: drafts)
    }

    private func applyDraftMutation(_ mutation: DraftMutation, drafts: [DraftComment]) {
        AppLog.info("draft", "Applied draft mutation; draftCount=\(drafts.count); undoDepth=\(self.undoStack.count + 1)")
        review = review?.withDrafts(drafts)
        recordHistory(mutation)
        persistDrafts()
    }

    /// All commentable-line anchors for a file's diff (for range selection).
    public func commentableAnchors(for file: DiffFile) -> [DraftStartAnchor] {
        file.hunks.enumerated().flatMap { hunkIndex, hunk in
            hunk.lines.enumerated().compactMap { lineIndex, line in
                DraftRangeValidator.anchor(for: file, hunkIndex: hunkIndex, lineIndex: lineIndex).map {
                    DraftStartAnchor(path: $0.path, side: $0.side, line: $0.line,
                                     startLine: $0.startLine, startSide: $0.startSide)
                }
            }
        }
    }

    // MARK: - Undo / redo

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private func recordHistory(_ mutation: DraftMutation) {
        undoStack.append(mutation)
        redoStack.removeAll()
    }

    public func undoDraft() {
        guard let mutation = undoStack.popLast() else { return }
        redoStack.append(mutation)
        var drafts = review?.drafts ?? []
        if let before = mutation.before {
            if let index = drafts.firstIndex(where: { $0.id == mutation.draftID }) {
                drafts[index] = before
            } else {
                drafts.append(before)
            }
        } else {
            drafts.removeAll { $0.id == mutation.draftID }
        }
        review = review?.withDrafts(drafts)
        persistDrafts()
    }

    public func redoDraft() {
        guard let mutation = redoStack.popLast() else { return }
        undoStack.append(mutation)
        var drafts = review?.drafts ?? []
        if let after = mutation.after {
            if let index = drafts.firstIndex(where: { $0.id == mutation.draftID }) {
                drafts[index] = after
            } else {
                drafts.append(after)
            }
        } else {
            drafts.removeAll { $0.id == mutation.draftID }
        }
        review = review?.withDrafts(drafts)
        persistDrafts()
    }

    // MARK: - Persistence (debounced)

    /// A short debounce so rapid draft/viewed mutations coalesce into one
    /// filesystem write. The in-memory state updates immediately; only the
    /// disk write is deferred. The last snapshot always wins. The pending
    /// tasks are declared on the class (extensions cannot hold stored props).
    private static let persistDebounceNanos: UInt64 = 150_000_000 // 150 ms

    private func persistDrafts() {
        guard let endpoint = session.endpoint, !session.headSHA.isEmpty else { return }
        let drafts = session.drafts
        let headSHA = session.headSHA
        pendingDraftSave?.cancel()
        pendingDraftSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDebounceNanos)
            guard !Task.isCancelled else { return }
            do {
                try await self?.persistence.saveDrafts(drafts, for: endpoint, headSHA: headSHA)
                self?.persistenceFailure = nil
                AppLog.debug("persistence", "Saved drafts; endpoint=\(endpoint); count=\(drafts.count)")
            } catch {
                AppLog.failure("persistence", context: "Could not save drafts for \(endpoint)", error: error)
                self?.persistenceFailure = PersistenceFailure(operation: "drafts", message: "\(error)")
                self?.banner = SessionBanner(text: "Could not save local drafts. Changes remain in memory.", isError: true)
            }
        }
    }

    private func persistViewed() {
        guard let endpoint = session.endpoint, !session.headSHA.isEmpty else { return }
        let viewed = session.viewed
        let headSHA = session.headSHA
        pendingViewedSave?.cancel()
        pendingViewedSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDebounceNanos)
            guard !Task.isCancelled else { return }
            do {
                try await self?.persistence.saveViewed(viewed, for: endpoint, headSHA: headSHA)
                self?.persistenceFailure = nil
                AppLog.debug("persistence", "Saved viewed marks; endpoint=\(endpoint); count=\(viewed.count)")
            } catch {
                AppLog.failure("persistence", context: "Could not save viewed marks for \(endpoint)", error: error)
                self?.persistenceFailure = PersistenceFailure(operation: "viewed", message: "\(error)")
                self?.banner = SessionBanner(text: "Could not save local viewed marks. Changes remain in memory.", isError: true)
            }
        }
    }

    private func persistHiddenReviewers() {
        guard let endpoint = session.endpoint else { return }
        let hidden = session.hiddenReviewers
        pendingHiddenReviewersSave?.cancel()
        pendingHiddenReviewersSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDebounceNanos)
            guard !Task.isCancelled else { return }
            do {
                try await self?.persistence.saveHiddenReviewers(hidden, for: endpoint)
                self?.persistenceFailure = nil
                AppLog.debug("persistence", "Saved hidden reviewers; endpoint=\(endpoint); count=\(hidden.count)")
            } catch {
                AppLog.failure("persistence", context: "Could not save hidden reviewers for \(endpoint)", error: error)
                self?.persistenceFailure = PersistenceFailure(operation: "hidden reviewers", message: "\(error)")
                self?.banner = SessionBanner(text: "Could not save hidden reviewer state. Changes remain in memory.", isError: true)
            }
        }
    }
}

// MARK: - Hidden reviewers

public extension ReviewSessionStore {

    /// The set of comment authors whose threads are currently hidden.
    var hiddenReviewers: Set<String> {
        review?.hiddenReviewers ?? []
    }

    /// Distinct comment authors across ALL threads (visible or hidden),
    /// alphabetized. The toolbar and menus use this list to offer hide and
    /// unhide for every participant.
    var reviewerNames: [String] {
        guard let review else { return [] }
        var names = Set<String>()
        for thread in review.threads {
            for comment in thread.comments where !comment.author.isEmpty {
                names.insert(comment.author)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Hides every thread that contains a comment by this author.
    func hideReviewer(_ name: String) {
        guard !name.isEmpty else { return }
        applyHiddenReviewers((review?.hiddenReviewers ?? []).union([name]))
    }

    func unhideReviewer(_ name: String) {
        guard !name.isEmpty else { return }
        applyHiddenReviewers((review?.hiddenReviewers ?? []).subtracting([name]))
    }

    func unhideAllReviewers() {
        guard let review, !review.hiddenReviewers.isEmpty else { return }
        applyHiddenReviewers([])
    }

    /// Applies a new hidden set and cleans up anything pointing at threads
    /// that just became invisible: the row selection and open reply editors.
    private func applyHiddenReviewers(_ hidden: Set<String>) {
        guard let review else { return }
        AppLog.info("review", "Updated hidden-reviewer filter; count=\(hidden.count)")
        self.review = review.withHiddenReviewers(hidden)
        if case .thread(let threadID)? = selection.rowID,
           let thread = self.review?.threadByID[threadID],
           thread.comments.contains(where: { hidden.contains($0.author) }) {
            selection.rowID = nil
        }
        replyEditors = replyEditors.filter { threadID, _ in
            guard let thread = self.review?.threadByID[threadID] else { return false }
            return !thread.comments.contains(where: { hidden.contains($0.author) })
        }
        persistHiddenReviewers()
    }
}

// MARK: - Viewed

public extension ReviewSessionStore {
    /// Toggles the local viewed mark for a file path and persists it. Only the
    /// sidebar's `isViewed` flags are rebuilt (never the diff rows).
    func toggleViewed(filePath: String) {
        var viewed = review?.viewed ?? []
        if viewed.contains(filePath) {
            viewed.remove(filePath)
        } else {
            viewed.insert(filePath)
        }
        review = review?.withViewed(viewed)
        AppLog.info("review", "Toggled viewed mark; path=\(filePath); isViewed=\(viewed.contains(filePath))")
        persistViewed()
    }

    // MARK: - Stacked list

    func isCollapsedInList(_ file: DiffFile) -> Bool {
        listCollapseOverrides[file.path]
            ?? StackedDiffsLayout.isCollapsedByDefault(file, isViewed: review?.viewed.contains(file.path) ?? false)
    }

    func toggleCollapsedInList(_ file: DiffFile) {
        listCollapseOverrides[file.path] = !isCollapsedInList(file)
    }

    /// Marks a file viewed or not from the list; a file just marked viewed
    /// folds away, like GitHub's "Viewed" checkbox.
    func toggleViewedInList(_ file: DiffFile) {
        toggleViewed(filePath: file.path)
        listCollapseOverrides[file.path] = nil
    }

    // MARK: - Context expansion

    /// Lines revealed per click; `all` reveals the whole gap.
    nonisolated static let contextExpansionStep = 20

    /// Reveals hidden unchanged lines above hunk `hunkIndex` of `path`, read
    /// from the head version of the file (fetched once per head SHA).
    func expandContext(path: String, aboveHunk hunkIndex: Int, all: Bool = false) {
        guard let review, let endpoint = review.endpoint, let sha = review.pr?.headRefOid,
              let file = review.files.first(where: { $0.path == path }),
              file.hiddenLinesAbove(hunk: hunkIndex) > 0 else { return }
        guard !demoSession else {
            banner = SessionBanner(text: "Hidden lines are not available in the demo.")
            return
        }
        let key = "\(sha):\(path)"
        let service = self.service
        Task { [weak self] in
            do {
                let lines: [String]
                if let cached = self?.fileLinesCache[key] {
                    lines = cached
                } else {
                    lines = try await service.fetchFileLines(endpoint, path: path, ref: sha)
                    self?.fileLinesCache[key] = lines
                }
                self?.applyContextExpansion(path: path, hunkIndex: hunkIndex, all: all, sha: sha, lines: lines)
            } catch {
                AppLog.failure("review", context: "Loading hidden lines failed; path=\(path)", error: error)
                self?.banner = SessionBanner(text: "Could not load hidden lines: \(error)", isError: true)
            }
        }
    }

    private func applyContextExpansion(path: String, hunkIndex: Int, all: Bool, sha: String, lines: [String]) {
        guard let review, review.pr?.headRefOid == sha,
              let index = review.files.firstIndex(where: { $0.path == path }) else { return }
        let file = review.files[index]
        let count = all ? file.hiddenLinesAbove(hunk: hunkIndex) : Self.contextExpansionStep
        let expanded = file.expandingContext(aboveHunk: hunkIndex, count: count, newFileLines: lines)
        guard expanded != file else { return }
        var files = review.files
        files[index] = expanded
        resetDerivedCaches()
        self.review = ReviewPresentation(
            endpoint: review.endpoint, pr: review.pr, files: files, threads: review.threads,
            drafts: review.drafts, viewed: review.viewed, hiddenReviewers: review.hiddenReviewers
        )
        selection.rowID = nil
        AppLog.info("review", "Expanded context; path=\(path); hunk=\(hunkIndex); revealed=\(min(count, file.hiddenLinesAbove(hunk: hunkIndex)))")
    }

    // MARK: - Resolve / unresolve (optimistic + rollback)

    /// Toggles a thread's resolved state optimistically, then syncs with
    /// GitHub. A stale failure (superseded by a newer toggle on the same
    /// thread) is ignored. Resolving changes no rows (only the thread value),
    /// so the update stays O(1).
    func toggleResolved(threadID: String) {
        guard let review, let index = review.threads.firstIndex(where: { $0.id == threadID }) else { return }
        let thread = review.threads[index]
        guard !thread.isOutdated else { return }
        let newState = !thread.isResolved
        let wasResolved = thread.isResolved

        var updated = thread
        updated.isResolved = newState
        self.review = review.withThread(updated)
        AppLog.info("review", "Optimistically set thread resolved=\(newState); threadID=\(threadID)")

        guard let endpoint = review.endpoint, !demoSession else {
            return
        }
        resolveGenerations[threadID] = (resolveGenerations[threadID] ?? 0) + 1
        let generation = resolveGenerations[threadID] ?? 1
        let operations = ReviewOperations(service: service, persistence: persistence)
        Task { [weak self] in
            do {
                try await operations.setResolved(endpoint: endpoint, threadID: threadID, resolved: newState)
                self?.resolveHandlingCount += 1
                AppLog.info("review", "Thread resolution synced; threadID=\(threadID); resolved=\(newState)")
            } catch {
                AppLog.failure("review", context: "Thread resolution failed; threadID=\(threadID)", error: error)
                guard let self else { return }
                self.resolveHandlingCount += 1
                guard generation == self.resolveGenerations[threadID] else { return }
                guard let currentReview = self.review,
                      let currentIndex = currentReview.threads.firstIndex(where: { $0.id == threadID }) else { return }
                var rollback = currentReview.threads[currentIndex]
                rollback.isResolved = wasResolved
                self.review = currentReview.withThread(rollback)
                self.banner = SessionBanner(text: "Resolve failed: \(error)", isError: true)
            }
        }
    }

    // MARK: - Reply (retryable)

    func beginReply(threadID: String) {
        guard let thread = session.threads.first(where: { $0.id == threadID }),
              let commentID = thread.rootCommentID else { return }
        AppLog.info("review", "Opening reply editor; threadID=\(threadID); commentID=\(commentID)")
        replyEditors[threadID] = ReplyEditorState(threadID: threadID, commentID: commentID)
    }

    func updateReply(threadID: String, body: String) {
        guard var editor = replyEditors[threadID] else { return }
        editor.body = body
        replyEditors[threadID] = editor
    }

    func cancelReply(threadID: String) {
        replyEditors[threadID] = nil
    }

    func sendReply(threadID: String) {
        guard var editor = replyEditors[threadID] else { return }
        let body = editor.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        if demoSession {
            if var updated = review?.threads.first(where: { $0.id == threadID }) {
                updated.comments.append(
                    PRComment(databaseId: 9999, author: "you", body: body, createdAt: Date())
                )
                review = review?.withThread(updated)
            }
            replyEditors[threadID] = nil
            banner = SessionBanner(text: "Demo: reply added locally.")
            return
        }
        guard let endpoint = session.endpoint else { return }
        let operations = ReviewOperations(service: service, persistence: persistence)
        AppLog.info("review", "Sending reply; endpoint=\(endpoint); threadID=\(threadID); commentID=\(editor.commentID)")

        replyEditors[threadID] = ReplyEditorState(threadID: editor.threadID, commentID: editor.commentID, body: editor.body, retryFailed: true)
        editor.retryFailed = true
        replyEditors[threadID] = editor
        Task { [weak self] in
            do {
                try await operations.reply(endpoint: endpoint, commentID: editor.commentID, body: body)
                AppLog.info("review", "Reply sent; threadID=\(threadID)")
                self?.replyEditors[threadID] = nil
                self?.refresh()
            } catch {
                AppLog.failure("review", context: "Reply failed; threadID=\(threadID)", error: error)
                guard let self else { return }
                self.replyEditors[threadID] = ReplyEditorState(
                    threadID: editor.threadID, commentID: editor.commentID,
                    body: editor.body, retryFailed: true
                )
                self.banner = SessionBanner(text: "Reply failed: \(error)", isError: true)
            }
        }
    }

    // MARK: - Submit

    func beginSubmit() {
        AppLog.info("review", "Opening submit-review sheet")
        submitEvent = .comment
        submitBody = ""
        submitValidationMessage = nil
        submitState = .editing
    }

    func cancelSubmit() {
        if case .submitting = submitState {
            // Cancelling an in-flight submission leaves the remote result
            // uncertain: retain drafts and show the uncertain state.
            submitTask?.cancel()
            submitState = .uncertain(message: "Submission was interrupted. Verify on GitHub before retrying.")
        } else {
            submitState = .hidden
            submitValidationMessage = nil
        }
    }

    func submitReview() {
        guard case .editing = submitState else { return }
        let event = submitEvent
        let body = submitBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittable = session.drafts.filter { !$0.isOrphaned }
        if event == .approve && body.isEmpty && !submittable.isEmpty {
            submitValidationMessage = "Approvals with inline comments usually include a summary."
            return
        }
        submitValidationMessage = nil
        submitState = .submitting
        AppLog.info("review", "Submitting review; event=\(event.apiValue); drafts=\(submittable.count); summaryCharacters=\(body.count)")

        if demoSession {
            review = review?.withDrafts(review?.drafts.filter { $0.isOrphaned } ?? [])
            submitState = .hidden
            banner = SessionBanner(text: "Demo mode — review not submitted.")
            return
        }
        guard let endpoint = session.endpoint else {
            submitState = .failed(message: "Not connected to GitHub.")
            return
        }
        let headSHA = session.headSHA
        let operations = ReviewOperations(service: service, persistence: persistence)
        let task = Task { [weak self] in
            do {
                let result = try await operations.submit(
                    endpoint: endpoint, headSHA: headSHA, body: body, event: event, drafts: submittable
                )
                guard let self else { return }
                let submitted = result.submitted.drafts
                var drafts = self.review?.drafts ?? []
                drafts.removeAll { submitted.contains($0) }
                self.review = self.review?.withDrafts(drafts)
                self.submitState = .hidden
                self.banner = SessionBanner(text: "Review submitted.")
                self.persistDrafts()
                AppLog.info("review", "Review submitted; draftsSent=\(submitted.count)")
                self.refresh()
            } catch is CancellationError {
                AppLog.warning("review", "Review submission was cancelled")
                guard let self else { return }
                // Cancellation after dispatch: the remote result is uncertain.
                self.submitState = .uncertain(message: "Submission was interrupted. Verify on GitHub before retrying.")
            } catch {
                AppLog.failure("review", context: "Review submission failed", error: error)
                guard let self else { return }
                self.submitState = .failed(message: "Submit failed: \(error)")
            }
        }
        submitTask = task
    }

    // MARK: - Refresh (with selection preservation)

    /// Refreshes via the shared migration path, preserving the selected path.
    func refresh() {
        guard let endpoint = session.endpoint, !demoSession else {
            banner = SessionBanner(text: "Demo mode — nothing to refresh.")
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()

        let snapshot = session
        let anchorPath = selection.filePath
        AppLog.info("refresh", "Starting refresh generation=\(generation); endpoint=\(endpoint); selectedPath=\(anchorPath ?? "none")")
        let operations = ReviewOperations(service: service, persistence: persistence)
        isBusy = true
        let task = Task { [weak self] in
            do {
                guard let self else { return }
                let bundle = try await self.service.fetchAll(endpoint)
                AppLog.info("refresh", "Fetched refresh bundle; files=\(bundle.files.count); threads=\(bundle.threads.count)")
                let result = try await operations.migrate(
                    bundle: bundle, endpoint: endpoint,
                    current: ReviewLocalState(
                        headSHA: snapshot.headSHA, drafts: snapshot.drafts, viewed: snapshot.viewed,
                        hiddenReviewers: snapshot.hiddenReviewers
                    )
                )
                try Task.checkCancellation()
                guard generation == self.refreshGeneration else { return }
                let pr = result.bundle.pr
                let files = result.bundle.files
                let threads = result.bundle.threads
                let drafts = result.localState.drafts
                let viewed = result.localState.viewed
                let hiddenReviewers = result.localState.hiddenReviewers
                // Build the presentation (rows, indexes, sidebar aggregation)
                // off the main actor; only the finished snapshot is published.
                let presentation = await Task.detached(priority: .userInitiated) {
                    ReviewPresentation(
                        endpoint: endpoint, pr: pr, files: files, threads: threads,
                        drafts: drafts, viewed: viewed, hiddenReviewers: hiddenReviewers
                    )
                }.value
                try Task.checkCancellation()
                guard generation == self.refreshGeneration else { return }
                self.review = presentation
                // Preserve selection by path; rowID resets (anchor restoration is Phase 9).
                let kept = anchorPath.flatMap { path in
                    files.contains { $0.path == path } ? path : nil
                }
                self.selection = ReviewSelection(filePath: kept ?? files.first?.path)
                self.banner = SessionBanner(text: result.message)
                self.isBusy = false
                AppLog.info("refresh", "Completed refresh generation=\(generation); selectedPath=\(self.selection.filePath ?? "none"); message=\(result.message)")
            } catch is CancellationError {
                AppLog.warning("refresh", "Refresh generation=\(generation) cancelled")
                // superseded or cancelled
            } catch {
                AppLog.failure("refresh", context: "Refresh generation=\(generation) failed", error: error)
                guard let self, generation == self.refreshGeneration else { return }
                self.banner = SessionBanner(text: "Refresh failed: \(error)", isError: true)
                self.isBusy = false
            }
        }
        refreshTask = task
    }

    // MARK: - Clipboard / browser

    /// Copies the exact `path:line content` text for a line row.
    func copyLineToClipboard(file: DiffFile, hunkIndex: Int, lineIndex: Int) -> Bool {
        guard let line = file.line(at: hunkIndex, lineIndex) else { return false }
        AppLog.info("clipboard", "Copying diff line; path=\(file.path); line=\(line.newLine ?? line.oldLine ?? 0)")
        let text = ReviewUtilities.clipboardText(path: file.path, line: line)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        banner = SessionBanner(text: "Copied \(file.path):\(line.newLine ?? line.oldLine ?? 0)")
        return true
    }

    /// Opens the PR in the default browser.
    func openInBrowser() {
        let url = ReviewUtilities.pullRequestURL(session.pr?.url)
        if demoSession || url == nil {
            banner = SessionBanner(text: demoSession ? "Demo mode — no PR URL to open." : "No PR URL available.", isError: true)
            return
        }
        AppLog.info("browser", "Opening PR URL in browser")
        NSWorkspace.shared.open(url!)
    }
}

// MARK: - Selection helpers

public extension ReviewSessionStore {
    /// Resolves a line row ID back to its (hunk, lineIndex) position in the
    /// given file by matching kind + old/new anchors. Results are cached per
    /// file (cleared on every load) so repeated command/tap lookups are O(1).
    func linePosition(for rowID: DiffRowID?, in file: DiffFile) -> (hunk: Int, lineIndex: Int)? {
        guard let rowID, case DiffRowID.line = rowID else {
            return nil
        }
        if let cached = linePositionCache[file.path] {
            return cached[rowID]
        }
        var map: [DiffRowID: (hunk: Int, lineIndex: Int)] = [:]
        map.reserveCapacity(file.lineCount)
        for (hi, hunk) in file.hunks.enumerated() {
            for (idx, l) in hunk.lines.enumerated() {
                let id = DiffRowID.line(
                    file: file.path, hunk: hi, kind: l.kind,
                    old: l.oldLine, new: l.newLine
                )
                map[id] = (hi, idx)
            }
        }
        linePositionCache[file.path] = map
        return map[rowID]
    }

    /// The selected diff line position, if the selection is a diff line.
    func selectedLinePosition(in file: DiffFile) -> (hunk: Int, lineIndex: Int)? {
        linePosition(for: selection.rowID, in: file)
    }
}

// MARK: - Phase 7: commands, navigation, escape

public extension ReviewSessionStore {

    /// Builds the pure command context for the current store state.
    func commandContext() -> ReviewCommandContext {
        let loaded = state == .loaded
        var commentable = false
        var threadIsActive = false
        var threadHasRoot = false
        if loaded, let file = selectedFile, let position = selectedLinePosition(in: file) {
            commentable = DraftRangeValidator.anchor(for: file, hunkIndex: position.hunk, lineIndex: position.lineIndex) != nil
        }
        if loaded, case .thread(let threadID)? = selection.rowID,
           let thread = review?.threadByID[threadID] {
            threadIsActive = !thread.isOutdated
            threadHasRoot = thread.rootCommentID != nil
        }
        return ReviewCommandContext(
            state: state, isDemo: demoSession,
            hasSelectedFile: selection.filePath != nil,
            hasCommentableSelection: commentable,
            selectedThreadIsActive: threadIsActive,
            selectedThreadHasRootComment: threadHasRoot,
            canUndo: canUndo, canRedo: canRedo,
            draftEditorOpen: draftEditor != nil,
            submitHidden: submitState == .hidden,
            isSubmitting: submitState == .submitting,
            canSubmit: true,   // body-only reviews are valid; availability gates on .loaded
            hasPRURL: ReviewUtilities.pullRequestURL(session.pr?.url) != nil,
            hasReviewers: !reviewerNames.isEmpty,
            hasHiddenReviewers: !(review?.hiddenReviewers.isEmpty ?? true)
        )
    }

    // MARK: - Diff navigation

    /// Ordered row IDs of commentable diff lines in the selected file. Built
    /// lazily and cached per file (cleared on every load), so holding an arrow
    /// key over a very large file never rescans the file per keystroke.
    func commentableLineIDs(in file: DiffFile) -> [DiffRowID] {
        if let cached = commentableCache[file.path] {
            return cached
        }
        var ids: [DiffRowID] = []
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            for (lineIndex, line) in hunk.lines.enumerated() {
                guard DraftRangeValidator.anchor(for: file, hunkIndex: hunkIndex, lineIndex: lineIndex) != nil else {
                    continue
                }
                ids.append(DiffRowID.line(
                    file: file.path, hunk: hunkIndex, kind: line.kind,
                    old: line.oldLine, new: line.newLine
                ))
            }
        }
        commentableCache[file.path] = ids
        return ids
    }

    /// Moves the line selection by delta among commentable lines.
    func moveLineSelection(_ delta: Int, in file: DiffFile) {
        let ids = commentableLineIDs(in: file)
        guard !ids.isEmpty else { return }
        let currentIndex = selection.rowID.flatMap { ids.firstIndex(of: $0) }
        let next = min(max(0, (currentIndex ?? (delta > 0 ? -1 : ids.count)) + delta), ids.count - 1)
        selection.rowID = ids[next]
    }

    func selectPreviousFile() {
        selectAdjacentFile(-1)
    }

    func selectNextFile() {
        selectAdjacentFile(1)
    }

    func selectPreviousUnviewedFile() {
        selectAdjacentUnviewedFile(-1)
    }

    func selectNextUnviewedFile() {
        selectAdjacentUnviewedFile(1)
    }

    /// Marks the selected file viewed (never un-marks it) and moves to the
    /// next unviewed file; stays put once every file is viewed.
    func markViewedAndAdvance() {
        guard let path = selection.filePath ?? review?.files.first?.path else { return }
        if review?.viewed.contains(path) == false {
            toggleViewed(filePath: path)
        }
        selectAdjacentUnviewedFile(1)
    }

    /// Walks the file list in `delta`'s direction, wrapping around, to the
    /// first file that is neither viewed nor the current one.
    private func selectAdjacentUnviewedFile(_ delta: Int) {
        guard let review, !review.files.isEmpty else { return }
        let count = review.files.count
        let start = selection.filePath.flatMap { review.fileIndexByPath[$0] } ?? (delta > 0 ? -1 : count)
        for step in 1...count {
            let index = ((start + delta * step) % count + count) % count
            let path = review.files[index].path
            guard path != selection.filePath, !review.viewed.contains(path) else { continue }
            select(filePath: path)
            selection.rowID = nil
            return
        }
    }

    private func selectAdjacentFile(_ delta: Int) {
        guard let review, !review.files.isEmpty else { return }
        let current = selection.filePath ?? review.files.first?.path
        let index = review.fileIndexByPath[current ?? ""] ?? 0
        let next = min(max(0, index + delta), review.files.count - 1)
        select(filePath: review.files[next].path)
        selection.rowID = nil
    }

    /// Selects the adjacent hunk header row in the current file. Hunk IDs are
    /// derived from the precomputed display rows; ordering by row index makes
    /// the scan cheap even for very large files.
    func selectAdjacentHunk(_ delta: Int, in file: DiffFile) {
        let hunkIDs: [DiffRowID]
        if let cached = hunkIDsCache[file.path] {
            hunkIDs = cached
        } else {
            let rows = review?.diffRows(for: file) ?? []
            hunkIDs = rows.compactMap { row -> DiffRowID? in
                if case .hunk = row.id { return row.id }
                return nil
            }
            hunkIDsCache[file.path] = hunkIDs
        }
        guard !hunkIDs.isEmpty else { return }
        let currentIndex = selection.rowID.flatMap { hunkIDs.firstIndex(of: $0) }
        let next = min(max(0, (currentIndex ?? (delta > 0 ? -1 : hunkIDs.count)) + delta), hunkIDs.count - 1)
        selection.rowID = hunkIDs[next]
    }

    // MARK: - Escape precedence

    /// Cancels the most relevant transient interaction: draft editor, reply
    /// editor, submit sheet (retaining uncertain behavior for in-flight
    /// submissions), loading, then the banner. Returns true when an
    /// interaction was cancelled; false when nothing needed dismissing
    /// (callers can then treat Escape as a mode switch, e.g. returning to
    /// the change canvas from a focused diff).
    @discardableResult
    func cancelTransientInteraction() -> Bool {
        if draftEditor != nil {
            cancelDraftEditor()
            return true
        }
        if !replyEditors.isEmpty {
            replyEditors = [:]
            return true
        }
        if submitState != .hidden {
            cancelSubmit()
            return true
        }
        if case .loading = state {
            cancelLoad()
            return true
        }
        if banner != nil {
            banner = nil
            return true
        }
        return false
    }
}

/// Clear draft history after a completed load (undo must not cross reviews).
public extension ReviewSessionStore {
    func clearDraftHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

// MARK: - Phase 8: dependency health

public extension ReviewSessionStore {

    /// Dependency health (published for the status UI).
    var dependencyStatus: GitHubDependencyStatus? {
        get { _dependencyStatus }
        set { _dependencyStatus = newValue }
    }

    /// Starts a nonblocking health check for a real window store.
    func startDependencyCheckIfNeeded() {
        guard !didStartDependencyCheck, !demoSession, !suppressDependencyCheck else { return }
        didStartDependencyCheck = true
        recheckDependency()
    }

    /// Re-runs the health check with the current executable preference.
    /// Superseded checks never publish (generation guard). A fresh resolver is
    /// built per check so preference changes take effect immediately.
    func recheckDependency() {
        dependencyGeneration += 1
        let generation = dependencyGeneration
        isCheckingDependency = true
        let resolver = GitHubExecutableResolver(overrideURL: preference.selectedExecutableURL)
        let runner = dependencyRunner ?? SystemCommandRunner(resolver: resolver)
        let checker = GitHubDependencyChecker(runner: runner, resolver: resolver)
        AppLog.info("dependency", "Starting GitHub CLI health check generation=\(generation)")
        Task { [weak self] in
            let status = await checker.check()
            guard let self, generation == self.dependencyGeneration else { return }
            self.isCheckingDependency = false
            self._dependencyStatus = status
            AppLog.info("dependency", "Completed GitHub CLI health check generation=\(generation); state=\(status.state); executable=\(status.executableURL?.path ?? "none")")
        }
    }

    // MARK: - Preference actions

    var selectedExecutableURL: URL? { preference.selectedExecutableURL }

    /// Validates and persists a user-selected executable, then rechecks.
    func setSelectedExecutable(_ url: URL) {
        if preference.setSelectedExecutableURL(url) {
            recheckDependency()
        } else {
            _dependencyStatus = GitHubDependencyStatus(
                state: .unusable, executableURL: url,
                message: "The selected file is not an executable."
            )
        }
    }

    func clearSelectedExecutable() {
        preference.clearSelectedExecutableURL()
        recheckDependency()
    }

    /// Copyable guidance for the current status (never runs a shell).
    var dependencyInstruction: String? {
        switch dependencyStatus?.state {
        case .missing:
            return "brew install gh"
        case .unauthenticated, .expiredOrRevoked:
            return "gh auth login"
        case .underScoped:
            return "gh auth refresh -h github.com -s repo"
        default:
            return nil
        }
    }
}
