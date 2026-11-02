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
    @Binding var showCanvas: Bool
    @AppStorage(DiffTextSize.key) private var diffFontSize = Double(DiffTextSize.defaultSize)

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
        .environment(\.diffFontSize, CGFloat(diffFontSize))
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
            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.review?.diffRows(for: file) ?? []) { row in
                        DiffRowView(store: store, file: file, displayRow: row, languageID: languageID)
                            .frame(minWidth: width, alignment: .leading)
                            .id(row.id)
                    }
                }
            }
        }
        Divider()
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
