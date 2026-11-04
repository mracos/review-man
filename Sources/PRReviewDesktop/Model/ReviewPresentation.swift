import Foundation
import PRReviewKit

/// Path-based selection for the desktop UI. Files are identified by path (not
/// index) so a reload retains the selected path when it still exists.
public struct ReviewSelection: Equatable {
    public var filePath: String?
    public var rowID: DiffRowID?

    public init(filePath: String? = nil, rowID: DiffRowID? = nil) {
        self.filePath = filePath
        self.rowID = rowID
    }
}

/// Typed, stable identity for one diff display row, derived from file, hunk,
/// side, and line anchors (never a transient array offset).
public enum DiffRowID: Hashable {
    case hunk(file: String, hunk: Int, oldStart: Int, newStart: Int)
    case line(file: String, hunk: Int, kind: DiffLine.Kind, old: Int?, new: Int?)
    case thread(id: String)
    case draft(id: UUID)
    case outdatedHeader(file: String)
    case orphanedHeader(file: String)
    case empty(file: String)
}

/// One row in the diff display: the core `Row` plus its file path and stable ID.
public struct DiffDisplayRow: Identifiable, Equatable {
    public let id: DiffRowID
    public let filePath: String
    public let row: Row

    public init(id: DiffRowID, filePath: String, row: Row) {
        self.id = id
        self.filePath = filePath
        self.row = row
    }
}

/// The single hovered diff row, isolated from the session store so moving the
/// pointer over a diff only invalidates diff-row views (never the sidebar,
/// header, toolbar, or editors). Diff rows observe this model directly.
@MainActor
public final class ReviewHoverModel: ObservableObject {
    @Published public var rowID: DiffRowID?

    public init() {}
}

/// Top-level load state of a review session window.
public enum PresentationState: Equatable {
    case welcome
    case loading(reference: String)
    case loaded
    case empty
    case failed(message: String)

