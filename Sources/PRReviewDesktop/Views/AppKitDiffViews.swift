import AppKit
import Foundation
import SwiftUI
import PRReviewKit

/// Renderer choices. The custom AppKit surface is the default diff renderer;
/// `--swiftui-diff` keeps an explicit fallback for comparison and recovery.
public enum AppKitDiffSpike {
    public enum Mode {
        case disabled
        case surface
    }

    public static var mode: Mode {
        if ProcessInfo.processInfo.arguments.contains("--swiftui-diff") {
            return .disabled
        }
        // --appkit-diff remains accepted for existing profiling scripts, but
        // the surface is now the default for every eligible textual file.
        return .surface
    }
}

/// SwiftUI bridge for the custom NSScrollView/drawing-surface prototype.
public struct AppKitDiffSurfaceView: NSViewRepresentable {
    @ObservedObject public var store: ReviewSessionStore
    public let file: DiffFile
    public let fontSize: CGFloat

    public init(store: ReviewSessionStore, file: DiffFile, fontSize: CGFloat = 12) {
        self.store = store
        self.file = file
        self.fontSize = fontSize
    }

    public func makeNSView(context: Context) -> AppKitDiffSurfaceContainer {
        AppKitDiffSurfaceContainer(store: store, snapshot: snapshot)
    }

    public func updateNSView(_ nsView: AppKitDiffSurfaceContainer, context: Context) {
        nsView.reload(store: store, snapshot: snapshot)
    }

    private var snapshot: AppKitDiffRenderSnapshot {
        AppKitDiffRenderSnapshot(
            file: file,
            rows: store.review?.diffRows(for: file) ?? [],
            metrics: .forFontSize(fontSize)
        )
    }
}

// MARK: - Shared row drawing

private struct AppKitDiffPalette {
    let addedForeground: NSColor
    let removedForeground: NSColor
    let contextForeground: NSColor
    let addedBackground: NSColor
    let removedBackground: NSColor
    let wordAddedBackground: NSColor
    let wordRemovedBackground: NSColor
    let gutterForeground: NSColor
    let gutterBackground: NSColor
    let hunkHeaderForeground: NSColor
    let hunkHeaderBackground: NSColor
    let selectionBackground: NSColor
    let hoverBackground: NSColor
    let keyword: NSColor
    let string: NSColor
    let comment: NSColor
    let number: NSColor
    let type: NSColor
    let directive: NSColor

    func foreground(for token: TokenKind) -> NSColor {
        switch token {
        case .plain: return contextForeground
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .number: return number
        case .type: return type
        case .directive: return directive
        }
    }

    static func make(
        isDark: Bool,
        highContrast: Bool,
        reduceTransparency: Bool = AppearanceSettings.reduceTransparency
    ) -> AppKitDiffPalette {
        if isDark {
            return AppKitDiffPalette(
                addedForeground: color(0.55, 0.85, 0.55),
                removedForeground: color(0.95, 0.50, 0.50),
                contextForeground: color(0.85, 0.85, 0.85),
                addedBackground: color(highContrast ? 0.06 : 0.10, highContrast ? 0.25 : 0.22, highContrast ? 0.06 : 0.10),
                removedBackground: color(highContrast ? 0.30 : 0.25, highContrast ? 0.08 : 0.12, highContrast ? 0.08 : 0.12),
                wordAddedBackground: color(0.15, 0.40, 0.15),
                wordRemovedBackground: color(0.45, 0.15, 0.15),
                gutterForeground: color(0.55, 0.55, 0.55),
                gutterBackground: color(0.12, 0.12, 0.12),
                hunkHeaderForeground: color(0.55, 0.75, 0.95),
                hunkHeaderBackground: color(0.10, 0.16, 0.25),
                selectionBackground: reduceTransparency
                    ? color(0.20, 0.38, 0.65)
                    : NSColor.controlAccentColor.withAlphaComponent(highContrast ? 0.32 : 0.18),
                hoverBackground: reduceTransparency
                    ? color(0.23, 0.23, 0.23)
                    : NSColor.white.withAlphaComponent(highContrast ? 0.12 : 0.07),
                keyword: color(0.85, 0.60, 0.95),
                string: color(0.95, 0.65, 0.45),
                comment: color(0.55, 0.55, 0.55),
                number: color(0.60, 0.75, 0.95),
                type: color(0.55, 0.85, 0.80),
                directive: color(0.90, 0.70, 0.45)
            )
        }
        return AppKitDiffPalette(
            addedForeground: color(0.05, 0.45, 0.15),
            removedForeground: color(0.75, 0.10, 0.10),
            contextForeground: highContrast ? .black : color(0.20, 0.20, 0.20),
            addedBackground: color(highContrast ? 0.80 : 0.86, highContrast ? 0.92 : 0.95, highContrast ? 0.80 : 0.86),
            removedBackground: color(highContrast ? 0.96 : 0.98, highContrast ? 0.82 : 0.88, highContrast ? 0.82 : 0.88),
            wordAddedBackground: color(0.70, 0.90, 0.70),
            wordRemovedBackground: color(0.96, 0.70, 0.70),
            gutterForeground: color(0.45, 0.45, 0.45),
            gutterBackground: color(0.94, 0.94, 0.94),
            hunkHeaderForeground: color(0.25, 0.40, 0.60),
            hunkHeaderBackground: color(0.90, 0.94, 0.98),
            selectionBackground: reduceTransparency
                ? color(0.74, 0.84, 0.98)
                : NSColor.controlAccentColor.withAlphaComponent(highContrast ? 0.28 : 0.16),
            hoverBackground: reduceTransparency
                ? color(0.86, 0.86, 0.86)
                : NSColor.black.withAlphaComponent(highContrast ? 0.10 : 0.05),
            keyword: color(0.55, 0.20, 0.70),
            string: color(0.55, 0.20, 0.10),
            comment: color(0.45, 0.45, 0.45),
            number: color(0.10, 0.35, 0.70),
            type: color(0.15, 0.45, 0.50),
            directive: color(0.60, 0.35, 0.10)
        )
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }
}

