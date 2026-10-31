import AppKit
import SwiftUI
import PRReviewKit

/// A two-column representation of a file diff. Old and new lines share a row,
/// so modified runs stay easy to scan while comments remain attached below the
/// line they annotate.
struct SideBySideDiffView: View {
    @ObservedObject var store: ReviewSessionStore
    let file: DiffFile
    @State private var scrollCoordinator = SideBySideScrollCoordinator()
    private let languageID: Int?

    init(store: ReviewSessionStore, file: DiffFile) {
        self.store = store
        self.file = file
        languageID = Highlighter.languageID(for: file.path)
    }

    var body: some View {
        let displayRows = store.review?.diffRows(for: file) ?? []
        let rows = SideBySideDiffLayout.rows(file: file, displayRows: displayRows)
        GeometryReader { geometry in
            let paneWidth = max(1, (geometry.size.width - 1) / 2)
            HStack(alignment: .top, spacing: 0) {
                SideBySideDiffPane(
                    store: store,
                    file: file,
                    rows: rows,
                    languageID: languageID,
                    side: .old,
                    viewportWidth: paneWidth,
                    scrollCoordinator: scrollCoordinator
                )
                Divider().frame(width: 1)
                SideBySideDiffPane(
                    store: store,
                    file: file,
                    rows: rows,
                    languageID: languageID,
                    side: .new,
                    viewportWidth: paneWidth,
                    scrollCoordinator: scrollCoordinator
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .accessibilityIdentifier("side-by-side-diff-pane")
        .background(SideBySideKeyboardMonitor(
            onEscape: handleExitCommand,
            onPageScroll: { direction in scrollCoordinator.scrollByPage(direction) }
        ))
    }

    /// Mirror the AppKit unified surface: Escape closes an active editor or
    /// banner first, then returns the reviewer to the Canvas.
    private func handleExitCommand() {
        guard !store.cancelTransientInteraction() else { return }
        NotificationCenter.default.post(name: .reviewReturnToCanvasRequest, object: store)
    }
}

/// Handles keyboard surface commands for the side-by-side panes: Escape exits
/// toward the Canvas, and Page Up / Page Down page both columns together.
/// Scrolling goes through the shared coordinator so it works regardless of
/// which view currently holds keyboard focus.
private struct SideBySideKeyboardMonitor: NSViewRepresentable {
    let onEscape: () -> Void
    let onPageScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape, onPageScroll: onPageScroll)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
        context.coordinator.onPageScroll = onPageScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeEventMonitor()
    }

    final class Coordinator {
        var onEscape: () -> Void
        var onPageScroll: (CGFloat) -> Void
        private weak var view: NSView?
        private var eventMonitor: Any?

        init(onEscape: @escaping () -> Void, onPageScroll: @escaping (CGFloat) -> Void) {
            self.onEscape = onEscape
            self.onPageScroll = onPageScroll
        }

        deinit {
            removeEventMonitor()
        }

        func install(on view: NSView) {
            self.view = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let window = self.view?.window,
                      event.window === window else {
                    return event
                }
                // Leave text entry (draft editors, search fields) untouched;
                // Page keys keep their native caret-movement meaning there.
                if window.firstResponder is NSTextView, event.keyCode != 53 {
                    return event
                }
                switch event.keyCode {
                case 53:
                    self.onEscape()
                    return nil
                case 121:
                    self.onPageScroll(1)
                    return nil
                case 116:
                    self.onPageScroll(-1)
                    return nil
                default:
                    return event
                }
            }
        }

        func removeEventMonitor() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

/// One fixed-width diff column with its own horizontal and vertical scrolling.
private struct SideBySideDiffPane: View {
    @ObservedObject var store: ReviewSessionStore
    let file: DiffFile
    let rows: [SideBySideDiffRow]
    let languageID: Int?
    let side: SideBySideDiffLineCell.Side
    let viewportWidth: CGFloat
    let scrollCoordinator: SideBySideScrollCoordinator

    var body: some View {
        let contentWidth = max(SideBySideDiffLayout.minimumColumnWidth(for: file), viewportWidth)
        VStack(spacing: 0) {
            Text(side.lineLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 26, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityAddTraits(.isHeader)

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row, contentWidth: contentWidth)
                            .id(row.id)
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .background(SideBySideScrollBridge(side: side, coordinator: scrollCoordinator))
            }
        }
        .frame(width: viewportWidth, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityLabel("\(side.lineLabel) diff pane")
    }

    @ViewBuilder
    private func rowView(_ row: SideBySideDiffRow, contentWidth: CGFloat) -> some View {
        switch row {
        case .hunk(let hunkIndex):
            HunkHeaderView(hunk: file.hunks[hunkIndex])
                .frame(width: contentWidth, alignment: .leading)
        case .lines(let hunkIndex, let oldLineIndex, let newLineIndex):
            lineCell(
                hunkIndex: hunkIndex,
                lineIndex: side == .old ? oldLineIndex : newLineIndex,
                contentWidth: contentWidth
            )
        case .supplementary(let displayRow):
            supplementaryRow(displayRow, contentWidth: contentWidth)
        }
    }

    @ViewBuilder
    private func lineCell(hunkIndex: Int, lineIndex: Int?, contentWidth: CGFloat) -> some View {
        if let lineIndex, let line = file.line(at: hunkIndex, lineIndex) {
            SideBySideDiffLineCell(
                store: store,
                file: file,
                line: line,
                hunkIndex: hunkIndex,
                lineIndex: lineIndex,
                languageID: languageID,
                side: side
            )
            .frame(width: contentWidth, height: 18, alignment: .leading)
        } else {
            Color.clear
                .frame(width: contentWidth, height: 18)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func supplementaryRow(_ displayRow: DiffDisplayRow, contentWidth: CGFloat) -> some View {
        switch displayRow.row {
        case .thread, .draft, .outdatedHeader, .orphanedHeader, .empty:
            if side == .new {
                DiffRowView(store: store, file: file, displayRow: displayRow, languageID: languageID)
                    .frame(width: contentWidth, alignment: .leading)
            } else {
                // Reserve the same height as the right-side card so the two
                // columns start every following diff row at the same Y value.
                DiffRowView(store: store, file: file, displayRow: displayRow, languageID: languageID)
                    .frame(width: contentWidth, alignment: .leading)
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        case .hunkHeader, .line:
            EmptyView()
        }
    }
}

private struct SideBySideDiffLineCell: View {
    @Environment(\.diffFontSize) private var diffFontSize
    enum Side {
        case old
        case new

        var lineLabel: String {
            self == .old ? "Before" : "After"
        }
    }

    @ObservedObject var store: ReviewSessionStore
    @ObservedObject private var hover: ReviewHoverModel
    let file: DiffFile
    let line: DiffLine
    let hunkIndex: Int
    let lineIndex: Int
    let languageID: Int?
    let side: Side

    @Environment(\.colorScheme) private var colorScheme

    init(
        store: ReviewSessionStore,
        file: DiffFile,
        line: DiffLine,
        hunkIndex: Int,
        lineIndex: Int,
        languageID: Int?,
        side: Side
    ) {
        self.store = store
        hover = store.hover
        self.file = file
        self.line = line
        self.hunkIndex = hunkIndex
        self.lineIndex = lineIndex
        self.languageID = languageID
        self.side = side
    }

    var body: some View {
        let palette = SemanticTheme.palette(
            for: colorScheme,
            increasedContrast: AppearanceSettings.increasedContrast
        )
        let content = store.diffLineCache.attributedString(
            for: line,
            languageID: languageID,
            palette: palette,
            isDark: colorScheme == .dark,
            highContrast: AppearanceSettings.increasedContrast
        )
        HStack(spacing: 0) {
            Text(lineNumberText)
                .font(.system(size: diffFontSize, design: .monospaced))
                .foregroundStyle(palette.gutterForeground)
                .lineLimit(1)
                .frame(width: 44 * diffFontSize / DiffTextSize.defaultSize, alignment: .trailing)
                .padding(.trailing, 8)
                .background(palette.gutterBackground.opacity(0.5))
            Text(content)
                .font(.system(size: diffFontSize, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor(palette: palette))
        .contentShape(Rectangle())
        .onTapGesture { DiffLineSelection.handleTap(store: store, file: file, hunkIndex: hunkIndex, lineIndex: lineIndex) }
        .onHover { hovering in
            hover.rowID = hovering ? rowID : nil
        }
        .contextMenu {
            Button("Comment") {
                if let anchor = DraftRangeValidator.anchor(for: file, hunkIndex: hunkIndex, lineIndex: lineIndex) {
                    store.beginDraft(at: DraftStartAnchor(
                        path: anchor.path, side: anchor.side, line: anchor.line,
                        startLine: anchor.startLine, startSide: anchor.startSide
                    ))
                }
            }
            Button("Copy \(file.path):\(line.newLine ?? line.oldLine ?? 0)") {
                _ = store.copyLineToClipboard(file: file, hunkIndex: hunkIndex, lineIndex: lineIndex)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(side.lineLabel), \(lineAccessibilityLabel)")
        .accessibilityIdentifier("side-by-side-\(side.lineLabel.lowercased())-\(file.path)-h\(hunkIndex)-\(line.oldLine ?? -1)-\(line.newLine ?? -1)")
    }

    private var rowID: DiffRowID {
        DiffRowID.line(
            file: file.path,
            hunk: hunkIndex,
            kind: line.kind,
            old: line.oldLine,
            new: line.newLine
        )
    }

    private var lineNumberText: String {
        let lineNumber = side == .old ? line.oldLine : line.newLine
        return lineNumber.map(String.init) ?? ""
    }

    private var lineAccessibilityLabel: String {
        let kind: String
        switch line.kind {
        case .added: kind = "Added"
        case .removed: kind = "Removed"
        case .context: kind = "Context"
        }
        let lineNumber = side == .old ? line.oldLine : line.newLine
        return "\(kind) line \(lineNumber ?? 0), \(file.path): \(line.content)"
    }

    private func backgroundColor(palette: SemanticTheme.Palette) -> Color {
        if store.selection.rowID == rowID { return .accentColor.opacity(0.18) }
        if hover.rowID == rowID { return .gray.opacity(0.10) }
        switch line.kind {
        case .added: return palette.addedBackground
        case .removed: return palette.removedBackground
        case .context: return .clear
        }
    }
}


/// Keeps both independently scrollable panes aligned. AppKit exposes the
/// scroll view's clip bounds, which SwiftUI does not publish continuously.
private final class SideBySideScrollCoordinator {
    private weak var oldScrollView: NSScrollView?
    private weak var newScrollView: NSScrollView?
    private var oldBoundsObserver: NSObjectProtocol?
    private var newBoundsObserver: NSObjectProtocol?
    private var isSynchronizing = false

    deinit {
        removeObserver(for: .old)
        removeObserver(for: .new)
    }

    func register(_ scrollView: NSScrollView, for side: SideBySideDiffLineCell.Side) {
        guard self.scrollView(for: side) !== scrollView else { return }
        removeObserver(for: side)
        setScrollView(scrollView, for: side)
        scrollView.contentView.postsBoundsChangedNotifications = true

        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self, weak scrollView] _ in
            guard let scrollView else { return }
            self?.synchronize(from: side, source: scrollView)
        }
        setObserver(observer, for: side)

        // Both panes describe the same paired rows. When one becomes available
        // after the other, inherit its current position rather than jumping it.
        if let oldScrollView {
            synchronize(from: .old, source: oldScrollView)
        }
    }

    /// Pages the panes by one viewport height. `direction` is +1 (down) or
    /// -1 (up). The bounds-change notification fired here makes the
    /// coordinator mirror the movement onto the opposite pane.
    func scrollByPage(_ direction: CGFloat) {
        guard let source = oldScrollView ?? newScrollView else { return }
        let clip = source.contentView
        let contentHeight = source.documentView?.frame.size.height ?? 0
        let viewport = clip.bounds.size.height
        guard contentHeight > viewport else { return }
        let newY = min(max(0, clip.bounds.origin.y + direction * viewport), contentHeight - viewport)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: newY))
        source.reflectScrolledClipView(clip)
    }

    func unregister(_ scrollView: NSScrollView, for side: SideBySideDiffLineCell.Side) {
        guard self.scrollView(for: side) === scrollView else { return }
        removeObserver(for: side)
        setScrollView(nil, for: side)
    }

    private func synchronize(from side: SideBySideDiffLineCell.Side, source: NSScrollView) {
        guard !isSynchronizing, let target = scrollView(for: opposite(of: side)) else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }

        let sourceOrigin = source.contentView.bounds.origin
        let viewport = target.contentView.bounds.size
        let contentSize = target.documentView?.frame.size ?? .zero
        let targetOrigin = NSPoint(
            x: min(max(0, sourceOrigin.x), max(0, contentSize.width - viewport.width)),
            y: min(max(0, sourceOrigin.y), max(0, contentSize.height - viewport.height))
        )
        target.contentView.scroll(to: targetOrigin)
        target.reflectScrolledClipView(target.contentView)
    }

    private func opposite(of side: SideBySideDiffLineCell.Side) -> SideBySideDiffLineCell.Side {
        side == .old ? .new : .old
    }

    private func scrollView(for side: SideBySideDiffLineCell.Side) -> NSScrollView? {
        side == .old ? oldScrollView : newScrollView
    }

    private func setScrollView(_ scrollView: NSScrollView?, for side: SideBySideDiffLineCell.Side) {
        if side == .old {
            oldScrollView = scrollView
        } else {
            newScrollView = scrollView
        }
    }

    private func setObserver(_ observer: NSObjectProtocol, for side: SideBySideDiffLineCell.Side) {
        if side == .old {
            oldBoundsObserver = observer
        } else {
            newBoundsObserver = observer
        }
    }

    private func removeObserver(for side: SideBySideDiffLineCell.Side) {
        let observer = side == .old ? oldBoundsObserver : newBoundsObserver
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        if side == .old {
            oldBoundsObserver = nil
        } else {
            newBoundsObserver = nil
        }
    }
}

/// Locates the AppKit scroll view backing one SwiftUI pane and hands it to the
/// shared synchronizer. It is non-interactive and has no accessibility role.
private struct SideBySideScrollBridge: NSViewRepresentable {
    let side: SideBySideDiffLineCell.Side
    let coordinator: SideBySideScrollCoordinator

    func makeCoordinator() -> BridgeCoordinator {
        BridgeCoordinator(side: side, scrollCoordinator: coordinator)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        context.coordinator.connect(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.connect(nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: BridgeCoordinator) {
        coordinator.disconnect()
    }

    final class BridgeCoordinator {
        private let side: SideBySideDiffLineCell.Side
        private let scrollCoordinator: SideBySideScrollCoordinator
        private weak var scrollView: NSScrollView?

        init(side: SideBySideDiffLineCell.Side, scrollCoordinator: SideBySideScrollCoordinator) {
            self.side = side
            self.scrollCoordinator = scrollCoordinator
        }

        func connect(_ view: NSView) {
            guard let scrollView = view.enclosingScrollView else {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.connect(view)
                }
                return
            }
            self.scrollView = scrollView
            scrollCoordinator.register(scrollView, for: side)
        }

        func disconnect() {
            guard let scrollView else { return }
            scrollCoordinator.unregister(scrollView, for: side)
        }
    }
}
