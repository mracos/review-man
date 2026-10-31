import SwiftUI
import PRReviewKit

/// The available presentations for a textual file diff.
public enum DiffPresentation: String, CaseIterable, Identifiable {
    case unified
    case sideBySide

    public var id: Self { self }

    public var title: String {
        switch self {
        case .unified: return "Unified"
        case .sideBySide: return "Side by Side"
        }
    }
}

/// The diff pane for one file: fixed-width gutters, horizontal scrolling,
/// LazyVStack rows with stable IDs, and programmatic scroll support.
public struct DiffView: View {
    @ObservedObject public var store: ReviewSessionStore
    public let file: DiffFile
    @Binding public var presentation: DiffPresentation
    /// Compact language identity for the whole file (cache key). Resolved once
    /// per body evaluation instead of once per line.
    private let languageID: Int?
    @AppStorage(DiffTextSize.key) private var diffFontSize = Double(DiffTextSize.defaultSize)

    public init(store: ReviewSessionStore, file: DiffFile, presentation: Binding<DiffPresentation>) {
        self.store = store
        self.file = file
        _presentation = presentation
        self.languageID = Highlighter.languageID(for: file.path)
    }

    public var body: some View {
        content.environment(\.diffFontSize, CGFloat(diffFontSize))
    }

    @ViewBuilder
    private var content: some View {
        if file.isBinary {
            EmptyStateView(
                icon: "doc.zipper",
                title: "Binary file",
                message: "\(file.path) cannot be displayed as a diff."
            )
            .accessibilityIdentifier("binary-file-state")
        } else if file.tooLarge {
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Diff too large",
                message: "\(file.path) exceeded the fetch limit and its patch is unavailable."
            )
            .accessibilityIdentifier("too-large-file-state")
        } else if file.hunks.isEmpty {
            EmptyStateView(
                icon: "doc",
                title: "No changes in this file",
                message: "\(file.path) has no textual changes to display."
            )
            .accessibilityIdentifier("empty-file-state")
        } else if presentation == .sideBySide {
            SideBySideDiffView(store: store, file: file)
                .onAppear { diffDidAppear() }
                .onDisappear { store.performance.diffDidDisappear(path: file.path) }
        } else {
            switch AppKitDiffSpike.mode {
            case .disabled:
                diffScroll
            case .surface:
                AppKitDiffSurfaceView(store: store, file: file, fontSize: CGFloat(diffFontSize))
                    .accessibilityIdentifier("diff-pane-appkit-surface")
                    .onAppear { diffDidAppear() }
                    .onDisappear { store.performance.diffDidDisappear(path: file.path) }
            }
        }
    }

    private var diffScroll: some View {
        let rows = displayRows()
        // The horizontal ScrollView proposes unbounded width to its content, so
        // rows collapse to intrinsic width — leaving a narrow strip of diff on
        // the left and empty space on the right. Each row gets a minimum width
        // of the pane so rows stretch to fill it; lines longer than the pane
        // still push the content wider and scroll horizontally.
        //
        // The minWidth is applied per-row (NOT on the LazyVStack): a minWidth
        // frame around the stack itself is vertically centered by its alignment
        // and fills the proposed height, leaving a large blank band above the
        // first row.
        return GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    ScrollView(.horizontal) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { displayRow in
                                DiffRowView(store: store, file: file, displayRow: displayRow, languageID: languageID)
                                    .frame(minWidth: geo.size.width, alignment: .leading)
                                    .id(displayRow.id)
                            }
                        }
                    }
                }
                .onMoveCommand { direction in
                    store.performance.recordNavigation()
                    handleMoveCommand(direction, proxy: proxy)
                }
            }
        }
        .accessibilityIdentifier("diff-pane")
        .onAppear {
            store.performance.diffDidAppear(
                path: file.path,
                lineCount: file.lineCount,
                rowCount: rows.count,
                hunkCount: file.hunks.count
            )
        }
        .onDisappear {
            store.performance.diffDidDisappear(path: file.path)
            AppLog.debug("render", "Closed diff pane; path=\(file.path)")
        }
    }

    private func diffDidAppear() {
        store.performance.diffDidAppear(
            path: file.path,
            lineCount: file.lineCount,
            rowCount: displayRows().count,
            hunkCount: file.hunks.count
        )
    }

    /// Arrow-key navigation among commentable lines; Escape handled at the
    /// window level. Scrolls the target row into view after moving.
    private func handleMoveCommand(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        switch direction {
        case .up, .down:
            store.moveLineSelection(direction == .down ? 1 : -1, in: file)
            if let rowID = store.selection.rowID {
                if AppearanceSettings.reduceMotion {
                    proxy.scrollTo(rowID, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(rowID, anchor: .center)
                    }
                }
            }
        default:
            break
        }
    }

    private func displayRows() -> [DiffDisplayRow] {
        if file.isBinary || file.tooLarge { return [] }
        guard let review = store.review else { return [] }
        return review.diffRows(for: file)
    }
}

/// Empty / binary / too-large detail state.
public struct EmptyStateView: View {
    public let icon: String
    public let title: String
    public let message: String

    public init(icon: String, title: String, message: String) {
        self.icon = icon
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diff-empty-state")
    }
}
