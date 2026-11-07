import SwiftUI
import PRReviewKit

/// The review window: a NavigationSplitView (collapsible file sidebar + detail
/// pane) that also hosts the open/loading/empty/error states. Publishes its
/// store as the focused command target and routes command notifications.
public struct ReviewWindowView: View {
    @ObservedObject public var store: ReviewSessionStore
    @ObservedObject public var inbox: InboxStore
    /// Which list the sidebar shows; the inbox until a file filter is asked for.
    @State private var sidebarTab: SidebarTab = .inbox
    @State private var showOpenSheet = false
    @State private var sheetReference = ""
    @State private var sidebarVisible = false
    /// One-shot request passed to the sidebar after it is made visible, so
    /// Cmd-F can put the insertion point in its file filter.
    @State private var focusSidebarSearch = false
    /// The change canvas is the default overview mode. Selecting a file card
    /// or a file in the sidebar switches back to the focused-file view.
    @State private var showCanvas = true
    /// Which overview `showCanvas` reveals: the spatial canvas or every diff
    /// stacked in one scroll.
    @AppStorage(OverviewMode.key) private var overviewModeRaw = OverviewMode.canvas.rawValue
    @State private var canvasZoom = ChangeCanvasView.defaultZoom
    @State private var diffPresentation: DiffPresentation = .unified
    @State private var showCloseWarning = false
    /// Editable copy of the failed reference shown in the error state.
    @State private var failureReference = ""

    public init(store: ReviewSessionStore, inbox: InboxStore) {
        self.store = store
        self.inbox = inbox
    }

    public var body: some View {
        Group {
            switch store.state {
            case .welcome:
                NavigationSplitView {
                    InboxSidebarView(inbox: inbox, store: store)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 420)
                } detail: {
                    OpenPullRequestView(store: store)
                        .frame(minWidth: 480, minHeight: 360)
                }
            case .loading(let reference):
                loadingView(reference: reference)
            case .loaded, .empty:
                loadedShell
            case .failed(let message):
                failureView(message: message)
            }
        }
        .focusedSceneObject(store)
        .background(CloseWarningBridge(store: store, showWarning: $showCloseWarning))
        .alert("Local changes may not be saved", isPresented: $showCloseWarning) {
            Button("Keep Editing", role: .cancel) {}
            Button("Close Anyway") {
                // Programmatic close bypasses windowShouldClose (which already
                // returned false to show this dialog).
                NSApp.keyWindow?.close()
            }
            .accessibilityIdentifier("close-anyway-button")
        } message: {
            Text("The last persistence operation failed; your in-memory changes may not survive this window closing.")
        }
        .modifier(CommandRoutingModifier(
            store: store,
            showOpenSheet: $showOpenSheet,
            sidebarVisible: $sidebarVisible
        ))
        .modifier(DiffPresentationCommandRouting(
            store: store,
            showCanvas: $showCanvas,
            diffPresentation: $diffPresentation
        ))
        .modifier(ViewedNavigationCommandRouting(store: store))
        .modifier(ZoomCommandRouting(store: store, showCanvas: $showCanvas, canvasZoom: $canvasZoom))
        .modifier(NavigationHistoryRouting(store: store, showCanvas: $showCanvas))
        .toolbar { toolbarContent }
        .onChange(of: store.requestFocus) { _ in
            if store.requestFocus == .sidebarSearch {
                sidebarVisible = true   // reveal the search surface if hidden
                sidebarTab = .files
                focusSidebarSearch = true
            }
            if store.requestFocus != .none { store.requestFocus = .none }
        }
        .onChange(of: showCanvas) { showingCanvas in
            guard !showingCanvas, let file = store.selectedFile else { return }
            // Start the render interval when the focused diff actually becomes
            // the visible mode. This avoids counting time spent browsing the
            // canvas after a file was selected there.
            store.performance.beginFileSelection(path: file.path, lineCount: file.lineCount)
        }
        .sheet(isPresented: $showOpenSheet) {
            VStack(spacing: 16) {
                Text("Open Pull Request")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                OpenPullRequestForm(store: store, reference: $sheetReference)
                    .frame(maxWidth: 420)
                Button("Close") { showOpenSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            .frame(width: 480)
            .onAppear { sheetReference = "" }
        }
        .sheet(isPresented: submitSheetBinding) {
            SubmitReviewView(store: store)
        }
        .onExitCommand {
            handleExitCommand()
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewReturnToCanvasRequest)) { note in
            // The AppKit diff surface swallows Escape in keyDown; it asks the
            // window to return to the canvas once no transient interaction
            // needed dismissing.
            handleReturnToCanvas(note)
        }
    }