private final class AppKitDiffTextCache {
    private var appearanceKey: String?
    private var values: [DiffRowID: NSAttributedString] = [:]

    func invalidate() {
        appearanceKey = nil
        values.removeAll(keepingCapacity: true)
    }

    func value(
        for rowID: DiffRowID,
        line: DiffLine,
        languageID: Int?,
        palette: AppKitDiffPalette,
        font: NSFont,
        appearanceKey: String
    ) -> NSAttributedString {
        let key = "\(appearanceKey)|\(font.pointSize)"
        if self.appearanceKey != key {
            self.appearanceKey = key
            values.removeAll(keepingCapacity: true)
        }
        if let value = values[rowID] { return value }
        let value = AppKitDiffTextBuilder.build(line: line, languageID: languageID, palette: palette, font: font)
        values[rowID] = value
        return value
    }
}

private enum AppKitDiffTextBuilder {
    static func build(line: DiffLine, languageID: Int?, palette: AppKitDiffPalette, font: NSFont) -> NSAttributedString {
        let baseColor: NSColor
        switch line.kind {
        case .added: baseColor = palette.addedForeground
        case .removed: baseColor = palette.removedForeground
        case .context: baseColor = palette.contextForeground
        }
        let result = NSMutableAttributedString(
            string: line.content,
            attributes: [.font: font, .foregroundColor: baseColor]
        )
        let language = languageID.flatMap { Highlighter.language(forID: $0) }
        let tokens = Highlighter.tokenize(line.content, language)
        for token in tokens {
            guard let range = nsRange(token.range, in: line.content) else { continue }
            result.addAttribute(.foregroundColor, value: palette.foreground(for: token.kind), range: range)
        }
        if let emphasis = line.emphasis, let range = nsRange(emphasis, in: line.content) {
            let color = line.kind == .added ? palette.wordAddedBackground : palette.wordRemovedBackground
            result.addAttribute(.backgroundColor, value: color, range: range)
        }
        return result
    }

    private static func nsRange(_ range: Range<Int>, in content: String) -> NSRange? {
        guard range.lowerBound >= 0, range.upperBound <= content.count else { return nil }
        let indexes = Array(content.indices) + [content.endIndex]
        guard range.upperBound < indexes.count else { return nil }
        return NSRange(indexes[range.lowerBound]..<indexes[range.upperBound], in: content)
    }
}

/// The diff's fonts at one size, built once per draw pass.
private struct AppKitDiffFonts {
    let code: NSFont
    let header: NSFont

    init(size: CGFloat) {
        code = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        header = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
    }
}

