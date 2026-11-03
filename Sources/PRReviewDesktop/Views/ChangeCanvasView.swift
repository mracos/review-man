import AppKit
import Foundation
import SwiftUI
import PRReviewKit

/// A spatial overview of every file changed by the pull request, drawn as a
/// left-to-right folder tree: the repository root sits at the far left and
/// directories branch right, one column per depth level, with each changed
/// file as a compact leaf chip. Elbow connectors trace the folder structure;
/// selecting a chip opens the existing focused diff view for comments and
/// line-level review.
/// How much detail the change canvas renders, chosen from the PR's size.
/// Full cards render every hunk and line; once a PR is large enough to
/// degrade, cards collapse to the file name only. This keeps the canvas
/// usable on `make demo` scale PRs.
/// Converts discrete mouse-wheel ticks into Canvas zoom changes. Precise
/// scroll input (trackpads) remains available for panning the canvas.
enum CanvasWheelZoom {
    static func adjustedZoom(
        currentZoom: CGFloat,
        scrollingDeltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool
    ) -> CGFloat? {
        guard !hasPreciseScrollingDeltas, scrollingDeltaY != 0 else { return nil }
        let adjustment = scrollingDeltaY > 0
            ? ChangeCanvasView.zoomStep
            : -ChangeCanvasView.zoomStep
        let zoom = ChangeCanvasView.clampedZoom(currentZoom + adjustment)
        return zoom == currentZoom ? nil : zoom
    }
}

public enum CanvasScale: Equatable {
    case full
    case condensed
    case summary

    /// PRs larger than 60 files or ~12k diff lines get condensed cards;
    /// larger than 300 files or ~60k lines get summary-only cards. A full
    /// canvas additionally stays within a small render budget: full cards
    /// mount one row per hunk line, so diffs beyond `fullCardLineBudget`
    /// rows collapse to file-name cards even when the file/line thresholds
    /// are not crossed. The demo tiers map as: small stays full, medium
    /// condenses (10k demo lines exceed the budget), large condenses,
    /// xlarge degrades to summaries.
    public static let condensedFileThreshold = 60
    public static let condensedLineThreshold = 12_000
    public static let fullCardLineBudget = 2_000
    public static let summaryFileThreshold = 300
    public static let summaryLineThreshold = 60_000

    public static func forFiles(_ files: [DiffFile]) -> CanvasScale {
        let totalLines = files.reduce(0) { $0 + $1.lineCount }
        if files.count > summaryFileThreshold || totalLines > summaryLineThreshold {
            return .summary
        }
        if files.count > condensedFileThreshold
            || totalLines > condensedLineThreshold
            || totalLines > fullCardLineBudget {
            return .condensed
        }
        return .full
    }
}

public struct ChangeCanvasView: View {
    public static let defaultZoom: CGFloat = 0.85
    public static let minimumZoom: CGFloat = 0.4
    public static let maximumZoom: CGFloat = 1.35
    public static let zoomStep: CGFloat = 0.1

    @ObservedObject public var store: ReviewSessionStore
    public let files: [DiffFile]
    @Binding public var showCanvas: Bool
    @Binding public var zoom: CGFloat

    @State private var pinchStartZoom: CGFloat?
    /// Viewport area available below the toolbar, used to fit the tree.
    @State private var viewportSize: CGSize?
    /// The last measured (unscaled) board size, used by the Fit button.
    @State private var boardSize: CGSize?
    /// True once the initial board measurement has had its chance to fit-zoom;
    /// reset when a new PR loads so its map gets the same treatment.
    @State private var didAutoFit = false
    /// Weak handle to the invisible first-responder bridge embedded in the
    /// canvas scroll hierarchy (see `CanvasFocusBridge`).
    @State private var focusTarget = CanvasFocusTarget()
    /// ScrollViewReader proxy captured on appear, used to bring the focused
    /// chip into the viewport (the canvas stays mounted while a diff is shown,
    /// so the proxy remains valid).
    @State private var scrollProxy: ScrollViewProxy?
    /// Folder IDs whose descendants are currently hidden from the canvas.
    @State private var collapsedFolderIDs: Set<String> = []
    /// The node currently selected for arrow-key navigation.
    @FocusState private var focusedNodeID: String?
    /// A plain-State record of the intended focus. While a diff is shown the
    /// canvas is `.disabled`, and SwiftUI resets `focusedNodeID` (a FocusState
    /// binding) to nil because it cannot keep focus on a non-focusable view.
    /// This regular @State survives the disabled period, so it is the source
    /// used to restore focus when returning to the canvas.
    @State private var lastFocusedNodeID: String?
    @State private var isSearchPresented = false
    @State private var searchQuery = ""
    @State private var selectedSearchResultIndex = 0
    @State private var searchHighlightedNodeID: String?
    @FocusState private var isSearchFieldFocused: Bool