    /// Escape precedence: dismiss transient interactions first; with nothing
    /// left to cancel, return from the focused diff to the change canvas.
    /// Zoom, collapsed folders, and keyboard focus survive because the canvas
    /// stays mounted (hidden) while the diff is shown.
    private func handleExitCommand() {
        let cancelled = store.cancelTransientInteraction()
        if !cancelled, !showCanvas {
            showCanvas = true
        }
    }

    private func handleReturnToCanvas(_ note: Notification) {
        guard matches(note) else { return }
        showCanvas = true
    }

    private func matches(_ note: Notification) -> Bool {
        guard let object = note.object as? ReviewSessionStore else { return true }
        return object === store
    }

    private var overviewMode: OverviewMode {
        OverviewMode(rawValue: overviewModeRaw) ?? .canvas
    }

    private var canvasVisible: Bool {
        showCanvas && overviewMode == .canvas
    }

    private var paneBinding: Binding<PaneChoice> {
        Binding(
            get: { showCanvas ? (overviewMode == .list ? .list : .canvas) : .file },
            set: { choice in
                switch choice {
                case .canvas:
                    overviewModeRaw = OverviewMode.canvas.rawValue
                    showCanvas = true
                case .list:
                    overviewModeRaw = OverviewMode.list.rawValue
                    showCanvas = true
                case .file:
                    showCanvas = false
                }
            }
        )
    }

