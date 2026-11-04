import SwiftUI
import PRReviewKit

/// Which overview the window shows when no single file is focused.
public enum OverviewMode: String {
    case canvas
    case list

    public static let key = "PRReview.overviewMode"
}

/// The "List" overview: every file's diff in one scroll, GitHub's "Files
/// changed" page. Each file has a pinned header with its Viewed checkbox and
/// folds away; rows are the same ones the focused diff renders, so comments,
/// threads and hidden-line expansion work here too.
struct StackedDiffsView: View {
    @ObservedObject var store: ReviewSessionStore
    let files: [DiffFile]
    let presentation: DiffPresentation
    @Binding var showCanvas: Bool

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(files, id: \.path) { file in
                        Section {
                            if !store.isCollapsedInList(file) {
                                fileBody(file, width: geo.size.width)
                            }
                        } header: {
                            StackedFileHeader(store: store, file: file) {
                                store.select(filePath: file.path)
                                showCanvas = false
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("stacked-diffs")
    }

    @ViewBuilder
    private func fileBody(_ file: DiffFile, width: CGFloat) -> some View {
        if file.isBinary || file.tooLarge || file.hunks.isEmpty {
            Text(file.isBinary ? "Binary file" : file.tooLarge ? "Diff too large to show" : "No textual changes")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else {
            let languageID = Highlighter.languageID(for: file.path)
            let displayRows = store.review?.diffRows(for: file) ?? []
            ScrollView(.horizontal) {
                if presentation == .sideBySide {
                    sideBySideRows(file, displayRows: displayRows, languageID: languageID, width: width)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayRows) { row in
                            DiffRowView(store: store, file: file, displayRow: row, languageID: languageID)
                                .frame(minWidth: width, alignment: .leading)
                                .id(row.id)
                        }
                    }
                }
            }
        }
        Divider()
    }

    /// Before and After next to each other, one half each, with the hunk
    /// headers and comment threads spanning both.
    private func sideBySideRows(_ file: DiffFile, displayRows: [DiffDisplayRow], languageID: Int?, width: CGFloat) -> some View {
        let column = max(SideBySideDiffLayout.minimumColumnWidth(for: file), ((width - 1) / 2).rounded(.down))
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(SideBySideDiffLayout.rows(file: file, displayRows: displayRows)) { row in
                switch row {
                case .hunk(let hunkIndex):
                    HunkHeaderView(hunk: file.hunks[hunkIndex], hiddenAbove: file.hiddenLinesAbove(hunk: hunkIndex)) { all in
                        store.expandContext(path: file.path, aboveHunk: hunkIndex, all: all)
                    }
                    .frame(width: column * 2 + 1, alignment: .leading)
                case .lines(let hunkIndex, let oldLineIndex, let newLineIndex):
                    HStack(spacing: 0) {
                        sideCell(file, hunkIndex: hunkIndex, lineIndex: oldLineIndex, side: .old, languageID: languageID, width: column)
                        Divider().frame(height: 18)
                        sideCell(file, hunkIndex: hunkIndex, lineIndex: newLineIndex, side: .new, languageID: languageID, width: column)
                    }
                case .supplementary(let displayRow):
                    DiffRowView(store: store, file: file, displayRow: displayRow, languageID: languageID)
                        .frame(width: column * 2 + 1, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func sideCell(_ file: DiffFile, hunkIndex: Int, lineIndex: Int?, side: SideBySideDiffLineCell.Side, languageID: Int?, width: CGFloat) -> some View {
        if let lineIndex, let line = file.line(at: hunkIndex, lineIndex) {
            SideBySideDiffLineCell(
                store: store, file: file, line: line, hunkIndex: hunkIndex,
                lineIndex: lineIndex, languageID: languageID, side: side
            )
            .frame(width: width, height: 18, alignment: .leading)
            .clipped()
        } else {
            Color.clear.frame(width: width, height: 18)
        }
    }
}

private struct StackedFileHeader: View {
    @ObservedObject var store: ReviewSessionStore
    let file: DiffFile
    let open: () -> Void

    var body: some View {
        let collapsed = store.isCollapsedInList(file)
        let isViewed = store.review?.viewed.contains(file.path) ?? false
        let comments = store.review?.sidebarItems.first { $0.path == file.path }?.threadCount ?? 0
        HStack(spacing: 8) {
            Button {
                store.toggleCollapsedInList(file)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(file.status.letter)
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(file.path)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show this file's changes" : "Hide this file's changes")
            .accessibilityIdentifier("stacked-file-toggle-\(file.path)")
            Spacer(minLength: 8)
            Text(verbatim: "+\(file.additions) -\(file.deletions)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if comments > 0 {
                Label(String(comments), systemImage: "bubble.left")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
            Toggle("Viewed", isOn: Binding(
                get: { isViewed },
                set: { _ in store.toggleViewedInList(file) }
            ))
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("stacked-file-viewed-\(file.path)")
            Button("Open", action: open)
                .help("Open this file's focused diff")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
