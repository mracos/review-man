import SwiftUI
import PRReviewKit

/// One diff line: fixed-width old/new gutters plus syntax-colored, word-level
/// highlighted content. Tokenization is demand-driven per realized line and
/// cached per (line, language, theme) in the store's `DiffLineCache`.
public struct DiffLineView: View {
    @ObservedObject public var store: ReviewSessionStore
    @ObservedObject private var hover: ReviewHoverModel
    public let file: DiffFile
    public let hunkIndex: Int
    public let lineIndex: Int
    /// Compact language identity for the cache key, resolved once per file
    /// (avoids a table scan + full Language hashing per line).
    public let languageID: Int?

    @Environment(\.colorScheme) private var colorScheme

    public init(store: ReviewSessionStore, file: DiffFile, hunkIndex: Int, lineIndex: Int, languageID: Int?) {
        self.store = store
        self.hover = store.hover
        self.file = file
        self.hunkIndex = hunkIndex
        self.lineIndex = lineIndex
        self.languageID = languageID
    }

    @ViewBuilder
    public var body: some View {
        if let diffLine = file.line(at: hunkIndex, lineIndex) {
            lineRow(diffLine)
        }
    }

    private func lineRow(_ diffLine: DiffLine) -> some View {
        let highContrast = AppearanceSettings.increasedContrast
        let palette = SemanticTheme.palette(for: colorScheme, increasedContrast: highContrast)
        let gutter = DiffAttributedStringBuilder.gutterText(for: diffLine, digits: file.gutterDigits)
        // The gutter text is `digits*2 + 3` characters; SF Mono's advance at
        // 12pt is ~0.6 × point size. The width MUST be in points — the old
        // `digits * 2 + 3` value was treated as points while the string is
        // that many *characters*, so the monospace gutter wrapped vertically
        // and inflated every row to ~45px.
        let gutterWidth = CGFloat(gutter.count) * 7.2

        // Rendered line from the per-window cache: tokenization + attributed
        // string building happen once per line per theme, so switching files
        // (even rapidly, in a large PR) renders the viewport from cache.
        let content = store.diffLineCache.attributedString(
            for: diffLine,
            languageID: languageID,
            palette: palette,
            isDark: colorScheme == .dark,
            highContrast: highContrast
        )

        return HStack(spacing: 0) {
            Text(gutter)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(palette.gutterForeground)
                .lineLimit(1)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.leading, 6)
                .background(palette.gutterBackground.opacity(0.5))
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        // Order matters: frame first so the background (and the hover /
        // selection overlay) spans the full row width like GitHub's diff,
        // not just the text's intrinsic width.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectionOrHoverBackground(for: diffLine, palette: palette))
        .contentShape(Rectangle())
        .onTapGesture { handleTap(hunkIndex: hunkIndex, lineIndex: lineIndex) }
        .onHover { hovering in
            // Hover lives on the dedicated hover model, so pointer movement
            // only re-renders diff rows — never the sidebar/header/editors.
            hover.rowID = hovering ? DiffRowID.line(
                file: file.path, hunk: hunkIndex, kind: diffLine.kind,
                old: diffLine.oldLine, new: diffLine.newLine
            ) : nil
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
            Button("Copy \(file.path):\(diffLine.newLine ?? diffLine.oldLine ?? 0)") {
                _ = store.copyLineToClipboard(file: file, hunkIndex: hunkIndex, lineIndex: lineIndex)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lineAccessibilityLabel(for: diffLine))
        .accessibilityIdentifier("diff-line-\(file.path)-h\(hunkIndex)-\(diffLine.oldLine ?? -1)-\(diffLine.newLine ?? -1)")
    }

    /// Selected rows win over hovered rows; hover uses a light overlay so it
    /// does not fight the kind background.
    private func selectionOrHoverBackground(for diffLine: DiffLine, palette: SemanticTheme.Palette) -> SwiftUI.Color {
        let id = DiffRowID.line(
            file: file.path, hunk: hunkIndex, kind: diffLine.kind,
            old: diffLine.oldLine, new: diffLine.newLine
        )
        if store.selection.rowID == id { return SwiftUI.Color.accentColor.opacity(0.18) }
        if hover.rowID == id { return SwiftUI.Color.gray.opacity(0.10) }
        return kindBackground(diffLine.kind, palette: palette)
    }

    /// One meaningful VoiceOver label per line.
    private func lineAccessibilityLabel(for diffLine: DiffLine) -> String {
        let kindWord: String
        switch diffLine.kind {
        case .added: kindWord = "Added"
        case .removed: kindWord = "Removed"
        case .context: kindWord = "Context"
        }
        let lineNumber = diffLine.newLine ?? diffLine.oldLine ?? 0
        return "\(kindWord) line \(lineNumber), \(file.path): \(diffLine.content)"
    }

    /// Click selects the line; Shift-click completes a range. Ranges are
    /// validated and either begin a draft or show an explanation.
    private func handleTap(hunkIndex: Int, lineIndex: Int) {
        DiffLineSelection.handleTap(store: store, file: file, hunkIndex: hunkIndex, lineIndex: lineIndex)
    }

    private func kindBackground(_ kind: DiffLine.Kind, palette: SemanticTheme.Palette) -> SwiftUI.Color {
        switch kind {
        case .added: return palette.addedBackground
        case .removed: return palette.removedBackground
        case .context: return .clear
        }
    }
}

/// Shared selection behavior for unified and side-by-side line cells.
@MainActor
enum DiffLineSelection {
    static func handleTap(store: ReviewSessionStore, file: DiffFile, hunkIndex: Int, lineIndex: Int) {
        guard let diffLine = file.line(at: hunkIndex, lineIndex) else { return }
        let isShift = NSEvent.modifierFlags.contains(.shift)
        if isShift, let startRow = store.selection.rowID {
            let end = (file, hunkIndex, lineIndex)
            var start: (file: DiffFile, hunkIndex: Int, lineIndex: Int)?
            if let position = store.linePosition(for: startRow, in: file) {
                start = (file, position.hunk, position.lineIndex)
            }
            let result = DraftRangeValidator().validate(start: start, end: end)
            switch result {
            case .single(let anchor):
                store.beginDraft(at: DraftStartAnchor(
                    path: anchor.path, side: anchor.side, line: anchor.line
                ))
            case .range(let anchor):
                store.beginDraft(at: DraftStartAnchor(
                    path: anchor.path, side: anchor.side, line: anchor.line,
                    startLine: anchor.startLine, startSide: anchor.startSide
                ))
            case .invalid(let reason):
                store.banner = SessionBanner(text: reason, isError: true)
            }
            store.selection.rowID = nil
        } else {
            store.selection.rowID = DiffRowID.line(
                file: file.path, hunk: hunkIndex, kind: diffLine.kind,
                old: diffLine.oldLine, new: diffLine.newLine
            )
        }
    }
}

/// A unified hunk header row.
public struct HunkHeaderView: View {
    public let hunk: DiffHunk
    /// Unchanged lines hidden above this hunk.
    public let hiddenAbove: Int
    /// Reveals hidden lines: `false` for one step, `true` for all of them.
    public let onExpand: ((Bool) -> Void)?