    private var submitSheetBinding: Binding<Bool> {
        Binding(
            get: { store.submitState != .hidden },
            set: { if !$0 { store.cancelSubmit() } }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if store.state == .loaded || store.state == .empty {
                let availability = ReviewCommandAvailability(context: store.commandContext())
                Picker("Diff view", selection: paneBinding) {
                    Text("Canvas").tag(PaneChoice.canvas)
                    Text("List").tag(PaneChoice.list)
                    Text("Selected file").tag(PaneChoice.file)
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                .accessibilityLabel("Diff view")
                .accessibilityIdentifier("diff-view-picker")

                if !showCanvas || overviewMode == .list {
                    Picker("Diff layout", selection: $diffPresentation) {
                        ForEach(DiffPresentation.allCases) { presentation in
                            Text(presentation.title).tag(presentation)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    .accessibilityIdentifier("diff-layout-picker")
                }

                Button {
                    showOpenSheet = true
                } label: {
                    Label("Open Pull Request", systemImage: "square.and.arrow.down")
                }
                .help("Open a different pull request")
                .accessibilityIdentifier("toolbar-open")
                Button {
                    store.beginSubmit()
                } label: {
                    Label("Submit Review", systemImage: "paperplane")
                }
                .disabled(!availability.canSubmit)
                .help("Submit the review")
                .accessibilityIdentifier("toolbar-submit")
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!availability.canRefresh)
                .help("Refresh the review")
                .accessibilityIdentifier("toolbar-refresh")
                Button {
                    if let file = store.selectedFile, let position = store.selectedLinePosition(in: file),
                       let anchor = DraftRangeValidator.anchor(for: file, hunkIndex: position.hunk, lineIndex: position.lineIndex) {
                        store.beginDraft(at: DraftStartAnchor(
                            path: anchor.path, side: anchor.side, line: anchor.line,
                            startLine: anchor.startLine, startSide: anchor.startSide
                        ))
                    } else {
                        store.banner = SessionBanner(text: "Select a diff line to comment on.", isError: true)
                    }
                } label: {
                    Label("Comment", systemImage: "bubble.left")
                }
                .disabled(!availability.canAddComment)
                .help("Comment on the selected line")
                .accessibilityIdentifier("toolbar-comment")
                Button {
                    store.toggleViewed(filePath: store.selection.filePath ?? "")
                } label: {
                    Label("Toggle Viewed", systemImage: "checkmark.circle")
                }
                .disabled(!availability.canToggleViewed)
                .help("Toggle viewed state")
                .accessibilityIdentifier("toolbar-viewed")
                Menu {
                    let names = store.reviewerNames
                    if names.isEmpty {
                        Text("No commenters yet")
                    } else {
                        ForEach(names, id: \.self) { name in
                            Button {
                                if store.hiddenReviewers.contains(name) {
                                    store.unhideReviewer(name)
                                } else {
                                    store.hideReviewer(name)
                                }
                            } label: {
                                if store.hiddenReviewers.contains(name) {
                                    Label(name, systemImage: "checkmark")
                                } else {
                                    Text(name)
                                }
                            }
                        }
                    }
                    if !store.hiddenReviewers.isEmpty {
                        Divider()
                        Button("Show All Comments") { store.unhideAllReviewers() }
                    }
                } label: {
                    Label("Filter Comments", systemImage: store.hiddenReviewers.isEmpty ? "eye" : "eye.slash")
                }
                .disabled(!availability.canHideReviewer)
                .help(store.hiddenReviewers.isEmpty
                    ? "Hide comments by a reviewer"
                    : "\(store.hiddenReviewers.count) reviewer(s) hidden — adjust the comment filter")
                .accessibilityIdentifier("toolbar-filter-comments")
                Button {
                    if let file = store.selectedFile, let position = store.selectedLinePosition(in: file) {
                        _ = store.copyLineToClipboard(file: file, hunkIndex: position.hunk, lineIndex: position.lineIndex)
                    }
                } label: {
                    Label("Copy Line", systemImage: "doc.on.doc")
                }
                .disabled(!availability.canCopyLine)
                .help("Copy the selected line")
                .accessibilityIdentifier("toolbar-copy")
                Button {
                    store.openInBrowser()
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .disabled(!availability.canOpenInBrowser)
                .help("Open the PR in your browser")
                .accessibilityIdentifier("toolbar-browser")
            }
        }
    }

    private func loadingView(reference: String) -> some View {
        let progress = store.loadProgress
        return VStack(spacing: 12) {
            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
                    .frame(width: 280)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text("Opening \(reference)")
                .font(.headline)
            Text(progress.headline)
                .monospacedDigit()
                .accessibilityIdentifier("loading-stage")
            if let size = progress.sizeSummary {
                Text(size)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let note = progress.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                Text("\(Int(context.date.timeIntervalSince(progress.startedAt)))s")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Button("Cancel") { store.cancelLoad() }
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("loading-state")
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Could not open pull request")
                .font(.headline)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("error-message")
            TextField("https://github.com/owner/repo/pull/123 or owner/repo#123", text: $failureReference)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .onSubmit { retryFromFailure() }
                .accessibilityIdentifier("error-reference-field")
            Button("Try Again") { retryFromFailure() }
                .disabled(failureReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("try-again-button")
            DependencyStatusCard(store: store)
                .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("error-state")
        .onAppear {
            if let reference = store.lastRequestedReference, reference != "demo" {
                failureReference = reference
            }
        }
    }

    private func retryFromFailure() {
        let trimmed = failureReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.open(reference: trimmed)
    }

    private var loadedShell: some View {
        NavigationSplitView(columnVisibility: sidebarBinding) {
            VStack(spacing: 0) {
                Picker("Sidebar", selection: $sidebarTab) {
                    Text("Inbox").tag(SidebarTab.inbox)
                    Text("Files").tag(SidebarTab.files)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                .accessibilityIdentifier("sidebar-tab")
                switch sidebarTab {
                case .inbox:
                    InboxSidebarView(inbox: inbox, store: store)
                case .files:
                    FileSidebarView(
                        store: store,
                        showCanvas: $showCanvas,
                        focusSearch: $focusSidebarSearch
                    )
                }
            }
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
        } detail: {
            detailPane
        }
    }

    private var sidebarBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = ($0 != .detailOnly) }
        )
    }

    @ViewBuilder
    private var detailPane: some View {
        if let review = store.review {
            VStack(spacing: 0) {
                PullRequestHeaderView(review: review)
                if let actions = store.actionState, actions.hasAnyAction {
                    PRActionsBar(store: store, actions: actions)
                }
                if !review.hiddenReviewers.isEmpty {
                    hiddenReviewersStrip(review)
                }
                Divider()
                if store.state == .empty {
                    EmptyStateView(
                        icon: "doc.text",
                        title: "No changed files",
                        message: "This pull request has no file changes."
                    )
                } else {
                    // Keep the canvas in the hierarchy while a diff is shown.
                    // Its internal expansion, keyboard-focus, and scroll
                    // state then survive switching between the two modes.
                    ZStack {
                        if SwiftFlowCanvasSpike.isEnabled {
                            SwiftFlowCanvasSpikeView(
                                store: store,
                                files: review.files,
                                showCanvas: $showCanvas,
                                zoom: $canvasZoom
                            )
                            .opacity(canvasVisible ? 1 : 0)
                            .allowsHitTesting(canvasVisible)
                            .disabled(!canvasVisible)
                            .accessibilityHidden(!canvasVisible)
                        } else {
                            ChangeCanvasView(
                                store: store,
                                files: review.files,
                                showCanvas: $showCanvas,
                                zoom: $canvasZoom
                            )
                            .opacity(canvasVisible ? 1 : 0)
                            .allowsHitTesting(canvasVisible)
                            .disabled(!canvasVisible)
                            .accessibilityHidden(!canvasVisible)
                        }

                        if showCanvas, overviewMode == .list {
                            StackedDiffsView(store: store, files: review.files, presentation: diffPresentation, showCanvas: $showCanvas)
                        }

                        if !showCanvas, let file = store.selectedFile {
                            VStack(spacing: 0) {
                                FocusedFileBar(store: store, file: file)
                                Divider()
                                DiffView(store: store, file: file, presentation: $diffPresentation)
                            }
                        } else if !showCanvas {
                            EmptyStateView(
                                icon: "sidebar.left",
                                title: "Select a file",
                                message: "Choose a file from the sidebar to view its diff."
                            )
                        }
                    }
                }
                if let banner = store.banner {
                    bannerBar(banner)
                }
            }
        } else {
            EmptyStateView(icon: "questionmark.circle", title: "Nothing loaded", message: "")
        }
    }

    private func hiddenReviewersStrip(_ review: ReviewPresentation) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
            Text("Comments by \(review.hiddenReviewers.sorted().joined(separator: ", ")) hidden")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("Show All") { store.unhideAllReviewers() }
                .font(.caption)
                .accessibilityIdentifier("hidden-reviewers-show-all")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(SwiftUI.Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hidden-reviewers-strip")
    }

    private func bannerBar(_ banner: SessionBanner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(banner.isError ? .red : .secondary)
            Text(banner.text)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                store.banner = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .padding(8)
        .background(AppearanceSettings.reduceTransparency
            ? Color(nsColor: .controlBackgroundColor)
            : Color.gray.opacity(0.1))
        .accessibilityIdentifier("status-banner")
    }
}

/// Routes command notifications to the focused window's store.
private struct CommandRoutingModifier: ViewModifier {
    @ObservedObject var store: ReviewSessionStore
    @Binding var showOpenSheet: Bool
    @Binding var sidebarVisible: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .reviewOpenRequest)) { note in
                if (note.object as? ReviewSessionStore) === store {
                    showOpenSheet = true
                } else if note.object == nil, store.state == .welcome {
                    // Unscoped requests only target the welcome window.
                    showOpenSheet = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewFindRequest)) { note in
                guard matches(note) else { return }
                store.requestFocus = .sidebarSearch
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewAddCommentRequest)) { note in
                guard matches(note) else { return }
                if let file = store.selectedFile, let position = store.selectedLinePosition(in: file),
                   let anchor = DraftRangeValidator.anchor(for: file, hunkIndex: position.hunk, lineIndex: position.lineIndex) {
                    store.beginDraft(at: DraftStartAnchor(
                        path: anchor.path, side: anchor.side, line: anchor.line,
                        startLine: anchor.startLine, startSide: anchor.startSide
                    ))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewReplyRequest)) { note in
                guard matches(note) else { return }
                if case .thread(let threadID)? = store.selection.rowID {
                    store.beginReply(threadID: threadID)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewResolveRequest)) { note in
                guard matches(note) else { return }
                if case .thread(let threadID)? = store.selection.rowID {
                    store.toggleResolved(threadID: threadID)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewToggleViewedRequest)) { note in
                guard matches(note) else { return }
                if let path = store.selection.filePath {
                    store.toggleViewed(filePath: path)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewSubmitRequest)) { note in
                guard matches(note) else { return }
                store.beginSubmit()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewRefreshRequest)) { note in
                guard matches(note) else { return }
                store.refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewToggleSidebarRequest)) { note in
                guard matches(note) else { return }
                sidebarVisible.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewPreviousFileRequest)) { note in
                guard matches(note) else { return }
                store.selectPreviousFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewNextFileRequest)) { note in
                guard matches(note) else { return }
                store.selectNextFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewPreviousHunkRequest)) { note in
                guard matches(note) else { return }
                if let file = store.selectedFile { store.selectAdjacentHunk(-1, in: file) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewNextHunkRequest)) { note in
                guard matches(note) else { return }
                if let file = store.selectedFile { store.selectAdjacentHunk(1, in: file) }
            }
    }

    private func matches(_ note: Notification) -> Bool {
        guard let object = note.object as? ReviewSessionStore else { return true }
        return object === store
    }
}