    public static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(maximumZoom, max(minimumZoom, value))
    }

    static func fittedZoom(board: CGSize, viewport: CGSize) -> CGFloat? {
        guard board.width > 0,
              board.height > 0,
              viewport.width > 32,
              viewport.height > 32 else {
            return nil
        }
        let scaleX = (viewport.width - 32) / board.width
        let scaleY = (viewport.height - 32) / board.height
        return clampedZoom(min(scaleX, scaleY) * 0.94)
    }

    public init(
        store: ReviewSessionStore,
        files: [DiffFile],
        showCanvas: Binding<Bool>,
        zoom: Binding<CGFloat>
    ) {
        self.store = store
        self.files = files
        self._showCanvas = showCanvas
        self._zoom = zoom
    }

    public var body: some View {
        if files.isEmpty {
            EmptyStateView(
                icon: "map",
                title: "Nothing to map",
                message: "This pull request has no changed files."
            )
        } else {
            VStack(spacing: 0) {
                canvasToolbar
                Divider()
                // Attach magnification to a parent of the ScrollView. This
                // lets pinch gestures pass through chips while native
                // two-axis scrolling stays untouched. The GeometryReader
                // reports the viewport so the tree can auto-fit on load.
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        canvasScroll
                    }
                    .overlay(alignment: .top) {
                        if isSearchPresented {
                            canvasSearchOverlay
                        }
                    }
                    .onAppear {
                        viewportSize = geometry.size
                        AppLog.info("canvas", "CANVAS_APPEAR files=\(files.count) viewport=\(geometry.size) \(canvasDiagnosticContext())")
                        prepareInitialCanvas(
                            in: CanvasTree.build(from: files),
                            viewport: geometry.size
                        )
                    }
                    .onChange(of: geometry.size) { newSize in
                        viewportSize = newSize
                        let collapsedTree = CanvasTree.build(from: files)
                            .hidingDescendants(of: collapsedFolderIDs)
                        fitInitialZoom(board: treePlan(for: collapsedTree).boardSize, viewport: newSize)
                        AppLog.info("canvas", "CANVAS_VIEWPORT_CHANGE viewport=\(newSize) \(canvasDiagnosticContext())")
                    }
                    .onPreferenceChange(CanvasBoardSizeKey.self) { board in
                        boardSize = board
                        AppLog.info("canvas", "CANVAS_BOARD_MEASURE board=\(board) \(canvasDiagnosticContext())")
                        fitInitialZoom(board: board)
                    }
                    .simultaneousGesture(magnificationGesture)
                }
            }
            .accessibilityIdentifier("change-canvas-pane")
            .onChange(of: showCanvas) { isVisible in
                // The canvas stays mounted (hidden, disabled) while a diff is
                // shown, so zoom, collapse, and selection state all survive.
                // The actual keyboard focus does not: FocusState drops the
                // first responder while the view is disabled and never
                // re-requests it for an unchanged value. Re-assert it on the
                // node that was focused before the diff opened.
                if isVisible {
                    restoreCanvasFocus()
                }
            }
            .onChange(of: store.review?.pr?.headRefOid) { _ in
                prepareInitialCanvas(in: CanvasTree.build(from: files))
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewCanvasSearchRequest)) { note in
                guard showCanvas, targetsThisStore(note) else { return }
                presentCanvasSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewCanvasCollapseFolderRequest)) { note in
                guard showCanvas, targetsThisStore(note) else { return }
                collapseFocusedFolder(in: CanvasTree.build(from: files))
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewCanvasExpandFolderRequest)) { note in
                guard showCanvas, targetsThisStore(note) else { return }
                expandFocusedFolder(in: CanvasTree.build(from: files))
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewCanvasCollapseAllFoldersRequest)) { note in
                guard showCanvas, targetsThisStore(note) else { return }
                collapseAllFolders(in: CanvasTree.build(from: files))
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewCanvasExpandAllFoldersRequest)) { note in
                guard showCanvas, targetsThisStore(note) else { return }
                expandAllFolders()
            }
        }
    }

    private var canvasToolbar: some View {
        let tree = CanvasTree.build(from: files)
        return HStack(spacing: 10) {
            Image(systemName: "map")
                .foregroundStyle(.orange)
            Text("Change canvas")
                .font(.headline)
            Text(toolbarSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if scale != .full {
                Text(scale == .condensed ? "Condensed" : "Overview")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(.orange)
                    .help(scale == .condensed
                        ? "Large PR — compact file chips. Click a chip to open the focused diff."
                        : "Very large PR — file chips only. Click a chip to open the focused diff.")
            }
            Text("\(tree.folderCount) folders · \(tree.fileCount) files")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                presentCanvasSearch()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Find a file or folder")
            .accessibilityLabel("Find a file or folder")

            Divider()
                .frame(height: 18)

            Button {
                zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom out (⌘−)")
            .accessibilityLabel("Zoom out (Command minus)")

            Text("\(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 42)
                .accessibilityLabel("Canvas zoom \(Int(zoom * 100)) percent")

            Button {
                zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom in (⌘+)")
            .accessibilityLabel("Zoom in (Command plus)")

            Button("Reset") {
                resetZoom()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Reset canvas zoom (⌘0)")

            Button("Fit") {
                fitToBoard()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Zoom to fit the whole tree")

            Button("Collapse all") {
                collapseAllFolders(in: tree)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(collapsedFolderIDs.count == tree.folderCount)
            .help("Collapse every folder in the tree")

            Button("Expand all") {
                expandAllFolders()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(collapsedFolderIDs.isEmpty)
            .help("Expand every folder in the tree")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.96))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("change-canvas-toolbar")
    }

    private var scale: CanvasScale {
        CanvasScale.forFiles(files)
    }

    private var toolbarSubtitle: String {
        switch scale {
        case .full:
            return "Folder tree, left to right · Mouse wheel, pinch, or ⌘+/⌘− to zoom"
        case .condensed:
            return "Compact chips · Mouse wheel, pinch, or ⌘+/⌘− to zoom"
        case .summary:
            return "File names only · Mouse wheel, pinch, or ⌘+/⌘− to zoom"
        }
    }

    private var canvasScroll: some View {
        let tree = CanvasTree.build(from: files)
            .hidingDescendants(of: collapsedFolderIDs)
        let commentCountsByPath = self.commentCountsByPath
        let descendantCommentCounts = descendantCommentCounts(for: tree)
        let plan = treePlan(for: tree, descendantCommentCounts: descendantCommentCounts)
        let boardSize = CGSize(
            width: plan.boardSize.width * zoom,
            height: plan.boardSize.height * zoom
        )
        let nodeFrames = plan.frames.map { frame in
            CGRect(
                x: frame.minX * zoom,
                y: frame.minY * zoom,
                width: frame.width * zoom,
                height: frame.height * zoom
            )
        }

        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                // Use real scaled layout geometry rather than scaleEffect. The
                // transform left SwiftUI's button hit regions stale after a tree
                // reflow until another zoom forced a new hit-test map.
                CanvasTreeLayout(frames: nodeFrames) {
                    ForEach(Array(tree.nodes.enumerated()), id: \.element.id) { index, node in
                        let isHighlighted = highlightedNodeID == node.id
                        let nodeView = treeNodeView(
                            node: node,
                            descendantFileCount: tree.subtreeFileCounts[index],
                            descendantCommentCount: descendantCommentCounts[index],
                            size: plan.frames[index].size,
                            zoom: zoom,
                            commentCount: commentCountsByPath[node.path, default: 0],
                            isHighlighted: isHighlighted
                        )
                        nodeView.id(canvasScrollID(node.id))
                    }
                }
                .frame(width: boardSize.width, height: boardSize.height)
                .background(treeConnectors(plan: plan, zoom: zoom))
                .background {
                    // Fit uses the unscaled plan, independently of the rendered
                    // document's current zoom.
                    Color.clear.preference(key: CanvasBoardSizeKey.self, value: plan.boardSize)
                }
            }
            // Invisible first-responder anchor for the whole canvas. SwiftUI's
            // FocusState cannot re-engage the AppKit responder chain once the
            // canvas returns from being disabled; restoring this view as the
            // window's first responder routes arrow keys back into SwiftUI's
            // focus engine, which re-applies the stored chip focus.
            .background {
                CanvasFocusBridge(target: focusTarget)
                    .allowsHitTesting(false)
                CanvasWheelZoomMonitor(zoom: $zoom, isEnabled: showCanvas)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Capture the proxy once the canvas appears so navigation can keep
            // the focused chip in view (arrow moves, return from a diff, and
            // collapse/expand reflows).
            .onAppear {
                scrollProxy = proxy
            }
        }
    }

    /// Node dimensions include each label's measured width, keeping every
    /// file and folder name visible while preserving a pure layout plan.
    private func treePlan(
        for tree: CanvasTree,
        descendantCommentCounts: [Int]? = nil
    ) -> TreePlan {
        let descendantCommentCounts = descendantCommentCounts
            ?? self.descendantCommentCounts(for: tree)
        let sizes = tree.nodes.enumerated().map { index, node in
            if node.isFolder {
                TreeMetrics.folderSize(
                    for: node.name,
                    descendantFileCount: tree.subtreeFileCounts[index],
                    commentCount: descendantCommentCounts[index]
                )
            } else if let file = node.file {
                TreeMetrics.fileSize(
                    for: file,
                    commentCount: commentCountsByPath[file.path, default: 0]
                )
            } else {
                TreeMetrics.fileSize(for: nil)
            }
        }
        return TreePlan.compute(
            sizes: sizes,
            depths: tree.depths,
            parents: tree.parents,
            columnGap: TreeMetrics.columnGap,
            rowGap: TreeMetrics.rowGap,
            padding: TreeMetrics.padding
        )
    }

    @ViewBuilder
    private func treeNodeView(
        node: CanvasTree.Node,
        descendantFileCount: Int,
        descendantCommentCount: Int,
        size: CGSize,
        zoom: CGFloat,
        commentCount: Int,
        isHighlighted: Bool
    ) -> some View {
        if node.isFolder {
            let isCollapsed = collapsedFolderIDs.contains(node.id)
            Button {
                AppLog.info("canvas", "CANVAS_FOLDER_TAP id=\(node.id) path=\(node.path) isCollapsed=\(isCollapsed) \(canvasDiagnosticContext())")
                setCanvasFocus(node.id)
                toggleFolder(node, in: CanvasTree.build(from: files))
            } label: {
                TreeFolderChip(
                    node: node,
                    descendantFileCount: descendantFileCount,
                    descendantCommentCount: descendantCommentCount,
                    isCollapsed: isCollapsed,
                    size: size,
                    zoom: zoom,
                    isHighlighted: isHighlighted
                )
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand folder" : "Collapse folder")
            .accessibilityIdentifier("canvas-folder-\(node.path)")
            .accessibilityLabel("\(isCollapsed ? "Expand" : "Collapse") \(node.name) folder, \(descendantFileCount) \(descendantFileCount == 1 ? "file" : "files")\(descendantCommentCount > 0 ? ", \(descendantCommentCount) comments" : "")")
            .focused($focusedNodeID, equals: node.id)
            .onMoveCommand(perform: handleCanvasMove)
        } else if let file = node.file {
            Button {
                setCanvasFocus(node.id)
                open(file)
            } label: {
                TreeFileChip(
                    store: store,
                    file: file,
                    size: size,
                    zoom: zoom,
                    commentCount: commentCount,
                    isHighlighted: isHighlighted
                )
            }
            .buttonStyle(.plain)
            // The Button is the hover target, so its help must carry the path;
            // help attached inside the label is superseded by this modifier.
            .help("\(file.path)\nOpen focused diff")
            .contextMenu {
                Button("Open focused diff") { open(file) }
                Button(fileIsViewed(file) ? "Mark unviewed" : "Mark viewed") {
                    store.toggleViewed(filePath: file.path)
                }
            }
            .accessibilityIdentifier("canvas-file-\(file.path)")
            .accessibilityLabel(canvasAccessibilityLabel(for: file, commentCount: commentCount))
            .focused($focusedNodeID, equals: node.id)
            .onMoveCommand(perform: handleCanvasMove)
        }
    }

    private var highlightedNodeID: String? {
        searchHighlightedNodeID ?? lastFocusedNodeID
    }

    private var searchResults: [CanvasTree.Node] {
        CanvasSearch.results(for: searchQuery, in: CanvasTree.build(from: files))
    }

    private var selectedSearchResult: CanvasTree.Node? {
        guard searchResults.indices.contains(selectedSearchResultIndex) else { return nil }
        return searchResults[selectedSearchResultIndex]
    }

    private var canvasSearchOverlay: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find a file or folder", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                    .onSubmit(commitCanvasSearch)
                Button(action: dismissCanvasSearch) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close canvas search")
            }

            if !searchResults.isEmpty {
                HStack {
                    Text("\(searchResults.count) \(searchResults.count == 1 ? "match" : "matches")")
                    Spacer()
                    Text("\(selectedSearchResultIndex + 1) of \(searchResults.count)")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                CanvasSearchResultsView(
                    results: searchResults,
                    selectedIndex: selectedSearchResultIndex,
                    onSelect: selectSearchResult
                )
            } else if !searchQuery.isEmpty {
                Text("No matching files or folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Type a name or path to focus it in the canvas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .background {
            CanvasSearchKeyMonitor(onMove: moveSearchSelection)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.top, 12)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas-search-overlay")
        .onChange(of: searchQuery) { _ in
            selectedSearchResultIndex = 0
            focusSelectedSearchResult()
        }
        .onExitCommand(perform: dismissCanvasSearch)
    }

    /// Elbow connectors between parent folders and their children, drawn in
    /// the same coordinate space as the scaled node layout frames.
    private func treeConnectors(plan: TreePlan, zoom: CGFloat) -> some View {
        Canvas { context, size in
            let lineColor = Color.secondary.opacity(0.4)
            for link in plan.links {
                let parent = plan.frames[link.parent]
                let child = plan.frames[link.child]
                let startX = parent.maxX * zoom
                let endX = child.minX * zoom
                let midX = startX + (endX - startX) / 2
                var path = Path()
                path.move(to: CGPoint(x: startX, y: parent.midY * zoom))
                path.addLine(to: CGPoint(x: midX, y: parent.midY * zoom))
                path.addLine(to: CGPoint(x: midX, y: child.midY * zoom))
                path.addLine(to: CGPoint(x: endX, y: child.midY * zoom))
                context.stroke(path, with: .color(lineColor), lineWidth: 1.5 * zoom)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchStartZoom == nil {
                    pinchStartZoom = zoom
                    AppLog.info("canvas", "CANVAS_MAGNIFY_BEGIN value=\(value) \(canvasDiagnosticContext())")
                }
                let start = pinchStartZoom ?? zoom
                zoom = Self.clampedZoom(start * value)
            }
            .onEnded { value in
                pinchStartZoom = nil
                AppLog.info("canvas", "CANVAS_MAGNIFY_END value=\(value) \(canvasDiagnosticContext())")
            }
    }

    private func zoomIn() {
        zoom = Self.clampedZoom(zoom + Self.zoomStep)
    }

    private func zoomOut() {
        zoom = Self.clampedZoom(zoom - Self.zoomStep)
    }

    private func resetZoom() {
        zoom = Self.defaultZoom
    }

    private func presentCanvasSearch() {
        isSearchPresented = true
        searchQuery = ""
        selectedSearchResultIndex = 0
        searchHighlightedNodeID = nil
        DispatchQueue.main.async {
            isSearchFieldFocused = true
        }
    }

    private func dismissCanvasSearch() {
        isSearchPresented = false
        isSearchFieldFocused = false
        searchHighlightedNodeID = nil
    }

    private func commitCanvasSearch() {
        guard let result = selectedSearchResult else {
            dismissCanvasSearch()
            return
        }
        let nodeID = result.id
        dismissCanvasSearch()
        setCanvasFocus(nil)
        DispatchQueue.main.async {
            setCanvasFocus(nodeID)
            if let view = focusTarget.view, let window = view.window {
                window.makeFirstResponder(view)
            }
            scrollToNode(nodeID)
        }
    }

    private func selectSearchResult(_ index: Int) {
        guard searchResults.indices.contains(index) else { return }
        selectedSearchResultIndex = index
        focusSelectedSearchResult()
        DispatchQueue.main.async {
            isSearchFieldFocused = true
        }
    }

    private func moveSearchSelection(_ offset: Int) {
        let resultCount = searchResults.count
        guard resultCount > 0 else { return }
        let index = (selectedSearchResultIndex + offset + resultCount) % resultCount
        selectedSearchResultIndex = index
        focusSelectedSearchResult()
    }

    private func focusSelectedSearchResult() {
        guard let result = selectedSearchResult else {
            searchHighlightedNodeID = nil
            return
        }
        let tree = CanvasTree.build(from: files)
        collapsedFolderIDs.subtract(tree.ancestorFolderIDs(of: result.id))
        searchHighlightedNodeID = result.id
        DispatchQueue.main.async {
            guard searchHighlightedNodeID == result.id else { return }
            scrollToNode(result.id)
        }
    }

    private func toggleFolder(_ node: CanvasTree.Node, in tree: CanvasTree) {
        if collapsedFolderIDs.contains(node.id) {
            expandFolderOneLevel(node.id, in: tree)
        } else {
            collapseFolderOneLevel(node.id, in: tree)
        }
    }

    private func collapseFocusedFolder(in tree: CanvasTree) {
        guard let folderID = focusedNodeID,
              tree.nodes.contains(where: { $0.id == folderID && $0.isFolder }) else {
            return
        }
        collapseFolderOneLevel(folderID, in: tree)
    }

    private func expandFocusedFolder(in tree: CanvasTree) {
        guard let folderID = focusedNodeID,
              tree.nodes.contains(where: { $0.id == folderID && $0.isFolder }) else {
            return
        }
        expandFolderOneLevel(folderID, in: tree)
    }

    /// Install this on each focusable chip rather than its ScrollView parent:
    /// the native button is the first responder after a node is clicked.
    private func handleCanvasMove(_ direction: MoveCommandDirection) {
        guard showCanvas else { return }
        let tree = CanvasTree.build(from: files)
            .hidingDescendants(of: collapsedFolderIDs)
        let plan = treePlan(for: tree)

        switch direction {
        case .up:
            moveCanvasFocus(.up, in: tree, plan: plan)
        case .down:
            moveCanvasFocus(.down, in: tree, plan: plan)
        case .left:
            moveCanvasFocus(.left, in: tree, plan: plan)
        case .right:
            moveCanvasFocus(.right, in: tree, plan: plan)
        default:
            break
        }
    }

    private func moveCanvasFocus(
        _ direction: CanvasNodeDirection,
        in tree: CanvasTree,
        plan: TreePlan
    ) {
        guard let nextNodeID = CanvasNodeNavigator.nextNodeID(
            from: focusedNodeID,
            direction: direction,
            tree: tree,
            plan: plan
        ) else {
            return
        }

        focusedNodeID = nextNodeID
        lastFocusedNodeID = nextNodeID
        scrollToNode(nextNodeID)
        AppLog.info("canvas", "CANVAS_KEYBOARD_FOCUS direction=\(direction) id=\(nextNodeID) \(canvasDiagnosticContext())")
    }

    // MARK: - Keep the focused node in view

    /// Scroll ID registered on each rendered chip so `ScrollViewReader` can
    /// bring it back into the viewport.
    private func canvasScrollID(_ nodeID: String) -> String {
        "canvas-scroll:\(nodeID)"
    }

    /// Scrolls the viewport so `nodeID` — or its nearest visible ancestor when
    /// a collapse hides it — is centered on screen. Respects Reduce Motion,
    /// mirroring the diff pane's scroll behavior.
    private func scrollToNode(_ nodeID: String?) {
        guard let proxy = scrollProxy else { return }
        guard let target = CanvasReveal.resolvedVisibleTarget(
            for: nodeID ?? lastFocusedNodeID,
            collapsedFolderIDs: collapsedFolderIDs
        ) else { return }
        let scrollID = canvasScrollID(target)
        if AppearanceSettings.reduceMotion {
            proxy.scrollTo(scrollID, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(scrollID, anchor: .center)
            }
        }
    }

    /// After a collapse/expand the tree reflows, so the focused chip (or its
    /// representative folder) can drift out of view. Redirects focus when a
    /// collapse hid the focused node, then reveals it once the new layout has
    /// had a run-loop turn to place its frames.
    private func revealFocusedNodeAfterReflow() {
        DispatchQueue.main.async {
            if let remembered = lastFocusedNodeID,
               CanvasReveal.isHiddenByCollapse(
                   nodeID: remembered,
                   collapsedFolderIDs: collapsedFolderIDs
               ),
               let target = CanvasReveal.resolvedVisibleTarget(
                   for: remembered,
                   collapsedFolderIDs: collapsedFolderIDs
               ) {
                setCanvasFocus(target)
                scrollToNode(target)
                return
            }
            scrollToNode(lastFocusedNodeID)
        }
    }

    /// Collapses immediate child folders first. A second collapse closes this
    /// folder after every child folder is already collapsed.
    private func collapseFolderOneLevel(_ folderID: String, in tree: CanvasTree) {
        let childFolderIDs = tree.childFolderIDs(of: folderID)
        let expandedChildFolderIDs = childFolderIDs.subtracting(collapsedFolderIDs)
        AppLog.info(
            "canvas",
            "CANVAS_FOLDER_COLLAPSE_STEP id=\(folderID) expandedChildren=\(expandedChildFolderIDs.count) \(canvasDiagnosticContext())"
        )

        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedChildFolderIDs.isEmpty {
                _ = collapsedFolderIDs.insert(folderID)
            } else {
                collapsedFolderIDs.formUnion(expandedChildFolderIDs)
            }
        }
        revealFocusedNodeAfterReflow()
    }

    /// Reveals direct children only. Once a folder is open, each invocation
    /// expands its collapsed child folders by one further level.
    private func expandFolderOneLevel(_ folderID: String, in tree: CanvasTree) {
        let childFolderIDs = tree.childFolderIDs(of: folderID)
        AppLog.info(
            "canvas",
            "CANVAS_FOLDER_EXPAND_STEP id=\(folderID) childFolders=\(childFolderIDs.count) wasCollapsed=\(collapsedFolderIDs.contains(folderID)) \(canvasDiagnosticContext())"
        )

        withAnimation(.easeInOut(duration: 0.2)) {
            if collapsedFolderIDs.contains(folderID) {
                _ = collapsedFolderIDs.remove(folderID)
                collapsedFolderIDs.formUnion(tree.descendantFolderIDs(of: folderID))
                return
            }

            let collapsedChildFolderIDs = childFolderIDs.intersection(collapsedFolderIDs)
            for childFolderID in collapsedChildFolderIDs {
                _ = collapsedFolderIDs.remove(childFolderID)
                collapsedFolderIDs.formUnion(tree.descendantFolderIDs(of: childFolderID))
            }
        }
        revealFocusedNodeAfterReflow()
    }

    private func collapseAllFolders(in tree: CanvasTree) {
        withAnimation(.easeInOut(duration: 0.2)) {
            collapsedFolderIDs = Set(tree.nodes.lazy.filter(\.isFolder).map(\.id))
            setCanvasFocus(tree.nodes.first?.id)
        }
        revealFocusedNodeAfterReflow()
    }

    private func prepareInitialCanvas(in tree: CanvasTree, viewport: CGSize? = nil) {
        didAutoFit = false
        let folderIDs = Set(tree.nodes.lazy.filter(\.isFolder).map(\.id))
        collapsedFolderIDs = folderIDs
        setCanvasFocus(tree.nodes.first?.id)
        let collapsedTree = tree.hidingDescendants(of: folderIDs)
        fitInitialZoom(board: treePlan(for: collapsedTree).boardSize, viewport: viewport)
    }

    private func expandAllFolders() {
        withAnimation(.easeInOut(duration: 0.2)) {
            collapsedFolderIDs.removeAll()
        }
        revealFocusedNodeAfterReflow()
    }

    /// "Fit" button: zooms the tree down (or up) so its bounding box sits
    /// fully inside the viewport with a small ocean margin.
    private func fitToBoard() {
        guard let board = boardSize,
              let viewport = viewportSize,
              let fittedZoom = Self.fittedZoom(board: board, viewport: viewport) else {
            AppLog.info("canvas", "CANVAS_FIT skipped board=\(String(describing: boardSize)) viewport=\(String(describing: viewportSize))")
            return
        }
        zoom = fittedZoom
        AppLog.info("canvas", "CANVAS_FIT board=\(board) viewport=\(viewport) zoom=\(zoom)")
    }

    /// Fits the newly laid-out board once. Manual zooming afterwards is never
    /// overridden.
    private func fitInitialZoom(board: CGSize, viewport: CGSize? = nil) {
        guard !didAutoFit,
              let viewport = viewport ?? viewportSize,
              let fittedZoom = Self.fittedZoom(board: board, viewport: viewport) else {
            return
        }
        didAutoFit = true
        zoom = fittedZoom
    }

    /// Re-applies keyboard focus to the node that was focused before the diff
    /// opened. `focusedNodeID` (a FocusState binding) is reset to nil while the
    /// canvas is disabled, so the target comes from `lastFocusedNodeID`, which
    /// survives. Clearing and restoring the FocusState value forces a fresh
    /// focus request, and making the invisible bridge view the first
    /// responder restores the AppKit responder chain so arrow keys route back
    /// into SwiftUI's focus engine.
    private func restoreCanvasFocus() {
        let tree = CanvasTree.build(from: files)
        let rememberedNodeID = lastFocusedNodeID
        let targetNodeID = rememberedNodeID.flatMap { id in
            tree.nodes.contains(where: { $0.id == id }) ? id : nil
        } ?? tree.nodes.first?.id
        guard let targetNodeID else { return }

        setCanvasFocus(nil)
        DispatchQueue.main.async {
            setCanvasFocus(targetNodeID)
            if let view = focusTarget.view, let window = view.window {
                window.makeFirstResponder(view)
            }
            // The restored chip may have scrolled off-viewport while the diff
            // was shown; bring it back into view now that the layout has had a
            // run-loop turn to place its frames.
            scrollToNode(targetNodeID)
        }
    }

    /// Sets the focus targets. Plain-state `lastFocusedNodeID` is kept in
    /// sync with the FocusState binding because the binding itself is reset to
    /// nil once the canvas is disabled.
    private func setCanvasFocus(_ nodeID: String?) {
        focusedNodeID = nodeID
        lastFocusedNodeID = nodeID
    }

    /// Logs and reacts to the canvas becoming visible again after a diff.
    private func handleShowCanvasChange(visible: Bool) {
        if visible {
            restoreCanvasFocus()
        }
    }

    private func open(_ file: DiffFile) {
        AppLog.info("canvas", "CANVAS_FILE_OPEN path=\(file.path) \(canvasDiagnosticContext())")
        store.select(filePath: file.path)
        showCanvas = false
    }

    private func fileIsViewed(_ file: DiffFile) -> Bool {
        store.review?.viewed.contains(file.path) == true
    }

    private var commentCountsByPath: [String: Int] {
        Dictionary(uniqueKeysWithValues: (store.review?.sidebarItems ?? []).map {
            ($0.path, $0.threadCount)
        })
    }

    private func descendantCommentCounts(for tree: CanvasTree) -> [Int] {
        let fullTree = CanvasTree.build(from: files)
        let fullCounts = fullTree.subtreeCommentCounts(byPath: commentCountsByPath)
        let countsByNodeID = Dictionary(
            uniqueKeysWithValues: zip(fullTree.nodes.map(\.id), fullCounts)
        )
        return tree.nodes.map { countsByNodeID[$0.id, default: 0] }
    }

    private func canvasAccessibilityLabel(for file: DiffFile, commentCount: Int) -> String {
        let comments = commentCount > 0 ? ", \(commentCount) comments" : ""
        let viewed = fileIsViewed(file) ? ", viewed" : ""
        return "\(file.path), \(file.additions) additions, \(file.deletions) deletions\(comments)\(viewed)"
    }

    private func canvasDiagnosticContext() -> String {
        let viewport = viewportSize.map(String.init(describing:)) ?? "nil"
        let board = boardSize.map(String.init(describing:)) ?? "nil"
        return "zoom=\(zoom) pinching=\(pinchStartZoom != nil) viewport=\(viewport) board=\(board) collapsed=\(collapsedFolderIDs.count) focused=\(focusedNodeID ?? "nil")"
    }

    private func targetsThisStore(_ note: Notification) -> Bool {
        guard let target = note.object as? ReviewSessionStore else { return true }
        return target === store
    }
}

// MARK: - Folder tree

/// A left-to-right directory tree of the PR's changed files: folders branch
/// right, files are leaves. Mirrors the real folder structure (no singleton
/// promotion), flattened in pre-order with parent/depth bookkeeping so the
/// layout and the connector drawing stay in lockstep.
struct CanvasTree: Equatable {
    struct Node: Identifiable, Equatable {
        let id: String
        let name: String
        let path: String
        let isFolder: Bool
        let file: DiffFile?

        init(folderPath: String, name: String) {
            self.id = "folder:\(folderPath)"
            self.name = name
            self.path = folderPath
            self.isFolder = true
            self.file = nil
        }

        init(file: DiffFile) {
            self.id = "file:\(file.path)"
            self.name = file.path.split(separator: "/").last.map(String.init) ?? file.path
            self.path = file.path
            self.isFolder = false
            self.file = file
        }
    }

    /// Pre-order flattening; `parents[i]` is the parent node index of node
    /// `i`, or nil for the implicit root folder.
    let nodes: [Node]
    let parents: [Int?]
    let depths: [Int]
    /// Number of changed files in each node's subtree (the root counts all).
    let subtreeFileCounts: [Int]

    var folderCount: Int { nodes.filter(\.isFolder).count }
    var fileCount: Int { nodes.filter { !$0.isFolder }.count }

    static func build(from files: [DiffFile]) -> CanvasTree {
        var nodes: [Node] = []
        var parents: [Int?] = []
        var depths: [Int] = []

        func visit(prefix: [String], parentIndex: Int?, depth: Int, items: [DiffFile]) {
            let folderPath = prefix.joined(separator: "/")
            let nodeIndex = nodes.count
            nodes.append(Node(
                folderPath: folderPath,
                name: prefix.isEmpty ? "Root" : prefix.last ?? folderPath
            ))
            parents.append(parentIndex)
            depths.append(depth)

            var subdirectoryItems: [String: [DiffFile]] = [:]
            var directFiles: [DiffFile] = []
            for item in items {
                let parts = item.path.split(separator: "/")
                if parts.count == prefix.count + 1 {
                    directFiles.append(item)
                } else if parts.count > prefix.count + 1 {
                    subdirectoryItems[String(parts[prefix.count]), default: []].append(item)
                }
            }
            // Subfolders first (their subtrees hang above this folder's own
            // files), then the folder's direct files, all sorted by name.
            for name in subdirectoryItems.keys.sorted() {
                visit(
                    prefix: prefix + [name],
                    parentIndex: nodeIndex,
                    depth: depth + 1,
                    items: subdirectoryItems[name] ?? []
                )
            }
            for file in directFiles.sorted(by: {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }) {
                nodes.append(Node(file: file))
                parents.append(nodeIndex)
                depths.append(depth + 1)
            }
        }

        visit(prefix: [], parentIndex: nil, depth: 0, items: files)

        var children: [[Int]] = Array(repeating: [], count: nodes.count)
        for (index, parent) in parents.enumerated() {
            if let parent {
                children[parent].append(index)
            }
        }
        var subtreeCounts = nodes.map { $0.isFolder ? 0 : 1 }
        for index in stride(from: nodes.count - 1, through: 0, by: -1) {
            subtreeCounts[index] += children[index].reduce(0) { $0 + subtreeCounts[$1] }
        }
        return CanvasTree(
            nodes: nodes,
            parents: parents,
            depths: depths,
            subtreeFileCounts: subtreeCounts
        )
    }

    func subtreeCommentCounts(byPath commentCountsByPath: [String: Int]) -> [Int] {
        var counts = nodes.map { node in
            node.isFolder ? 0 : commentCountsByPath[node.path, default: 0]
        }
        for index in stride(from: nodes.count - 1, through: 0, by: -1) {
            if let parent = parents[index] {
                counts[parent] += counts[index]
            }
        }
        return counts
    }

    func ancestorFolderIDs(of nodeID: String) -> Set<String> {
        guard var index = nodes.firstIndex(where: { $0.id == nodeID }) else {
            return []
        }
        var ancestorIDs: Set<String> = []
        while let parent = parents[index] {
            index = parent
            if nodes[index].isFolder {
                ancestorIDs.insert(nodes[index].id)
            }
        }
        return ancestorIDs
    }

    /// Folder IDs that are direct children of `nodeID`.
    func childFolderIDs(of nodeID: String) -> Set<String> {
        guard let parentIndex = nodes.firstIndex(where: { $0.id == nodeID }) else {
            return []
        }
        return Set(nodes.enumerated().compactMap { index, node in
            parents[index] == parentIndex && node.isFolder ? node.id : nil
        })
    }

    /// Folder IDs below `nodeID`, excluding the node itself.
    func descendantFolderIDs(of nodeID: String) -> Set<String> {
        guard let rootIndex = nodes.firstIndex(where: { $0.id == nodeID }) else {
            return []
        }

        var children: [[Int]] = Array(repeating: [], count: nodes.count)
        for (index, parent) in parents.enumerated() {
            if let parent {
                children[parent].append(index)
            }
        }

        var descendantIDs: Set<String> = []
        func collect(_ index: Int) {
            for child in children[index] {
                if nodes[child].isFolder {
                    descendantIDs.insert(nodes[child].id)
                }
                collect(child)
            }
        }
        collect(rootIndex)
        return descendantIDs
    }

    /// Returns a layout-ready tree that retains each collapsed folder but hides
    /// all of its descendants. Stored subtree counts stay attached to the
    /// folder so its chip can still show the total changed files it contains.
    func hidingDescendants(of collapsedNodeIDs: Set<String>) -> CanvasTree {
        guard !collapsedNodeIDs.isEmpty else { return self }

        var children: [[Int]] = Array(repeating: [], count: nodes.count)
        for (index, parent) in parents.enumerated() {
            if let parent {
                children[parent].append(index)
            }
        }

        var visibleNodes: [Node] = []
        var visibleParents: [Int?] = []
        var visibleDepths: [Int] = []
        var visibleSubtreeCounts: [Int] = []

        func visit(_ sourceIndex: Int, parentIndex: Int?, depth: Int) {
            let visibleIndex = visibleNodes.count
            visibleNodes.append(nodes[sourceIndex])
            visibleParents.append(parentIndex)
            visibleDepths.append(depth)
            visibleSubtreeCounts.append(subtreeFileCounts[sourceIndex])

            guard !collapsedNodeIDs.contains(nodes[sourceIndex].id) else { return }
            for child in children[sourceIndex] {
                visit(child, parentIndex: visibleIndex, depth: depth + 1)
            }
        }

        visit(0, parentIndex: nil, depth: 0)
        return CanvasTree(
            nodes: visibleNodes,
            parents: visibleParents,
            depths: visibleDepths,
            subtreeFileCounts: visibleSubtreeCounts
        )
    }
}

enum CanvasSearch {
    static func results(for query: String, in tree: CanvasTree) -> [CanvasTree.Node] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        return tree.nodes.filter {
            $0.name.localizedStandardContains(trimmedQuery)
                || $0.path.localizedStandardContains(trimmedQuery)
        }
    }
}

private struct CanvasSearchResultsView: View {
    let results: [CanvasTree.Node]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    private var selectedNodeID: String? {
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex].id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: results.count > 6) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        let isSelected = index == selectedIndex
                        Button {
                            onSelect(index)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: result.isFolder ? "folder.fill" : "doc.fill")
                                    .frame(width: 16)
                                    .foregroundStyle(result.isFolder ? .orange : .secondary)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.path.isEmpty ? "Root" : result.name)
                                        .lineLimit(1)
                                    if !result.path.isEmpty, result.path != result.name {
                                        Text(result.path)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                if isSelected {
                                    Image(systemName: "return")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 40)
                            .contentShape(Rectangle())
                            .background(
                                isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(result.id)
                        .accessibilityValue(isSelected ? "Selected" : "")
                        .accessibilityIdentifier("canvas-search-result-\(result.id)")
                    }
                }
            }
            .frame(height: CGFloat(min(results.count, 6)) * 42)
            .onChange(of: selectedNodeID) { nodeID in
                guard let nodeID else { return }
                proxy.scrollTo(nodeID, anchor: .center)
            }
        }
    }
}