private enum AppKitDiffRowRenderer {
    static func draw(
        row: DiffDisplayRow,
        file: DiffFile,
        rect: NSRect,
        cache: AppKitDiffTextCache,
        languageID: Int?,
        palette: AppKitDiffPalette,
        fonts: AppKitDiffFonts,
        characterWidth: CGFloat,
        appearanceKey: String,
        selected: Bool = false,
        hovered: Bool = false
    ) {
        switch row.row {
        case .hunkHeader(let hunkIndex):
            guard hunkIndex < file.hunks.count else { return }
            palette.hunkHeaderBackground.setFill()
            rect.fill()
            // The expand hint leads and the header follows it, so the two
            // never overlap however large the text gets.
            var textRect = rect.insetBy(dx: 8, dy: 3)
            let hidden = file.hiddenLinesAbove(hunk: hunkIndex)
            if hidden > 0 {
                let step = min(ReviewSessionStore.contextExpansionStep, hidden)
                let hint = hidden > step
                    ? "Show \(step) more of \(hidden) (Option: all)"
                    : "Show \(hidden) hidden lines"
                let hintWidth = (hint as NSString).size(withAttributes: [.font: fonts.header]).width.rounded(.up)
                drawText(hint, in: textRect, font: fonts.header, color: .linkColor)
                textRect.origin.x += hintWidth + 16
                textRect.size.width = max(0, textRect.width - hintWidth - 16)
            }
            drawText(
                file.hunks[hunkIndex].header,
                in: textRect,
                font: fonts.header,
                color: palette.hunkHeaderForeground
            )
        case .line(let hunkIndex, let lineIndex):
            guard let line = file.line(at: hunkIndex, lineIndex) else { return }
            switch line.kind {
            case .added: palette.addedBackground.setFill()
            case .removed: palette.removedBackground.setFill()
            case .context: NSColor.clear.setFill()
            }
            rect.fill()
            if selected {
                palette.selectionBackground.setFill()
                rect.fill()
            } else if hovered {
                palette.hoverBackground.setFill()
                rect.fill()
            }

            let gutterWidth = CGFloat(file.gutterDigits * 2 + 3) * characterWidth + 14
            palette.gutterBackground.withAlphaComponent(0.5).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: gutterWidth, height: rect.height).fill()
            drawText(
                DiffAttributedStringBuilder.gutterText(for: line, digits: file.gutterDigits),
                in: NSRect(x: rect.minX + 6, y: rect.minY + 2, width: gutterWidth - 8, height: rect.height - 4),
                font: fonts.code,
                color: palette.gutterForeground,
                alignment: .right
            )
            let text = cache.value(
                for: row.id,
                line: line,
                languageID: languageID,
                palette: palette,
                font: fonts.code,
                appearanceKey: appearanceKey
            )
            text.draw(
                with: NSRect(
                    x: rect.minX + gutterWidth + 8,
                    y: rect.minY + 2,
                    width: max(0, rect.width - gutterWidth - 16),
                    height: rect.height - 4
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        case .thread(let threadID):
            drawMarkerRow("Comment thread · \(threadID)", in: rect, color: palette.hunkHeaderForeground, font: fonts.header)
        case .draft(let draftID):
            drawMarkerRow("Draft comment · \(draftID.uuidString.prefix(8))", in: rect, color: palette.hunkHeaderForeground, font: fonts.header)
        case .outdatedHeader:
            drawMarkerRow("Outdated comments", in: rect, color: palette.comment, font: fonts.header)
        case .orphanedHeader:
            drawMarkerRow("Orphaned drafts", in: rect, color: palette.removedForeground, font: fonts.header)
        case .empty:
            drawMarkerRow("No changes", in: rect, color: palette.comment, font: fonts.header)
        }
    }

    private static func drawMarkerRow(_ text: String, in rect: NSRect, color: NSColor, font: NSFont) {
        NSColor.controlBackgroundColor.setFill()
        rect.fill()
        drawText(text, in: rect.insetBy(dx: 8, dy: 3), font: font, color: color)
    }

    private static func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        NSString(string: text).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }
}

private func appKitAppearanceKey(for appearance: NSAppearance) -> (isDark: Bool, key: String) {
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let contrast = AppearanceSettings.increasedContrast
    let reduceTransparency = AppearanceSettings.reduceTransparency
    return (dark, "\(dark)-\(contrast)-\(reduceTransparency)")
}

// MARK: - Accessibility