    public init(hunk: DiffHunk, hiddenAbove: Int = 0, onExpand: ((Bool) -> Void)? = nil) {
        self.hunk = hunk
        self.hiddenAbove = hiddenAbove
        self.onExpand = onExpand
    }

    public var body: some View {
        // The expand buttons lead, so they stay on screen in a side-by-side
        // pane whose rows are wider than the visible column.
        HStack(spacing: 10) {
            if hiddenAbove > 0, let onExpand {
                let step = min(ReviewSessionStore.contextExpansionStep, hiddenAbove)
                Button("Show \(step) more" as String) { onExpand(false) }
                    .help(Text(verbatim: "Reveal \(step) hidden lines above this change"))
                    .accessibilityIdentifier("hunk-expand-step")
                if hiddenAbove > step {
                    Button("Show all \(hiddenAbove)" as String) { onExpand(true) }
                        .accessibilityIdentifier("hunk-expand-all")
                }
            }
            Text(hunk.header)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SwiftUI.Color.gray.opacity(0.08))
        .accessibilityIdentifier("hunk-header")
    }
}

/// An inline thread card: active (accent), resolved (dimmed), or outdated
/// (under the outdated header). Reply and resolve controls (Phase 6).
public struct ThreadCardView: View {
    @ObservedObject public var store: ReviewSessionStore
    public let thread: PRThread