private struct CanvasSearchKeyMonitor: NSViewRepresentable {
    let onMove: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMove: onMove)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onMove = onMove
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeEventMonitor()
    }

    final class Coordinator {
        var onMove: (Int) -> Void
        private weak var view: NSView?
        private var eventMonitor: Any?

        init(onMove: @escaping (Int) -> Void) {
            self.onMove = onMove
        }

        deinit {
            removeEventMonitor()
        }

        func install(on view: NSView) {
            self.view = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let window = self.view?.window,
                      event.window === window,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                    return event
                }
                switch event.keyCode {
                case 125:
                    self.onMove(1)
                    return nil
                case 126:
                    self.onMove(-1)
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

// MARK: - Tree keyboard navigation

/// Pure logic for resolving which chip handles reveal/focus once folders are
/// collapsed, independent of the view so it can be unit-tested. Node ids are
/// "folder:<path>" / "file:<path>" (root folder path is empty).
/// Collapsing a folder keeps its own chip rendered but drops the descendant
/// chips, so a node under a collapsed folder must fall back to the nearest
/// visible folder ancestor.
enum CanvasReveal {
    /// The path encoded in a canvas node id ("file:a/b.py" → "a/b.py").
    static func nodePath(of nodeID: String) -> String? {
        if nodeID.hasPrefix("file:") {
            return String(nodeID.dropFirst("file:".count))
        }
        if nodeID.hasPrefix("folder:") {
            return String(nodeID.dropFirst("folder:".count))
        }
        return nil
    }

    /// Folder node id containing `nodeID` in the full tree ("file:a/b.py" →
    /// "folder:a"). Root-level nodes report the root folder, so a fully
    /// hidden target never walks past the visible root.
    static func parentFolderID(of nodeID: String) -> String? {
        guard let path = nodePath(of: nodeID),
              let lastSlash = path.lastIndex(of: "/") else {
            return "folder:"
        }
        return "folder:" + path[..<lastSlash]
    }

    /// Whether a collapse currently hides `nodeID`'s chip. Collapsed folders
    /// themselves stay rendered; their descendants do not.
    static func isHiddenByCollapse(nodeID: String, collapsedFolderIDs: Set<String>) -> Bool {
        guard let path = nodePath(of: nodeID) else { return false }
        for collapsed in collapsedFolderIDs {
            guard let foldedPath = nodePath(of: collapsed) else { continue }
            if foldedPath.isEmpty {
                // A collapsed root hides every other node; the root itself stays.
                return !path.isEmpty
            }
            if path.hasPrefix(foldedPath + "/") {
                return true
            }
        }
        return false
    }

    /// The id to scroll to: `nodeID` itself when it is currently rendered,
    /// otherwise the nearest folder ancestor that is still visible.
    static func resolvedVisibleTarget(
        for nodeID: String?,
        collapsedFolderIDs: Set<String>
    ) -> String? {
        var current = nodeID
        while let id = current {
            if !isHiddenByCollapse(nodeID: id, collapsedFolderIDs: collapsedFolderIDs) {
                return id
            }
            guard let parent = parentFolderID(of: id) else { return nil }
            current = parent
        }
        return nil
    }
}

/// Directions supported by the canvas's arrow-key node navigation.
enum CanvasNodeDirection: CustomStringConvertible {
    case up
    case down
    case left
    case right

    var description: String {
        switch self {
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        }
    }
}

/// Resolves arrow-key destinations from the visible tree and its plan. Left
/// and right follow hierarchy; up and down prefer the current depth column,
/// then fall back to the nearest visible node when that column has no peer.
enum CanvasNodeNavigator {
    static func nextNodeID(
        from currentNodeID: String?,
        direction: CanvasNodeDirection,
        tree: CanvasTree,
        plan: TreePlan
    ) -> String? {
        guard !tree.nodes.isEmpty else { return nil }
        guard let currentNodeID,
              let currentIndex = tree.nodes.firstIndex(where: { $0.id == currentNodeID }) else {
            return tree.nodes.first?.id
        }

        switch direction {
        case .left:
            guard let parentIndex = tree.parents[currentIndex] else { return nil }
            return tree.nodes[parentIndex].id
        case .right:
            guard let childIndex = tree.parents.firstIndex(of: currentIndex) else { return nil }
            return tree.nodes[childIndex].id
        case .up, .down:
            let currentFrame = plan.frames[currentIndex]
            let verticalCandidates = tree.nodes.indices.filter { index in
                switch direction {
                case .up: return plan.frames[index].midY < currentFrame.midY
                case .down: return plan.frames[index].midY > currentFrame.midY
                case .left, .right: return false
                }
            }
            let sameColumnCandidates = verticalCandidates.filter {
                tree.depths[$0] == tree.depths[currentIndex]
            }
            // A single straight branch can have every node on the same row.
            // Fall back to that row's visual order so arrow navigation never
            // traps focus on an otherwise navigable canvas.
            let candidates: [Int]
            if !sameColumnCandidates.isEmpty {
                candidates = sameColumnCandidates
            } else if !verticalCandidates.isEmpty {
                candidates = verticalCandidates
            } else {
                candidates = tree.nodes.indices.filter { $0 != currentIndex }
            }
            let destination = candidates.min { lhs, rhs in
                let lhsVerticalDistance = abs(plan.frames[lhs].midY - currentFrame.midY)
                let rhsVerticalDistance = abs(plan.frames[rhs].midY - currentFrame.midY)
                if lhsVerticalDistance != rhsVerticalDistance {
                    return lhsVerticalDistance < rhsVerticalDistance
                }
                return abs(plan.frames[lhs].midX - currentFrame.midX)
                    < abs(plan.frames[rhs].midX - currentFrame.midX)
            }
            return destination.map { tree.nodes[$0].id }
        }
    }
}

// MARK: - Tree geometry

/// Pure geometry for the left-to-right tree: every depth gets one column
/// (root leftmost), nodes stack vertically by subtree span, and a parent is
/// vertically centered over its children. All frames are returned in board
/// coordinates (inset by `padding`), so the layout, the connector drawing,
/// and the fit-zoom all agree without any measurement round-trips.
struct TreePlan {
    struct Link: Equatable {
        var parent: Int
        var child: Int
    }

    var frames: [CGRect]
    var links: [Link]
    var boardSize: CGSize

    static func compute(
        sizes: [CGSize],
        depths: [Int],
        parents: [Int?],
        columnGap: CGFloat,
        rowGap: CGFloat,
        padding: CGFloat
    ) -> TreePlan {
        let count = sizes.count
        guard count > 0 else {
            return TreePlan(frames: [], links: [], boardSize: .zero)
        }

        // One column per depth; column width is the widest node at that depth.
        var maxWidthByDepth: [Int: CGFloat] = [:]
        for (index, depth) in depths.enumerated() {
            maxWidthByDepth[depth] = max(maxWidthByDepth[depth] ?? 0, sizes[index].width)
        }
        let maxDepth = depths.max() ?? 0
        var columnX: [CGFloat] = []
        var cursor: CGFloat = 0
        for depth in 0...maxDepth {
            columnX.append(cursor)
            if depth < maxDepth {
                cursor += (maxWidthByDepth[depth] ?? 0) + columnGap
            }
        }

        var children: [[Int]] = Array(repeating: [], count: count)
        for (index, parent) in parents.enumerated() {
            if let parent {
                children[parent].append(index)
            }
        }

        // Top-down placement: leaves start at the cursor; a parent is centered
        // over the span of its children. Consecutive siblings get `rowGap`,
        // preventing file chips from appearing as one uninterrupted strip.
        var nodeY: [CGFloat] = Array(repeating: 0, count: count)
        func assignY(_ index: Int, minY: CGFloat) -> CGFloat {
            let own = sizes[index].height
            if children[index].isEmpty {
                nodeY[index] = minY
                return minY + own
            }
            var cursor = minY
            for (childOffset, child) in children[index].enumerated() {
                cursor = assignY(child, minY: cursor)
                if childOffset < children[index].count - 1 {
                    cursor += rowGap
                }
            }
            let span = cursor - minY
            nodeY[index] = minY + span / 2 - own / 2
            return max(cursor, nodeY[index] + own)
        }
        if count > 0 {
            _ = assignY(0, minY: 0)
        }

        // Layout-space frames, then the tight bounding box shifted into the
        // board by `padding`.
        var frames: [CGRect] = []
        frames.reserveCapacity(count)
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = minX
        var maxX = -minX
        var maxY = -minX
        for index in 0..<count {
            let frame = CGRect(
                x: columnX[depths[index]],
                y: nodeY[index],
                width: sizes[index].width,
                height: sizes[index].height
            )
            frames.append(frame)
            minX = min(minX, frame.minX)
            minY = min(minY, frame.minY)
            maxX = max(maxX, frame.maxX)
            maxY = max(maxY, frame.maxY)
        }
        let shiftX = padding - minX
        let shiftY = padding - minY
        frames = frames.map { $0.offsetBy(dx: shiftX, dy: shiftY) }

        var links: [Link] = []
        for (index, parent) in parents.enumerated() {
            if let parent {
                links.append(Link(parent: parent, child: index))
            }
        }

        return TreePlan(
            frames: frames,
            links: links,
            boardSize: CGSize(
                width: maxX - minX + padding * 2,
                height: maxY - minY + padding * 2
            )
        )
    }
}

enum TreeMetrics {
    static let folderMinimumWidth: CGFloat = 190
    static let folderHeight: CGFloat = 54
    static let fileMinimumWidth: CGFloat = 250
    static let fileHeight: CGFloat = 50
    static let columnGap: CGFloat = 48
    static let rowGap: CGFloat = 24
    static let padding: CGFloat = 40

    static func folderSize(
        for name: String,
        descendantFileCount: Int,
        commentCount: Int = 0
    ) -> CGSize {
        let nameWidth = textWidth(name, font: .systemFont(ofSize: 12, weight: .semibold))
        let countWidth = textWidth("\(descendantFileCount)", font: .monospacedSystemFont(ofSize: 10, weight: .bold)) + 12
        let commentBadge = commentCount > 0 ? "● \(commentCount)" : ""
        let commentBadgeWidth = textWidth(
            commentBadge,
            font: .systemFont(ofSize: 10, weight: .regular)
        )
        // Chevron, icon, inter-item gaps, flexible gap, and horizontal padding.
        let chromeWidth: CGFloat = commentCount > 0 ? 102 : 94
        return CGSize(
            width: max(folderMinimumWidth, nameWidth + countWidth + commentBadgeWidth + chromeWidth),
            height: folderHeight
        )
    }

    static func fileSize(for file: DiffFile?, commentCount: Int = 0) -> CGSize {
        let fileName = file?.path.split(separator: "/").last.map(String.init) ?? ""
        let nameWidth = textWidth(fileName, font: .monospacedSystemFont(ofSize: 12, weight: .semibold))
        let counts = file.map { "+\($0.additions) −\($0.deletions)" } ?? ""
        let countWidth = textWidth(counts, font: .monospacedSystemFont(ofSize: 10, weight: .regular))
        let commentBadge = commentCount > 0 ? "● \(commentCount)" : ""
        let commentBadgeWidth = commentCount > 0
            ? textWidth(commentBadge, font: .systemFont(ofSize: 10, weight: .regular)) + 8
            : 0
        // Status, inter-item gaps, a viewed-mark reservation, and horizontal padding.
        let chromeWidth: CGFloat = 18 + 8 + 4 + 20 + 20
        return CGSize(
            width: max(fileMinimumWidth, nameWidth + countWidth + commentBadgeWidth + chromeWidth),
            height: fileHeight
        )
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

// MARK: - Chips

/// A folder node: disclosure state, icon, name, and changed-file count.
private struct TreeFolderChip: View {
    let node: CanvasTree.Node
    let descendantFileCount: Int
    let descendantCommentCount: Int
    let isCollapsed: Bool
    let size: CGSize
    let zoom: CGFloat
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8 * zoom) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10 * zoom, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10 * zoom)
            Image(systemName: "folder.fill")
                .font(.system(size: 12 * zoom, weight: .semibold))
                .foregroundStyle(.orange)
            Text(node.name)
                .font(.system(size: 12 * zoom, weight: .semibold))
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 4 * zoom)
            Text("\(descendantFileCount)")
                .font(.system(size: 10 * zoom, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .padding(.horizontal, 6 * zoom)
                .padding(.vertical, zoom)
                .background(Color.primary.opacity(0.08), in: Capsule())
            if descendantCommentCount > 0 {
                Text("● \(descendantCommentCount)")
                    .font(.system(size: 10 * zoom))
                    .foregroundStyle(.purple)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .accessibilityLabel("\(descendantCommentCount) comments")
            }
        }
        .padding(.horizontal, 12 * zoom)
        .frame(width: size.width * zoom, height: size.height * zoom)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10 * zoom))
        .overlay {
            RoundedRectangle(cornerRadius: 10 * zoom)
                .stroke(
                    isHighlighted ? Color.accentColor : Color.orange.opacity(0.35),
                    lineWidth: (isHighlighted ? 2 : 1) * max(zoom, 0.5)
                )
        }
        .shadow(color: Color.black.opacity(0.07), radius: 4 * zoom, y: 2 * zoom)
        .contentShape(RoundedRectangle(cornerRadius: 10 * zoom))
    }
}