    public static func == (lhs: PresentationState, rhs: PresentationState) -> Bool {
        switch (lhs, rhs) {
        case (.welcome, .welcome): return true
        case (.loading(let a), .loading(let b)): return a == b
        case (.loaded, .loaded): return true
        case (.empty, .empty): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

/// One row of the file sidebar.
public struct FileSidebarItem: Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let oldPath: String?
    public let statusLetter: String
    /// Additions/deletions are nil when the patch is unavailable (too-large).
    public let additions: Int?
    public let deletions: Int?
    public let isBinary: Bool
    public let tooLarge: Bool
    public let threadCount: Int
    public let isViewed: Bool
    /// Lowercased path, precomputed once so search filtering does not re-lower
    /// case every path on every keystroke.
    public let searchable: String

    public init(
        path: String, oldPath: String?, statusLetter: String,
        additions: Int?, deletions: Int?, isBinary: Bool, tooLarge: Bool,
        threadCount: Int, isViewed: Bool
    ) {
        self.path = path
        self.oldPath = oldPath
        self.statusLetter = statusLetter
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.tooLarge = tooLarge
        self.threadCount = threadCount
        self.isViewed = isViewed
        self.searchable = path.lowercased()
    }
}

/// Immutable data snapshot for a loaded review window.
///
/// The snapshot carries precomputed derived data so hot paths never rescan the
/// whole review:
/// - `rowsByFile` / `diffRowsByFile`: the display row list per file, built once.
/// - `fileIndexByPath` / `threadByID` / `draftByID`: O(1) lookups used by the
///   sidebar, detail pane, and row views.
///
/// Local mutations never rebuild the whole snapshot: `withViewed`,
/// `withDrafts`, and `withThread` return updated copies that rebuild only the
/// affected file's rows (or only the sidebar's viewed flags).
public struct ReviewPresentation {
    public let endpoint: PREndpoint?
    public let pr: PRInfo?
    public let files: [DiffFile]
    /// All fetched threads, including those hidden by the reviewer filter:
    /// resolve/reply operations and unhide need the full list.
    public let threads: [PRThread]
    public let drafts: [DraftComment]
    public let viewed: Set<String>
    /// Comment authors whose threads are hidden from the diff and the sidebar
    /// counts. A thread is hidden when ANY of its comments was written by a
    /// hidden author. Local-only state, persisted per pull request.
    public let hiddenReviewers: Set<String>
    /// RowBuilder rows per file path (display order is authoritative).
    public let rowsByFile: [String: [Row]]
    /// Display rows (rows + stable IDs) per file path, precomputed so a large
    /// file's viewport does not re-derive IDs on every body evaluation.
    public let diffRowsByFile: [String: [DiffDisplayRow]]
    /// RowBuilder rows for files that vanished from the diff (pathless orphans).
    public let pathlessOrphanIDs: [UUID]
    public let sidebarItems: [FileSidebarItem]
    /// O(1) lookups (built once; kept in sync by the incremental update methods).
    public let fileIndexByPath: [String: Int]
    public let threadByID: [String: PRThread]
    public let draftByID: [UUID: DraftComment]

    /// Full build (initial load / refresh).
    public init(
        endpoint: PREndpoint?,
        pr: PRInfo?,
        files: [DiffFile],
        threads: [PRThread],
        drafts: [DraftComment],
        viewed: Set<String>,
        hiddenReviewers: Set<String> = []
    ) {
        var fileIndex: [String: Int] = [:]
        fileIndex.reserveCapacity(files.count)
        for (i, f) in files.enumerated() { fileIndex[f.path] = i }
        var threadIndex: [String: PRThread] = [:]
        threadIndex.reserveCapacity(threads.count)
        for t in threads { threadIndex[t.id] = t }
        var draftIndex: [UUID: DraftComment] = [:]
        draftIndex.reserveCapacity(drafts.count)
        for d in drafts { draftIndex[d.id] = d }

        // Group threads/drafts by path ONCE; per-file row builds use the
        // grouped slices instead of re-filtering the global arrays per file.
        // Hidden threads are filtered BEFORE grouping, so every row build and
        // sidebar count sees the same visible set.
        let visibleThreads = Self.visibleThreads(threads, hiddenReviewers: hiddenReviewers)
        let threadsByPath = Dictionary(grouping: visibleThreads, by: { $0.path })
        let draftsByPath = Dictionary(grouping: drafts, by: { $0.path })

        var rows: [String: [Row]] = [:]
        rows.reserveCapacity(files.count)
        var diffRows: [String: [DiffDisplayRow]] = [:]
        diffRows.reserveCapacity(files.count)
        for file in files {
            let fileRows = RowBuilder.build(
                file: file,
                fileThreads: threadsByPath[file.path] ?? [],
                fileDrafts: draftsByPath[file.path] ?? [],
                outdatedExpanded: true
            )
            rows[file.path] = fileRows
            diffRows[file.path] = Self.displayRows(fileRows, for: file)
        }

        // Pathless orphans surface on the last file so they stay visible and
        // deletable even when their path vanished from the diff.
        let knownPaths = Set(files.map { $0.path })
        let pathless = drafts.filter { $0.isOrphaned && !knownPaths.contains($0.path) }
        var orphans: [UUID] = []
        if !pathless.isEmpty, let lastPath = files.last?.path, var lastRows = rows[lastPath] {
            if !lastRows.contains(.orphanedHeader) {
                lastRows.append(.orphanedHeader)
            }
            lastRows.append(contentsOf: pathless.map { .draft(draftID: $0.id) })
            rows[lastPath] = lastRows
            if let lastFileIndex = fileIndex[lastPath] {
                diffRows[lastPath] = Self.displayRows(lastRows, for: files[lastFileIndex])
            }
            orphans = pathless.map(\.id)
        }

        let sidebarItems = files.map { file -> FileSidebarItem in
            let threadCount = (threadsByPath[file.path] ?? []).filter { !$0.isOutdated }.count
                + (draftsByPath[file.path] ?? []).count
            let countsAvailable = !file.tooLarge && !file.isBinary
            return FileSidebarItem(
                path: file.path,
                oldPath: file.oldPath,
                statusLetter: file.status.letter,
                additions: countsAvailable ? file.additions : nil,
                deletions: countsAvailable ? file.deletions : nil,
                isBinary: file.isBinary,
                tooLarge: file.tooLarge,
                threadCount: threadCount,
                isViewed: viewed.contains(file.path)
            )
        }

        self.init(
            endpoint: endpoint, pr: pr, files: files, threads: threads, drafts: drafts,
            viewed: viewed, hiddenReviewers: hiddenReviewers, rowsByFile: rows,
            pathlessOrphanIDs: orphans, sidebarItems: sidebarItems, diffRowsByFile: diffRows,
            fileIndexByPath: fileIndex, threadByID: threadIndex, draftByID: draftIndex
        )
    }

    /// Internal full-field initializer: the incremental update methods reuse
    /// unchanged derived data (COW keeps the big arrays shared) and pass the
    /// rebuilt pieces explicitly.
    private init(
        endpoint: PREndpoint?,
        pr: PRInfo?,
        files: [DiffFile],
        threads: [PRThread],
        drafts: [DraftComment],
        viewed: Set<String>,
        hiddenReviewers: Set<String>,
        rowsByFile: [String: [Row]],
        pathlessOrphanIDs: [UUID],
        sidebarItems: [FileSidebarItem],
        diffRowsByFile: [String: [DiffDisplayRow]],
        fileIndexByPath: [String: Int],
        threadByID: [String: PRThread],
        draftByID: [UUID: DraftComment]
    ) {
        self.endpoint = endpoint
        self.pr = pr
        self.files = files
        self.threads = threads
        self.drafts = drafts
        self.viewed = viewed
        self.hiddenReviewers = hiddenReviewers
        self.rowsByFile = rowsByFile
        self.pathlessOrphanIDs = pathlessOrphanIDs
        self.sidebarItems = sidebarItems
        self.diffRowsByFile = diffRowsByFile
        self.fileIndexByPath = fileIndexByPath
        self.threadByID = threadByID
        self.draftByID = draftByID
    }

    /// Threads to display: a thread is hidden when ANY of its comments was
    /// written by a hidden reviewer, so hiding follows every author in a
    /// thread, not just the root commenter.
    static func visibleThreads(_ threads: [PRThread], hiddenReviewers: Set<String>) -> [PRThread] {
        guard !hiddenReviewers.isEmpty else { return threads }
        return threads.filter { thread in
            thread.comments.allSatisfy { !hiddenReviewers.contains($0.author) }
        }
    }

    public func rows(for path: String) -> [Row] {
        rowsByFile[path] ?? []
    }

    /// Maps a file's core rows to display rows with stable, anchor-derived IDs
    /// (precomputed at build time).
    /// Files in this diff marked viewed; a mark left on a file that is no
    /// longer in the pull request does not count.
    public var viewedFileCount: Int {
        files.reduce(0) { $0 + (viewed.contains($1.path) ? 1 : 0) }
    }

    public func diffRows(for file: DiffFile) -> [DiffDisplayRow] {
        diffRowsByFile[file.path] ?? []
    }

    /// A copy with a new viewed set: only sidebar `isViewed` flags change;
    /// rows and indexes are untouched.
    public func withViewed(_ newViewed: Set<String>) -> ReviewPresentation {
        let newSidebar = sidebarItems.map { item in
            let isViewed = newViewed.contains(item.path)
            guard isViewed != item.isViewed else { return item }
            return FileSidebarItem(
                path: item.path, oldPath: item.oldPath, statusLetter: item.statusLetter,
                additions: item.additions, deletions: item.deletions,
                isBinary: item.isBinary, tooLarge: item.tooLarge,
                threadCount: item.threadCount, isViewed: isViewed
            )
        }
        return ReviewPresentation(
            endpoint: endpoint, pr: pr, files: files, threads: threads, drafts: drafts,
            viewed: newViewed, hiddenReviewers: hiddenReviewers,
            rowsByFile: rowsByFile, pathlessOrphanIDs: pathlessOrphanIDs,
            sidebarItems: newSidebar, diffRowsByFile: diffRowsByFile,
            fileIndexByPath: fileIndexByPath, threadByID: threadByID, draftByID: draftByID
        )
    }

    /// A copy with a new hidden-reviewer set. Rows and sidebar counts are
    /// rebuilt only for files containing threads authored by any changed
    /// reviewer; everything else (indexes, other files' rows) is reused.
    public func withHiddenReviewers(_ newHidden: Set<String>) -> ReviewPresentation {
        let changed = hiddenReviewers.symmetricDifference(newHidden)
        guard !changed.isEmpty else { return self }

        let visible = Self.visibleThreads(threads, hiddenReviewers: newHidden)
        let visibleByPath = Dictionary(grouping: visible, by: { $0.path })
        let draftsByPath = Dictionary(grouping: drafts, by: { $0.path })

        // Only files with a thread by a changed author can change. Scanned
        // from the FULL thread list: a newly hidden thread is absent from
        // `visible`, so the visible grouping alone would miss its file.
        let threadsByPath = Dictionary(grouping: threads, by: { $0.path })
        var affected = Set<String>()
        for (path, fileThreads) in threadsByPath {
            if fileThreads.contains(where: { $0.comments.contains { changed.contains($0.author) } }) {
                affected.insert(path)
            }
        }
        let knownPaths = Set(files.map { $0.path })
        let pathless = drafts.filter { $0.isOrphaned && !knownPaths.contains($0.path) }
        let lastPath = files.last?.path

        var newRows = rowsByFile
        var newDiffRows = diffRowsByFile
        var newSidebar = sidebarItems
        var sidebarIndexByPath: [String: Int] = [:]
        sidebarIndexByPath.reserveCapacity(newSidebar.count)
        for (i, item) in newSidebar.enumerated() { sidebarIndexByPath[item.path] = i }

        for path in affected {
            guard let fileIndex = fileIndexByPath[path] else { continue }
            let file = files[fileIndex]
            var fileRows = RowBuilder.build(
                file: file,
                fileThreads: visibleByPath[path] ?? [],
                fileDrafts: draftsByPath[path] ?? [],
                outdatedExpanded: true
            )
            // Re-attach pathless orphans when the rebuilt file is the last
            // one (they surface on the last file, same as the full build).
            if path == lastPath, !pathless.isEmpty {
                if !fileRows.contains(.orphanedHeader) {
                    fileRows.append(.orphanedHeader)
                }
                fileRows.append(contentsOf: pathless.map { .draft(draftID: $0.id) })
            }
            newRows[path] = fileRows
            newDiffRows[path] = Self.displayRows(fileRows, for: file)

            if let sidebarIndex = sidebarIndexByPath[path] {
                let item = newSidebar[sidebarIndex]
                let threadCount = (visibleByPath[path] ?? []).filter { !$0.isOutdated }.count
                    + (draftsByPath[path] ?? []).count
                newSidebar[sidebarIndex] = FileSidebarItem(
                    path: item.path, oldPath: item.oldPath, statusLetter: item.statusLetter,
                    additions: item.additions, deletions: item.deletions,
                    isBinary: item.isBinary, tooLarge: item.tooLarge,
                    threadCount: threadCount, isViewed: item.isViewed
                )
            }
        }

        return ReviewPresentation(
            endpoint: endpoint, pr: pr, files: files, threads: threads, drafts: drafts,
            viewed: viewed, hiddenReviewers: newHidden,
            rowsByFile: newRows, pathlessOrphanIDs: pathlessOrphanIDs,
            sidebarItems: newSidebar, diffRowsByFile: newDiffRows,
            fileIndexByPath: fileIndexByPath, threadByID: threadByID, draftByID: draftByID
        )
    }

    /// A copy with a new drafts array: only the files whose rows depend on
    /// drafts are rebuilt (paths with drafts in either the old or new set,
    /// plus the last file when pathless orphans exist). Indexes are rebuilt
    /// for the changed slices.
    public func withDrafts(_ newDrafts: [DraftComment]) -> ReviewPresentation {
        let knownPaths = Set(files.map { $0.path })

        var affected = Set<String>()
        for d in drafts where knownPaths.contains(d.path) { affected.insert(d.path) }
        for d in newDrafts where knownPaths.contains(d.path) { affected.insert(d.path) }
        let oldHasPathless = drafts.contains { $0.isOrphaned && !knownPaths.contains($0.path) }
        let newHasPathless = newDrafts.contains { $0.isOrphaned && !knownPaths.contains($0.path) }
        if (oldHasPathless || newHasPathless), let last = files.last?.path {
            affected.insert(last)
        }

        let visibleThreads = Self.visibleThreads(threads, hiddenReviewers: hiddenReviewers)
        let threadsByPath = Dictionary(grouping: visibleThreads, by: { $0.path })
        let draftsByPath = Dictionary(grouping: newDrafts, by: { $0.path })

        var newRows = rowsByFile
        var newDiffRows = diffRowsByFile
        var newSidebar = sidebarItems
        var sidebarIndexByPath: [String: Int] = [:]
        sidebarIndexByPath.reserveCapacity(newSidebar.count)
        for (i, item) in newSidebar.enumerated() { sidebarIndexByPath[item.path] = i }

        let pathless = newDrafts.filter { $0.isOrphaned && !knownPaths.contains($0.path) }
        let lastPath = files.last?.path

        for path in affected {
            guard let fileIndex = fileIndexByPath[path] else { continue }
            let file = files[fileIndex]
            var fileRows = RowBuilder.build(
                file: file,
                fileThreads: threadsByPath[path] ?? [],
                fileDrafts: draftsByPath[path] ?? [],
                outdatedExpanded: true
            )
            if path == lastPath, !pathless.isEmpty {
                if !fileRows.contains(.orphanedHeader) {
                    fileRows.append(.orphanedHeader)
                }
                fileRows.append(contentsOf: pathless.map { .draft(draftID: $0.id) })
            }
            newRows[path] = fileRows
            newDiffRows[path] = Self.displayRows(fileRows, for: file)

            if let sidebarIndex = sidebarIndexByPath[path] {
                let item = newSidebar[sidebarIndex]
                let threadCount = (threadsByPath[path] ?? []).filter { !$0.isOutdated }.count
                    + (draftsByPath[path] ?? []).count
                newSidebar[sidebarIndex] = FileSidebarItem(
                    path: item.path, oldPath: item.oldPath, statusLetter: item.statusLetter,
                    additions: item.additions, deletions: item.deletions,
                    isBinary: item.isBinary, tooLarge: item.tooLarge,
                    threadCount: threadCount, isViewed: item.isViewed
                )
            }
        }

        var newDraftIndex: [UUID: DraftComment] = [:]
        newDraftIndex.reserveCapacity(newDrafts.count)
        for d in newDrafts { newDraftIndex[d.id] = d }

        return ReviewPresentation(
            endpoint: endpoint, pr: pr, files: files, threads: threads, drafts: newDrafts,
            viewed: viewed, hiddenReviewers: hiddenReviewers, rowsByFile: newRows,
            pathlessOrphanIDs: pathless.map(\.id), sidebarItems: newSidebar,
            diffRowsByFile: newDiffRows, fileIndexByPath: fileIndexByPath,
            threadByID: threadByID, draftByID: newDraftIndex
        )
    }

    /// A copy with one thread replaced. Rows are rebuilt for the thread's file
    /// only when its comments changed (a reply can reorder threads within the
    /// file); a resolve toggle changes no rows, only the thread value.
    public func withThread(_ updated: PRThread) -> ReviewPresentation {
        guard let index = threads.firstIndex(where: { $0.id == updated.id }) else { return self }
        var newThreads = threads
        newThreads[index] = updated
        var newThreadIndex = threadByID
        newThreadIndex[updated.id] = updated

        var newRows = rowsByFile
        var newDiffRows = diffRowsByFile
        if threads[index].comments != updated.comments,
           let fileIndex = fileIndexByPath[updated.path] {
            let file = files[fileIndex]
            let visible = Self.visibleThreads(newThreads, hiddenReviewers: hiddenReviewers)
            let fileThreads = visible.filter { $0.path == updated.path }
            let draftsByPath = Dictionary(grouping: drafts, by: { $0.path })
            var fileRows = RowBuilder.build(
                file: file,
                fileThreads: fileThreads,
                fileDrafts: draftsByPath[updated.path] ?? [],
                outdatedExpanded: true
            )
            // Re-attach pathless orphans when the rebuilt file is the last
            // one (they surface on the last file, same as the full build).
            if updated.path == files.last?.path {
                let knownPaths = Set(files.map { $0.path })
                let pathless = drafts.filter { $0.isOrphaned && !knownPaths.contains($0.path) }
                if !pathless.isEmpty {
                    if !fileRows.contains(.orphanedHeader) {
                        fileRows.append(.orphanedHeader)
                    }
                    fileRows.append(contentsOf: pathless.map { .draft(draftID: $0.id) })
                }
            }
            newRows[updated.path] = fileRows
            newDiffRows[updated.path] = Self.displayRows(fileRows, for: file)
        }

        return ReviewPresentation(
            endpoint: endpoint, pr: pr, files: files, threads: newThreads, drafts: drafts,
            viewed: viewed, hiddenReviewers: hiddenReviewers, rowsByFile: newRows,
            pathlessOrphanIDs: pathlessOrphanIDs, sidebarItems: sidebarItems,
            diffRowsByFile: newDiffRows, fileIndexByPath: fileIndexByPath,
            threadByID: newThreadIndex, draftByID: draftByID
        )
    }

    /// Core rows → display rows with stable, anchor-derived IDs.
    private static func displayRows(_ rows: [Row], for file: DiffFile) -> [DiffDisplayRow] {
        let path = file.path
        return rows.map { row in
            let id: DiffRowID
            switch row {
            case .hunkHeader(let hunkIndex):
                let hunk = file.hunks[hunkIndex]
                id = .hunk(file: path, hunk: hunkIndex, oldStart: hunk.oldStart, newStart: hunk.newStart)
            case .line(let hunkIndex, let lineIndex):
                let line = file.hunks[hunkIndex].lines[lineIndex]
                id = .line(file: path, hunk: hunkIndex, kind: line.kind, old: line.oldLine, new: line.newLine)
            case .thread(let threadID):
                id = .thread(id: threadID)
            case .draft(let draftID):
                id = .draft(id: draftID)
            case .outdatedHeader:
                id = .outdatedHeader(file: path)
            case .orphanedHeader:
                id = .orphanedHeader(file: path)
            case .empty:
                id = .empty(file: path)
            }
            return DiffDisplayRow(id: id, filePath: path, row: row)
        }
    }
}