/// Keeps the diff-layout commands separate from the larger command router so
/// Swift's type checker does not need to infer one oversized modifier chain.
private struct DiffPresentationCommandRouting: ViewModifier {
    @ObservedObject var store: ReviewSessionStore
    @Binding var showCanvas: Bool
    @Binding var diffPresentation: DiffPresentation

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .reviewDiffPresentationRequest)) { note in
            guard matches(note), store.selectedFile != nil else { return }
            if let rawValue = note.userInfo?["presentation"] as? String,
               let presentation = DiffPresentation(rawValue: rawValue) {
                diffPresentation = presentation
            } else {
                diffPresentation = diffPresentation == .unified ? .sideBySide : .unified
            }
            showCanvas = false
        }
    }

    private func matches(_ note: Notification) -> Bool {
        guard let object = note.object as? ReviewSessionStore else { return true }
        return object === store
    }
}

/// Viewed-aware file navigation, kept out of `CommandRoutingModifier` for the
/// same type-checker reason as `DiffPresentationCommandRouting`.
private struct ViewedNavigationCommandRouting: ViewModifier {
    @ObservedObject var store: ReviewSessionStore

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .reviewPreviousUnviewedFileRequest)) { note in
                guard matches(note) else { return }
                store.selectPreviousUnviewedFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewNextUnviewedFileRequest)) { note in
                guard matches(note) else { return }
                store.selectNextUnviewedFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewMarkViewedAndNextRequest)) { note in
                guard matches(note) else { return }
                store.markViewedAndAdvance()
            }
    }

    private func matches(_ note: Notification) -> Bool {
        guard let object = note.object as? ReviewSessionStore else { return true }
        return object === store
    }
}