/// A file leaf: status letter, short name, ± counts, viewed mark. Compact at
/// every scale — the tree is a structure overview; patches stay in the
/// focused diff.
private struct TreeFileChip: View {
    @ObservedObject var store: ReviewSessionStore
    let file: DiffFile
    let size: CGSize
    let zoom: CGFloat
    let commentCount: Int
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8 * zoom) {
            Text(file.status.letter)
                .font(.system(size: 11 * zoom, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 18 * zoom, height: 18 * zoom)
                .background(statusColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 4 * zoom))

            Text(fileName)
                .font(.system(size: 12 * zoom, weight: .semibold, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4 * zoom)

            Text(verbatim: "+\(file.additions) −\(file.deletions)")
                .font(.system(size: 10 * zoom, design: .monospaced))
                .foregroundStyle(.secondary)

            if commentCount > 0 {
                Text("● \(commentCount)")
                    .font(.system(size: 10 * zoom))
                    .foregroundStyle(.purple)
                    .accessibilityLabel("\(commentCount) comments")
            }

            if fileIsViewed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12 * zoom))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 10 * zoom)
        .frame(width: size.width * zoom, height: size.height * zoom)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9 * zoom))
        .overlay {
            RoundedRectangle(cornerRadius: 9 * zoom)
                .stroke(borderColor, lineWidth: (isHighlighted || isSelected ? 2 : 1) * zoom)
        }
        .shadow(color: Color.black.opacity(0.07), radius: 4 * zoom, y: 2 * zoom)
        .contentShape(RoundedRectangle(cornerRadius: 9 * zoom))
    }

    private var fileName: String {
        file.path.split(separator: "/").last.map(String.init) ?? file.path
    }

    private var fileIsViewed: Bool {
        store.review?.viewed.contains(file.path) == true
    }

    private var isSelected: Bool {
        store.selection.filePath == file.path
    }

    private var borderColor: Color {
        (isHighlighted || isSelected) ? .accentColor.opacity(0.8) : Color.gray.opacity(0.22)
    }

    private var statusColor: Color {
        switch file.status {
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .modified: return .secondary
        }
    }
}