    public init(store: ReviewSessionStore, thread: PRThread) {
        self.store = store
        self.thread = thread
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accentColor)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    let root = thread.rootComment
                    Text("\(root?.author ?? "?") · \(root.map { timeAgo($0.createdAt) } ?? "")\(thread.isResolved ? " · resolved" : "")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(thread.isResolved ? .secondary : .primary)
                    ForEach(Array(thread.comments.enumerated()), id: \.offset) { _, comment in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(comment.author) · \(timeAgo(comment.createdAt))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(comment.body)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(4)
                        }
                    }
                    if !thread.isOutdated {
                        HStack(spacing: 10) {
                            Button("Reply") { store.beginReply(threadID: thread.id) }
                                .font(.caption2)
                                .accessibilityIdentifier("thread-reply-button-\(thread.id)")
                            Button(thread.isResolved ? "Unresolve" : "Resolve") {
                                store.toggleResolved(threadID: thread.id)
                            }
                            .font(.caption2)
                            .accessibilityIdentifier("thread-resolve-button-\(thread.id)")
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if store.replyEditors[thread.id] != nil {
                ReplyEditorView(store: store, threadID: thread.id)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if !thread.isOutdated {
                Button("Reply") { store.beginReply(threadID: thread.id) }
                Button(thread.isResolved ? "Unresolve" : "Resolve") {
                    store.toggleResolved(threadID: thread.id)
                }
            }
            if !thread.comments.isEmpty {
                Divider()
                ForEach(distinctAuthors, id: \.self) { author in
                    Button("Hide comments by \(author)") {
                        store.hideReviewer(author)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread-card-\(thread.id)")
    }

    /// Every distinct author in the thread, alphabetized: hiding follows any
    /// participant, so each gets a hide action in the context menu.
    private var distinctAuthors: [String] {
        Array(Set(thread.comments.map(\.author)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var accentColor: SwiftUI.Color {
        thread.isResolved ? .gray : (thread.isOutdated ? .secondary : .purple)
    }

    /// Cached formatter: `RelativeDateTimeFormatter` construction is expensive,
    /// and thread cards render one relative timestamp per comment.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private func timeAgo(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Inline reply editor for one thread. The text lives in local `@State` so
/// keystrokes never publish the session store; it is committed to the store
/// only when Send/Retry is pressed (and the store retains the body across a
/// failed send so retry keeps the text).
private struct ReplyEditorView: View {
    @ObservedObject public var store: ReviewSessionStore
    public let threadID: String

    @State private var text: String = ""

    public init(store: ReviewSessionStore, threadID: String) {
        self.store = store
        self.threadID = threadID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 48)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                .accessibilityIdentifier("reply-editor-\(threadID)")
            HStack(spacing: 8) {
                if retryFailed {
                    Label("Failed — Retry keeps your text", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Spacer()
                if retryFailed {
                    Button("Edit") {
                        var e = store.replyEditors[threadID]
                        e?.retryFailed = false
                        store.replyEditors[threadID] = e
                    }
                    .font(.caption2)
                }
                Button(retryFailed ? "Retry" : "Send") {
                    commitText()
                    store.sendReply(threadID: threadID)
                }
                .buttonStyle(.borderedProminent)
                .font(.caption2)
                .accessibilityIdentifier("reply-send-button-\(threadID)")
                Button("Cancel") { store.cancelReply(threadID: threadID) }
                    .font(.caption2)
            }
        }
        .padding(.leading, 9)
        .onAppear {
            // Fresh editor: seed from the store's (empty) body. On a failed
            // send the editor never disappears, so @State keeps the typed text.
            if text.isEmpty {
                text = store.replyEditors[threadID]?.body ?? ""
            }
        }
    }

    private var retryFailed: Bool {
        store.replyEditors[threadID]?.retryFailed ?? false
    }

    private func commitText() {
        var editor = store.replyEditors[threadID]
        editor?.body = text
        store.replyEditors[threadID] = editor
    }
}