private final class AppKitDiffAccessibilityRow: NSAccessibilityElement {
    weak var owner: AppKitDiffSurfaceNSView?
    let rowID: DiffRowID
    var frameInParent = NSRect.zero
    var title = ""
    var value: String?
    var selected = false

    init(owner: AppKitDiffSurfaceNSView, rowID: DiffRowID, identifier: String) {
        self.owner = owner
        self.rowID = rowID
        super.init()
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityIdentifier(identifier)
        setAccessibilityEnabled(true)
    }

    override func accessibilityFrame() -> NSRect {
        owner.map { NSAccessibility.screenRect(fromView: $0, rect: frameInParent) } ?? .zero
    }

    override func accessibilityParent() -> Any? { owner }

    override func accessibilityLabel() -> String? { title }

    override func accessibilityValue() -> Any? { value }

    override func isAccessibilitySelected() -> Bool { selected }

    override func accessibilityPerformPress() -> Bool {
        owner?.activateAccessibilityRow(rowID)
        return true
    }
}

// MARK: - Visible SwiftUI comment overlays

/// Hosts only interactive rows that are near the viewport. Code lines remain
/// in the AppKit drawing surface; comment cards and editors keep their
/// existing SwiftUI behavior while the large-file path avoids a full SwiftUI
/// row tree.
private struct AppKitDiffCommentOverlayView: View {
    @ObservedObject var store: ReviewSessionStore
    let file: DiffFile
    let displayRow: DiffDisplayRow
    let languageID: Int?