// MARK: - Board support

/// Reports the unscaled size of the board up to `ChangeCanvasView` so the
/// Fit button and the initial fit-zoom can frame the whole tree in the
/// viewport.
private struct CanvasBoardSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

/// Places nodes at their scaled `TreePlan` frames during layout. Buttons are
/// never visually transformed after layout, so the scroll view and hit testing
/// share the same geometry.
private struct CanvasTreeLayout: Layout {
    let frames: [CGRect]

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let requiredSize = frames.reduce(into: CGSize.zero) { size, frame in
            size.width = max(size.width, frame.maxX)
            size.height = max(size.height, frame.maxY)
        }
        return CGSize(
            width: proposal.width ?? requiredSize.width,
            height: proposal.height ?? requiredSize.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        for (index, subview) in subviews.enumerated() where frames.indices.contains(index) {
            let frame = frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.midX, y: bounds.minY + frame.midY),
                anchor: .center,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }
}

// MARK: - First-responder bridge

/// Weak handle to the canvas's invisible NSView, held by `ChangeCanvasView` so
/// it can restore the AppKit first responder after returning from a focused
/// diff.
private final class CanvasFocusTarget {
    weak var view: NSView?
}

/// An invisible NSView embedded in the canvas scroll hierarchy. SwiftUI's
/// FocusState tracks which chip is focused but cannot re-engage the AppKit
/// responder chain after the canvas is disabled and re-enabled; making this
/// view the window's first responder routes keyboard events back into
/// SwiftUI's focus engine, which re-applies the chip focus.
private struct CanvasFocusBridge: NSViewRepresentable {
    let target: CanvasFocusTarget