/// Records where the window looks (canvas or a file) and serves Back/Forward.
/// History starts over whenever a different pull request loads.
private struct NavigationHistoryRouting: ViewModifier {
    @ObservedObject var store: ReviewSessionStore
    @Binding var showCanvas: Bool
    @State private var history = NavigationHistory<ReviewLocation>()

    private var location: ReviewLocation {
        if showCanvas { return .canvas }
        return store.selection.filePath.map(ReviewLocation.file) ?? .canvas
    }

    func body(content: Content) -> some View {
        content
            .onAppear { history.visit(location) }
            .onChange(of: location) { history.visit($0) }
            .onChange(of: store.review?.pr?.url) { _ in
                history.reset()
                history.visit(location)
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewNavigateBackRequest)) { note in
                guard matches(note) else { return }
                history.back().map(go)
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewNavigateForwardRequest)) { note in
                guard matches(note) else { return }
                history.forward().map(go)
            }
    }

    private func go(_ target: ReviewLocation) {
        switch target {
        case .canvas:
            showCanvas = true
        case .file(let path):
            store.select(filePath: path)
            showCanvas = false
        }
    }

    private func matches(_ note: Notification) -> Bool {
        guard let object = note.object as? ReviewSessionStore else { return true }
        return object === store
    }
}

/// Cmd-+ / Cmd-- / Cmd-0 zoom the canvas while it shows, and size the diff
/// text while a file is open.
private struct ZoomCommandRouting: ViewModifier {
    @ObservedObject var store: ReviewSessionStore
    @Binding var showCanvas: Bool
    @Binding var canvasZoom: CGFloat
    @AppStorage(DiffTextSize.key) private var diffFontSize = Double(DiffTextSize.defaultSize)
    @AppStorage(OverviewMode.key) private var overviewModeRaw = OverviewMode.canvas.rawValue

    /// The canvas zooms; the list and the focused diff size their text.
    private var zoomsCanvas: Bool {
        showCanvas && overviewModeRaw == OverviewMode.canvas.rawValue
    }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .reviewCanvasZoomInRequest)) { note in
                guard matches(note) else { return }
                zoom(by: 1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewCanvasZoomOutRequest)) { note in
                guard matches(note) else { return }
                zoom(by: -1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewCanvasResetZoomRequest)) { note in
                guard matches(note) else { return }
                if zoomsCanvas {
                    canvasZoom = ChangeCanvasView.defaultZoom
                } else {
                    diffFontSize = Double(DiffTextSize.defaultSize)
                }
            }
    }

    private func zoom(by direction: CGFloat) {
        if zoomsCanvas {
            canvasZoom = ChangeCanvasView.clampedZoom(canvasZoom + direction * ChangeCanvasView.zoomStep)
        } else {
            diffFontSize = Double(DiffTextSize.stepped(CGFloat(diffFontSize), by: direction))
        }
    }

    private func matches(_ note: Notification) -> Bool {
        guard let object = note.object as? ReviewSessionStore else { return true }
        return object === store
    }
}

/// The sidebar's two lists.
enum SidebarTab: Hashable {
    case inbox
    case files
}

/// The toolbar's three panes: the two overviews and the focused file.
private enum PaneChoice: Hashable {
    case canvas
    case list
    case file
}