    @ViewBuilder
    var body: some View {
        switch displayRow.row {
        case .thread, .draft:
            DiffRowView(
                store: store,
                file: file,
                displayRow: displayRow,
                languageID: languageID
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .line:
            if let editor = store.draftEditor, isEditorForLine(editor) {
                DraftEditorView(store: store, editor: editor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            EmptyView()
        }
    }

    private func isEditorForLine(_ editor: DraftEditorState) -> Bool {
        guard case .line(let hunkIndex, let lineIndex) = displayRow.row,
              let line = file.line(at: hunkIndex, lineIndex) else {
            return false
        }
        let lineNumber = editor.side == "LEFT" ? line.oldLine : line.newLine
        return editor.path == file.path && editor.line == lineNumber
    }
}

// MARK: - Drawing surface prototype

public final class AppKitDiffSurfaceContainer: NSView {
    private let scrollView: NSScrollView
    private let surface: AppKitDiffSurfaceNSView

    public init(store: ReviewSessionStore, snapshot: AppKitDiffRenderSnapshot) {
        scrollView = NSScrollView(frame: .zero)
        surface = AppKitDiffSurfaceNSView(store: store, snapshot: snapshot)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(scrollView)
        scrollView.documentView = surface
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        surface.updateViewportWidth(900)
        setAccessibilityIdentifier("appkit-diff-surface")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        surface.updateViewportWidth(scrollView.contentView.bounds.width)
    }

    public func reload(store: ReviewSessionStore, snapshot: AppKitDiffRenderSnapshot) {
        surface.reload(store: store, snapshot: snapshot)
        needsLayout = true
    }

    public func scroll(to rowID: DiffRowID, alignment: CGFloat = 0.5) {
        surface.scroll(to: rowID, alignment: alignment)
    }
}

private final class AppKitDiffSurfaceNSView: NSView {
    private weak var store: ReviewSessionStore?
    private var baseSnapshot: AppKitDiffRenderSnapshot
    private var snapshot: AppKitDiffRenderSnapshot
    private let textCache = AppKitDiffTextCache()
    private var renderedSelection: DiffRowID?
    private var contextMenuPosition: (hunk: Int, lineIndex: Int)?
    private var rowHeightOverrides: [DiffRowID: CGFloat] = [:]
    private var hostedRows: [DiffRowID: NSHostingView<AppKitDiffCommentOverlayView>] = [:]
    private var accessibilityRows: [DiffRowID: AppKitDiffAccessibilityRow] = [:]
    private var hoveredRowID: DiffRowID?
    private var trackingArea: NSTrackingArea?
    private var boundsObserver: NSObjectProtocol?
    private var isUpdatingHostedRows = false

    init(store: ReviewSessionStore, snapshot: AppKitDiffRenderSnapshot) {
        self.store = store
        baseSnapshot = snapshot
        self.snapshot = snapshot
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        reload(store: store, snapshot: snapshot)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Interactive diff for \(snapshot.file.path)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    override var isFlipped: Bool { true }

    func reload(store: ReviewSessionStore, snapshot: AppKitDiffRenderSnapshot) {
        let selectionChanged = renderedSelection != store.selection.rowID
        let fileChanged = baseSnapshot.file.path != snapshot.file.path
        self.store = store
        baseSnapshot = snapshot
        if fileChanged {
            rowHeightOverrides.removeAll()
        } else {
            rowHeightOverrides = rowHeightOverrides.filter { id, _ in
                guard let index = snapshot.layout.rowIndex(for: id) else { return false }
                if case .line = snapshot.rows[index].row {
                    return false
                }
                return true
            }
        }
        self.snapshot = snapshot.applyingRowHeightOverrides(rowHeightOverrides)
        self.renderedSelection = store.selection.rowID
        textCache.invalidate()
        updateFrameSize(viewportWidth: bounds.width)
        updateHostedRows()
        setAccessibilityLabel("Interactive diff for \(snapshot.file.path)")
        needsDisplay = true
        if selectionChanged, let rowID = store.selection.rowID {
            DispatchQueue.main.async { [weak self] in
                self?.scroll(to: rowID, alignment: 0.5)
            }
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        }
    }

    func updateViewportWidth(_ width: CGFloat) {
        updateFrameSize(viewportWidth: width)
        updateHostedRows()
    }

    func scroll(to rowID: DiffRowID, alignment: CGFloat) {
        guard let scrollView = enclosingScrollView,
              let originY = snapshot.layout.scrollOrigin(
                  for: rowID,
                  viewportHeight: scrollView.contentView.bounds.height,
                  alignment: alignment
              ) else { return }
        let origin = NSPoint(x: scrollView.contentView.bounds.origin.x, y: originY)
        scrollView.contentView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.installBoundsObserver()
            self.updateHostedRows()
            self.window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        trackingArea = nil
        super.updateTrackingAreas()
        guard window != nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let next = lineHit(at: event)?.positioned.id
        guard next != hoveredRowID else { return }
        hoveredRowID = next
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredRowID != nil else { return }
        hoveredRowID = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let hunkIndex = expandableHunkHit(at: event) {
            store?.expandContext(
                path: snapshot.file.path,
                aboveHunk: hunkIndex,
                all: event.modifierFlags.contains(.option)
            )
            return
        }
        guard let hit = lineHit(at: event) else { return }
        selectLine(
            hunkIndex: hit.hunkIndex,
            lineIndex: hit.lineIndex,
            extending: event.modifierFlags.contains(.shift)
        )
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let hit = lineHit(at: event), let store else { return nil }
        contextMenuPosition = (hit.hunkIndex, hit.lineIndex)
        store.selection.rowID = hit.positioned.id
        updateAccessibilityRows()
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        needsDisplay = true

        let menu = NSMenu()
        menu.autoenablesItems = false
        let comment = NSMenuItem(
            title: "Comment",
            action: #selector(beginCommentFromContextMenu),
            keyEquivalent: ""
        )
        comment.target = self
        comment.isEnabled = DraftRangeValidator.anchor(
            for: snapshot.file,
            hunkIndex: hit.hunkIndex,
            lineIndex: hit.lineIndex
        ) != nil
        menu.addItem(comment)

        let copy = NSMenuItem(
            title: "Copy \(snapshot.file.path):\(hit.line.newLine ?? hit.line.oldLine ?? 0)",
            action: #selector(copyLineFromContextMenu),
            keyEquivalent: ""
        )
        copy.target = self
        menu.addItem(copy)
        return menu
    }

    override func keyDown(with event: NSEvent) {
        guard let store else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 126: // up
            moveSelection(by: -1, store: store)
        case 125: // down
            moveSelection(by: 1, store: store)
        case 116: // page up
            moveSelection(by: -pageSize, store: store)
        case 121: // page down
            moveSelection(by: pageSize, store: store)
        case 115: // home
            selectBoundary(first: true, store: store)
        case 119: // end
            selectBoundary(first: false, store: store)
        case 53: // escape
            if !store.cancelTransientInteraction() {
                NotificationCenter.default.post(
                    name: .reviewReturnToCanvasRequest,
                    object: store
                )
            }
        default:
            super.keyDown(with: event)
        }
    }

    @objc private func beginCommentFromContextMenu() {
        guard let store, let position = contextMenuPosition,
              let anchor = DraftRangeValidator.anchor(
                  for: snapshot.file,
                  hunkIndex: position.hunk,
                  lineIndex: position.lineIndex
              ) else { return }
        store.beginDraft(at: DraftStartAnchor(
            path: anchor.path,
            side: anchor.side,
            line: anchor.line,
            startLine: anchor.startLine,
            startSide: anchor.startSide
        ))
        contextMenuPosition = nil
    }

    @objc private func copyLineFromContextMenu() {
        guard let store, let position = contextMenuPosition else { return }
        _ = store.copyLineToClipboard(
            file: snapshot.file,
            hunkIndex: position.hunk,
            lineIndex: position.lineIndex
        )
        contextMenuPosition = nil
    }

    private var pageSize: Int {
        let viewportHeight = enclosingScrollView?.contentView.bounds.height ?? 400
        return max(1, Int(viewportHeight / snapshot.layout.metrics.lineHeight))
    }

    private func moveSelection(by delta: Int, store: ReviewSessionStore) {
        store.performance.recordNavigation()
        store.moveLineSelection(delta, in: snapshot.file)
        scrollToSelection(store: store)
        needsDisplay = true
    }

    private func selectBoundary(first: Bool, store: ReviewSessionStore) {
        let ids = store.commentableLineIDs(in: snapshot.file)
        guard let id = first ? ids.first : ids.last else { return }
        store.performance.recordNavigation()
        store.selection.rowID = id
        scroll(to: id, alignment: 0.5)
        updateAccessibilityRows()
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        needsDisplay = true
    }

    private func scrollToSelection(store: ReviewSessionStore) {
        guard let rowID = store.selection.rowID else { return }
        scroll(to: rowID, alignment: 0.5)
    }

    private func beginDraft(at anchor: DiffLineAnchor, store: ReviewSessionStore) {
        store.beginDraft(at: DraftStartAnchor(
            path: anchor.path,
            side: anchor.side,
            line: anchor.line,
            startLine: anchor.startLine,
            startSide: anchor.startSide
        ))
    }

    private func selectLine(hunkIndex: Int, lineIndex: Int, extending: Bool) {
        guard let store,
              let line = snapshot.file.line(at: hunkIndex, lineIndex) else { return }
        let rowID = DiffRowID.line(
            file: snapshot.file.path,
            hunk: hunkIndex,
            kind: line.kind,
            old: line.oldLine,
            new: line.newLine
        )
        if extending, let startRow = store.selection.rowID {
            var start: (file: DiffFile, hunkIndex: Int, lineIndex: Int)?
            if let position = store.linePosition(for: startRow, in: snapshot.file) {
                start = (snapshot.file, position.hunk, position.lineIndex)
            }
            let result = DraftRangeValidator().validate(
                start: start,
                end: (snapshot.file, hunkIndex, lineIndex)
            )
            switch result {
            case .single(let anchor):
                beginDraft(at: anchor, store: store)
            case .range(let anchor):
                beginDraft(at: anchor, store: store)
            case .invalid(let reason):
                store.banner = SessionBanner(text: reason, isError: true)
            }
            store.selection.rowID = nil
        } else {
            store.selection.rowID = rowID
        }
        updateAccessibilityRows()
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        needsDisplay = true
    }

    /// The hunk whose header was clicked, when it has hidden lines above it.
    private func expandableHunkHit(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        guard let positioned = snapshot.layout.row(atY: point.y),
              case .hunkHeader(let hunkIndex) = positioned.row.row,
              snapshot.file.hiddenLinesAbove(hunk: hunkIndex) > 0 else { return nil }
        return hunkIndex
    }

    private func lineHit(at event: NSEvent) -> (
        positioned: AppKitDiffLayout.PositionedRow,
        hunkIndex: Int,
        lineIndex: Int,
        line: DiffLine
    )? {
        let point = convert(event.locationInWindow, from: nil)
        guard let positioned = snapshot.layout.row(atY: point.y),
              case .line(let hunkIndex, let lineIndex) = positioned.row.row,
              let line = snapshot.file.line(at: hunkIndex, lineIndex) else {
            return nil
        }
        return (positioned, hunkIndex, lineIndex, line)
    }

    private func installBoundsObserver() {
        guard boundsObserver == nil,
              let clipView = enclosingScrollView?.contentView else { return }
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.updateHostedRows()
        }
    }

    private func updateHostedRows() {
        guard !isUpdatingHostedRows, let store else { return }
        isUpdatingHostedRows = true

        let visible = visibleRect.insetBy(dx: 0, dy: -240)
        let range = snapshot.layout.visibleRange(in: visible, overscan: 0)
        var desired: [DiffRowID: DiffDisplayRow] = [:]
        for index in range {
            let positioned = snapshot.layout.rows[index]
            if let overlayRow = overlayRow(for: positioned, store: store) {
                desired[overlayRow.id] = overlayRow
            }
        }

        for (id, host) in hostedRows where desired[id] == nil {
            host.removeFromSuperview()
            hostedRows.removeValue(forKey: id)
        }

        var heightChanged = false
        for (id, displayRow) in desired {
            guard let positioned = snapshot.layout.row(for: id) else { continue }
            let host: NSHostingView<AppKitDiffCommentOverlayView>
            if let existing = hostedRows[id] {
                host = existing
            } else {
                let overlay = AppKitDiffCommentOverlayView(
                    store: store,
                    file: snapshot.file,
                    displayRow: displayRow,
                    languageID: snapshot.languageID
                )
                let newHost = NSHostingView(rootView: overlay)
                newHost.translatesAutoresizingMaskIntoConstraints = true
                newHost.autoresizingMask = []
                addSubview(newHost)
                hostedRows[id] = newHost
                host = newHost
            }

            let editorOffset = lineEditorOffset(for: displayRow)
            let availableHeight = max(1, positioned.height - editorOffset)
            host.frame = NSRect(
                x: 0,
                y: positioned.originY + editorOffset,
                width: snapshot.layout.contentWidth,
                height: availableHeight
            )
            host.layoutSubtreeIfNeeded()
            let measuredHeight = host.fittingSize.height
            if measuredHeight.isFinite, measuredHeight > 1 {
                let requiredHeight = editorOffset + measuredHeight
                if abs(requiredHeight - positioned.height) > 1 {
                    rowHeightOverrides[id] = requiredHeight
                    heightChanged = true
                }
            }
        }

        if heightChanged {
            snapshot = baseSnapshot.applyingRowHeightOverrides(rowHeightOverrides)
            updateFrameSize(viewportWidth: bounds.width)
            isUpdatingHostedRows = false
            updateHostedRows()
            return
        }

        isUpdatingHostedRows = false
        updateAccessibilityRows()
        needsDisplay = true
    }

    override func accessibilityChildren() -> [Any] {
        var children: [Any] = []
        let range = snapshot.layout.visibleRange(in: visibleRect)
        for index in range {
            let id = snapshot.layout.rows[index].id
            if let host = hostedRows[id] {
                children.append(host)
            } else if let row = accessibilityRows[id] {
                children.append(row)
            }
        }
        return children
    }

    override func accessibilitySelectedChildren() -> [Any] {
        guard let id = store?.selection.rowID,
              let row = accessibilityRows[id] else { return [] }
        return [row]
    }

    private func updateAccessibilityRows() {
        guard let store else { return }
        let range = snapshot.layout.visibleRange(in: visibleRect)
        var desired = Set<DiffRowID>()
        for index in range {
            let positioned = snapshot.layout.rows[index]
            guard hostedRows[positioned.id] == nil else { continue }
            desired.insert(positioned.id)
            let element = accessibilityRows[positioned.id] ?? {
                let identifier = "appkit-diff-row-\(String(describing: positioned.id))"
                let created = AppKitDiffAccessibilityRow(
                    owner: self,
                    rowID: positioned.id,
                    identifier: identifier
                )
                accessibilityRows[positioned.id] = created
                return created
            }()
            element.frameInParent = NSRect(
                x: 0,
                y: positioned.originY,
                width: snapshot.layout.contentWidth,
                height: positioned.height
            )
            element.title = accessibilityTitle(for: positioned)
            element.value = accessibilityValue(for: positioned)
            element.selected = store.selection.rowID == positioned.id
        }
        for (id, _) in accessibilityRows where !desired.contains(id) {
            accessibilityRows.removeValue(forKey: id)
        }
    }

    fileprivate func activateAccessibilityRow(_ rowID: DiffRowID) {
        guard let store, snapshot.layout.row(for: rowID) != nil else { return }
        store.selection.rowID = rowID
        scroll(to: rowID, alignment: 0.5)
        updateAccessibilityRows()
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    private func accessibilityTitle(for positioned: AppKitDiffLayout.PositionedRow) -> String {
        switch positioned.row.row {
        case .line(let hunkIndex, let lineIndex):
            guard let line = snapshot.file.line(at: hunkIndex, lineIndex) else {
                return "Diff line"
            }
            let kind: String
            switch line.kind {
            case .added: kind = "Added"
            case .removed: kind = "Removed"
            case .context: kind = "Context"
            }
            let number = line.newLine ?? line.oldLine ?? 0
            return "\(kind) line \(number), \(snapshot.file.path): \(line.content)"
        case .hunkHeader(let hunkIndex):
            return hunkIndex < snapshot.file.hunks.count
                ? "Hunk \(snapshot.file.hunks[hunkIndex].header)"
                : "Hunk header"
        case .thread:
            return "Comment thread"
        case .draft:
            return "Draft comment"
        case .outdatedHeader:
            return "Outdated comments"
        case .orphanedHeader:
            return "Orphaned drafts"
        case .empty:
            return "No changes"
        }
    }

    private func accessibilityValue(for positioned: AppKitDiffLayout.PositionedRow) -> String? {
        guard case .line(let hunkIndex, let lineIndex) = positioned.row.row else { return nil }
        return snapshot.file.line(at: hunkIndex, lineIndex)?.content
    }

    private func overlayRow(
        for positioned: AppKitDiffLayout.PositionedRow,
        store: ReviewSessionStore
    ) -> DiffDisplayRow? {
        switch positioned.row.row {
        case .thread(let threadID):
            return store.review?.threadByID[threadID] == nil ? nil : positioned.row
        case .draft(let draftID):
            return store.review?.draftByID[draftID] == nil ? nil : positioned.row
        case .line:
            guard let editor = store.draftEditor, isEditorForLine(positioned.row, editor) else {
                return nil
            }
            return positioned.row
        default:
            return nil
        }
    }

    private func isEditorForLine(_ displayRow: DiffDisplayRow, _ editor: DraftEditorState) -> Bool {
        guard case .line(let hunkIndex, let lineIndex) = displayRow.row,
              let line = snapshot.file.line(at: hunkIndex, lineIndex) else {
            return false
        }
        let lineNumber = editor.side == "LEFT" ? line.oldLine : line.newLine
        return editor.path == snapshot.file.path && editor.line == lineNumber
    }

    private func lineEditorOffset(for displayRow: DiffDisplayRow) -> CGFloat {
        if case .line = displayRow.row, store?.draftEditor != nil {
            return snapshot.layout.metrics.lineHeight
        }
        return 0
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let appearance = appKitAppearanceKey(for: effectiveAppearance)
        let palette = AppKitDiffPalette.make(
            isDark: appearance.isDark,
            highContrast: AppearanceSettings.increasedContrast,
            reduceTransparency: AppearanceSettings.reduceTransparency
        )
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        let visible = visibleRect.insetBy(dx: 0, dy: -snapshot.layout.metrics.lineHeight)
        let range = snapshot.layout.visibleRange(in: visible, overscan: 0)
        let fonts = AppKitDiffFonts(size: snapshot.layout.metrics.fontSize)
        for index in range {
            let positioned = snapshot.layout.rows[index]
            guard hostedRows[positioned.id] == nil else { continue }
            let rect = NSRect(x: 0, y: positioned.originY, width: bounds.width, height: positioned.height)
            guard rect.intersects(dirtyRect) else { continue }
            AppKitDiffRowRenderer.draw(
                row: positioned.row,
                file: snapshot.file,
                rect: rect,
                cache: textCache,
                languageID: snapshot.languageID,
                palette: palette,
                fonts: fonts,
                characterWidth: snapshot.layout.metrics.characterWidth,
                appearanceKey: appearance.key,
                selected: store?.selection.rowID == positioned.id,
                hovered: hoveredRowID == positioned.id
            )
        }
    }

    private func updateFrameSize(viewportWidth: CGFloat) {
        let width = max(snapshot.layout.contentWidth, viewportWidth)
        let height = snapshot.layout.contentHeight
        guard frame.size.width != width || frame.size.height != height else { return }
        setFrameSize(NSSize(width: width, height: height))
    }
}
