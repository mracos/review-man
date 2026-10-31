import SwiftUI
import PRReviewKit

/// Dispatches one core `Row` to its dedicated view. No business logic here —
/// this is the single seam where Phase 6 adds selection backgrounds and inline
/// editors.
public struct DiffRowView: View {
    @ObservedObject public var store: ReviewSessionStore
    public let file: DiffFile
    public let displayRow: DiffDisplayRow
    /// Compact language identity, resolved once per file in `DiffView`.
    public let languageID: Int?

    public init(store: ReviewSessionStore, file: DiffFile, displayRow: DiffDisplayRow, languageID: Int?) {
        self.store = store
        self.file = file
        self.displayRow = displayRow
        self.languageID = languageID
    }

    public var body: some View {
        VStack(spacing: 0) {
            rowContent
            if let editor = store.draftEditor, isEditorForThisRow {
                DraftEditorView(store: store, editor: editor)
                    .padding(.leading, gutterOffset)
            }
        }
    }

    /// The inline editor appears below its anchor line (or the draft card it
    /// is editing).
    private var isEditorForThisRow: Bool {
        guard let editor = store.draftEditor else { return false }
        if editor.draftID != nil {
            // Editing an existing draft: expand that draft's card.
            if case .draft(let id) = displayRow.row { return id == editor.draftID }
            return false
        }
        guard case .line(let hunkIndex, let lineIndex) = displayRow.row,
              hunkIndex < file.hunks.count, lineIndex < file.hunks[hunkIndex].lines.count else {
            return false
        }
        let line = file.hunks[hunkIndex].lines[lineIndex]
        let lineNum = editor.side == "LEFT" ? line.oldLine : line.newLine
        return editor.path == file.path && editor.line == lineNum
    }

    private var gutterOffset: CGFloat { 150 }

    @ViewBuilder
    private var rowContent: some View {
        switch displayRow.row {
        case .hunkHeader(let hunkIndex):
            HunkHeaderView(hunk: file.hunks[hunkIndex], hiddenAbove: file.hiddenLinesAbove(hunk: hunkIndex)) { all in
                store.expandContext(path: file.path, aboveHunk: hunkIndex, all: all)
            }
        case .line(let hunkIndex, let lineIndex):
            DiffLineView(store: store, file: file, hunkIndex: hunkIndex, lineIndex: lineIndex, languageID: languageID)
        case .thread(let threadID):
            if let thread = store.review?.threadByID[threadID] {
                ThreadCardView(store: store, thread: thread)
            } else {
                EmptyView()
            }
        case .draft(let draftID):
            if let draft = store.review?.draftByID[draftID] {
                draftCard(draft)
            } else {
                EmptyView()
            }
        case .outdatedHeader:
            Text("Outdated comments")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(SwiftUI.Color.gray.opacity(0.08))
        case .orphanedHeader:
            Text("Orphaned drafts — not submitted")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(SwiftUI.Color.orange.opacity(0.08))
        case .empty:
            Text("(no changes)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(6)
        }
    }

    private func draftCard(_ draft: DraftComment) -> some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(draft.isOrphaned ? SwiftUI.Color.orange : SwiftUI.Color.purple)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.isOrphaned ? "You · orphaned draft · \(draft.path):\(draft.line)" : "You · draft \(draft.side == "LEFT" ? "(left)" : "")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(draft.isOrphaned ? SwiftUI.Color.orange : SwiftUI.Color.purple)
                Text(draft.body)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                HStack(spacing: 10) {
                    Button("Edit") { store.editDraft(draft) }
                        .font(.caption2)
                        .accessibilityIdentifier("draft-edit-button-\(draft.id.uuidString)")
                    Button("Delete") { store.deleteDraft(draft) }
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("draft-delete-button-\(draft.id.uuidString)")
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Edit") { store.editDraft(draft) }
            Button("Delete") { store.deleteDraft(draft) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("draft-card-\(draft.id.uuidString)")
    }
}