    func makeNSView(context: Context) -> NSView {
        let view = CanvasFocusBridgeView(frame: .zero)
        view.setAccessibilityElement(false)
        target.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The bridge's NSView accepts first responder status (plain NSViews do not)
/// but never handles input itself — default responder behavior bubbles keys up
/// to the SwiftUI hosting view, which routes them to the focused chip.
private final class CanvasFocusBridgeView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Observes discrete mouse-wheel events over the canvas without taking over
/// hit testing. Trackpad scrolling is deliberately passed through to the
/// ScrollView, while a physical wheel adjusts the Canvas zoom.
private struct CanvasWheelZoomMonitor: NSViewRepresentable {
    @Binding var zoom: CGFloat
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(zoom: $zoom, isEnabled: isEnabled)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(zoom: $zoom, isEnabled: isEnabled)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeEventMonitor()
    }

    final class Coordinator {
        private weak var view: NSView?
        private var eventMonitor: Any?
        private var zoom: Binding<CGFloat>
        private var isEnabled: Bool

        init(zoom: Binding<CGFloat>, isEnabled: Bool) {
            self.zoom = zoom
            self.isEnabled = isEnabled
        }

        deinit {
            removeEventMonitor()
        }

        func install(on view: NSView) {
            self.view = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return handle(event) ? nil : event
            }
        }

        func update(zoom: Binding<CGFloat>, isEnabled: Bool) {
            self.zoom = zoom
            self.isEnabled = isEnabled
        }

        func removeEventMonitor() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard isEnabled,
                  let view,
                  let window = view.window,
                  event.window === window else {
                return false
            }

            let location = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(location),
                  let zoom = CanvasWheelZoom.adjustedZoom(
                      currentZoom: zoom.wrappedValue,
                      scrollingDeltaY: event.scrollingDeltaY,
                      hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
                  ) else {
                return false
            }

            self.zoom.wrappedValue = zoom
            return true
        }
    }
}
