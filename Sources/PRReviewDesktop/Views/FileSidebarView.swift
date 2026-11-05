import Foundation
import SwiftUI
import PRReviewKit

/// Collapsible file sidebar: native search, a folder tree, status letters, ±
/// counts, comment badges, binary/too-large markers, and viewed checkmarks.
public struct FileSidebarView: View {
    @ObservedObject public var store: ReviewSessionStore
    @Binding public var showCanvas: Bool
    @Binding public var focusSearch: Bool

    private static let canvasSelection = "__change_canvas__"
    /// Folder paths explicitly collapsed by the reviewer. All folders start
    /// expanded so a small PR remains as scannable as the previous flat list.
    @State private var collapsedFolderPaths: Set<String> = []
    /// The first result is a non-navigating visual target for an active file
    /// filter. It helps reviewers locate the best match without opening it.
    @State private var highlightedSearchPath: String?

    private enum SidebarFocusTarget: Hashable {
        case filter
        case fileList
    }

    @FocusState private var focusedControl: SidebarFocusTarget?

    public init(
        store: ReviewSessionStore,
        showCanvas: Binding<Bool>,
        focusSearch: Binding<Bool>
    ) {
        self.store = store
        self._showCanvas = showCanvas
        self._focusSearch = focusSearch
    }

    public var body: some View {
        let fileTree = FileSidebarTreeNode.build(from: store.filteredSidebarItems)

        VStack(spacing: 0) {
            fileFilter
            Divider()

            List(selection: Binding(
            get: { showCanvas ? Self.canvasSelection : store.selection.filePath },
            set: { selection in
                // `List` can invoke its selection binding while reconciling
                // its own view update. Publishing state synchronously here
                // causes SwiftUI's "Publishing changes from within view
                // updates" loop, especially when switching Canvas → file.
                // Defer the mutation one main-loop turn instead.
                DispatchQueue.main.async {
                    if selection == Self.canvasSelection {
                        guard !showCanvas else { return }
                        AppLog.info("selection", "Sidebar selected change canvas")
                        showCanvas = true
                    } else if let selection {
                        AppLog.info("selection", "Sidebar selected file path=\(selection)")
                        showCanvas = false
                        store.select(filePath: selection)
                    }
                }
            }
        )) {
            Section("Review") {
                Label {
                    HStack {
                        Text("Canvas")
                        Spacer()
                        Text("\(store.review?.files.count ?? 0)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "square.grid.3x3")
                }
                .tag(Self.canvasSelection)
                .listRowBackground(showCanvas ? Color.accentColor.opacity(0.12) : Color.clear)
                .accessibilityIdentifier("sidebar-change-canvas")
                .accessibilityLabel("Change canvas, \(store.review?.files.count ?? 0) files")
            }

            Section("Files") {
                if fileTree.isEmpty {
                    Label("No matching files", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sidebar-no-file-matches")
                } else {
                    ForEach(fileTree) { node in
                        SidebarFileTreeRow(
                            store: store,
                            node: node,
                            collapsedFolderPaths: $collapsedFolderPaths,
                            highlightedSearchPath: highlightedSearchPath
                        )
                    }
                }
            }
            }
            .focusable()
            .focused($focusedControl, equals: .fileList)
            .onExitCommand { focusedControl = .filter }
            .accessibilityIdentifier("sidebar-file-list")
        }
        .onChange(of: store.sidebarSearch) { query in
            // Search results should never be hidden inside a folder that was
            // previously collapsed.
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedQuery.isEmpty {
                collapsedFolderPaths.removeAll()
                highlightedSearchPath = store.filteredSidebarItems.first?.path
            } else {
                highlightedSearchPath = nil
            }
        }
        .onChange(of: focusSearch) { shouldFocus in
            if shouldFocus { focusFileFilter() }
        }
        .onAppear { focusFileFilter() }
        .onReceive(NotificationCenter.default.publisher(for: .reviewCollapseAllFoldersRequest)) { note in
            guard targetsThisStore(note) else { return }
            collapsedFolderPaths = FileSidebarTreeNode.folderIDs(from: store.review?.sidebarItems ?? [])
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewExpandAllFoldersRequest)) { note in
            guard targetsThisStore(note) else { return }
            collapsedFolderPaths.removeAll()
        }
        .navigationTitle(showCanvas ? "Canvas" : "Files")
        .accessibilityIdentifier("file-sidebar")
    }

    private var fileFilter: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Filter files", text: $store.sidebarSearch)
                .textFieldStyle(.plain)
                .focused($focusedControl, equals: .filter)
                .onSubmit { focusHighlightedFileList() }
                .accessibilityIdentifier("sidebar-file-filter")

            if !store.sidebarSearch.isEmpty {
                Button {
                    store.sidebarSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear file filter")
            }

            BulkViewedMenu(store: store)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func focusFileFilter() {
        guard focusSearch else { return }
        // The sidebar can be constructed one layout pass after Cmd-F reveals
        // it, so defer setting focus until its native text field is attached.
        DispatchQueue.main.async {
            focusedControl = .filter
            focusSearch = false
        }
    }

    private func focusHighlightedFileList() {
        guard let path = highlightedSearchPath else { return }
        // List keyboard focus follows its selection. Select the filtered match
        // first so Return targets that row rather than the Canvas row.
        showCanvas = false
        store.select(filePath: path)
        focusedControl = .fileList
    }

    private func targetsThisStore(_ note: Notification) -> Bool {
        guard let target = note.object as? ReviewSessionStore else { return true }
        return target === store
    }
}

/// One recursive row in the sidebar's folder tree. A disclosure group is used
/// instead of a flat OutlineGroup so folders can start expanded and matching
/// search results can be revealed deterministically.
private struct SidebarFileTreeRow: View {
    @ObservedObject var store: ReviewSessionStore
    let node: FileSidebarTreeNode
    @Binding var collapsedFolderPaths: Set<String>
    let highlightedSearchPath: String?

    var body: some View {
        if let item = node.item {
            let isBestSearchMatch = item.path == highlightedSearchPath
            SidebarFileItemRow(store: store, item: item, displayName: node.name)
                .tag(item.path)
                .listRowBackground(isBestSearchMatch ? Color.accentColor.opacity(0.18) : Color.clear)
                .accessibilityIdentifier("sidebar-row-\(item.path)")
                .accessibilityHint(isBestSearchMatch ? "Best matching file for the active filter" : "")
        } else {
            DisclosureGroup(isExpanded: folderExpansion) {
                ForEach(node.children) { child in
                    SidebarFileTreeRow(
                        store: store,
                        node: child,
                        collapsedFolderPaths: $collapsedFolderPaths,
                        highlightedSearchPath: highlightedSearchPath
                    )
                }
            } label: {
                folderLabel
            }
            .contextMenu {
                let scope = BulkViewedScope.folder(node.path)
                let unviewed = store.viewedChangeCount(scope, viewed: true)
                if unviewed > 0 {
                    Button("Mark Folder Viewed (\(unviewed))" as String) { store.setViewed(scope, viewed: true) }
                }
                if unviewed < node.fileCount {
                    Button("Mark Folder Unviewed" as String) { store.setViewed(scope, viewed: false) }
                }
            }
            .accessibilityIdentifier("sidebar-folder-\(node.path)")
            .accessibilityLabel("\(node.name), folder, \(node.fileCount) \(node.fileCount == 1 ? "file" : "files")")
        }
    }

    private var folderExpansion: Binding<Bool> {
        Binding(
            get: { !collapsedFolderPaths.contains(node.id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedFolderPaths.remove(node.id)
                } else {
                    collapsedFolderPaths.insert(node.id)
                }
            }
        )
    }

    private var folderLabel: some View {
        Label {
            HStack {
                Text(node.name)
                    .fontWeight(.medium)
                Spacer(minLength: 4)
                Text("\(node.fileCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: folderExpansion.wrappedValue ? "folder.fill" : "folder")
                .foregroundStyle(.secondary)
        }
        // AppKit's DisclosureGroup only toggles from its disclosure indicator.
        // Make the entire visible folder label provide the same action.
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleFolderExpansion)
    }

    private func toggleFolderExpansion() {
        folderExpansion.wrappedValue.toggle()
    }
}

/// Preserves the metadata and context menu from the old flat row while the
/// tree supplies its concise, folder-relative display name.
private struct SidebarFileItemRow: View {
    @ObservedObject var store: ReviewSessionStore
    let item: FileSidebarItem
    let displayName: String

    var body: some View {
        HStack(spacing: 6) {
            Text(item.statusLetter)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 14)
                .accessibilityLabel("status \(item.statusLetter)")

            Text(title)
                .font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            Spacer(minLength: 4)

            if item.isBinary {
                Text("B").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("binary")
            }
            if item.tooLarge {
                Text("!").font(.caption2).foregroundStyle(.orange)
                    .accessibilityLabel("diff too large")
            }
            if item.threadCount > 0 {
                Text("● \(item.threadCount)")
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .accessibilityLabel("\(item.threadCount) comments")
            }
            if item.isViewed {
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .accessibilityLabel("viewed")
            }
            if let additions = item.additions, let deletions = item.deletions {
                Text(verbatim: "+\(additions) −\(deletions)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("--")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("counts unavailable")
            }
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button(item.isViewed ? "Mark Unviewed" : "Mark Viewed") {
                store.toggleViewed(filePath: item.path)
            }
            if let ext = BulkViewedScope.fileExtension(of: item.path) {
                let scope = BulkViewedScope.fileExtension(ext)
                let count = store.viewedChangeCount(scope, viewed: true)
                if count > 0 {
                    Button("Mark All .\(ext) Files Viewed (\(count))" as String) {
                        store.setViewed(scope, viewed: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.path), status \(item.statusLetter)\(item.threadCount > 0 ? ", \(item.threadCount) comments" : "")\(item.isViewed ? ", viewed" : "")")
    }

    private var title: String {
        guard let oldPath = item.oldPath, oldPath != item.path, item.statusLetter == "R" else {
            return displayName
        }
        let oldName = oldPath.split(separator: "/").last.map(String.init) ?? oldPath
        return oldName == displayName ? oldPath : "\(oldName) → \(displayName)"
    }

    private var statusColor: SwiftUI.Color {
        switch item.statusLetter {
        case "A": return .green
        case "D": return .red
        case "R": return .blue
        default: return .secondary
        }
    }
}

/// A lightweight, pure representation of the sidebar tree. Its builder runs
/// over the already filtered items, so each visible folder contains only the
/// matching files and exposes an accurate badge count.
struct FileSidebarTreeNode: Identifiable, Equatable {
    let id: String
    let path: String
    let name: String
    let item: FileSidebarItem?
    let children: [FileSidebarTreeNode]
    let fileCount: Int

    static func build(from items: [FileSidebarItem]) -> [FileSidebarTreeNode] {
        build(items, depth: 0, folderPath: "")
    }

    /// IDs for every folder in the complete (unfiltered) sidebar tree. The
    /// menu command uses these to make Collapse All deterministic even while
    /// a search result is narrowing the visible branches.
    static func folderIDs(from items: [FileSidebarItem]) -> Set<String> {
        var identifiers: Set<String> = []
        func collect(_ nodes: [FileSidebarTreeNode]) {
            for node in nodes {
                if node.item == nil { identifiers.insert(node.id) }
                collect(node.children)
            }
        }
        collect(build(from: items))
        return identifiers
    }

    private static func build(
        _ items: [FileSidebarItem],
        depth: Int,
        folderPath: String
    ) -> [FileSidebarTreeNode] {
        let folderGroups = Dictionary(grouping: items.filter {
            pathComponents($0.path).count > depth + 1
        }) { item in
            pathComponents(item.path)[depth]
        }

        let folders = folderGroups.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                let descendants = folderGroups[name] ?? []
                let path = folderPath.isEmpty ? name : "\(folderPath)/\(name)"
                return FileSidebarTreeNode(
                    id: "folder:\(path)",
                    path: path,
                    name: name,
                    item: nil,
                    children: build(descendants, depth: depth + 1, folderPath: path),
                    fileCount: descendants.count
                )
            }

        let files = items
            .filter { pathComponents($0.path).count == depth + 1 }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { item in
                FileSidebarTreeNode(
                    id: "file:\(item.path)",
                    path: item.path,
                    name: pathComponents(item.path).last ?? item.path,
                    item: item,
                    children: [],
                    fileCount: 1
                )
            }

        // Folders first mirrors Finder/Xcode source lists and makes the
        // hierarchy visually scannable before root-level files.
        return folders + files
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}

/// Entries that would change nothing are hidden.
private struct BulkViewedMenu: View {
    @ObservedObject var store: ReviewSessionStore

    var body: some View {
        Menu {
            let filtered = store.sidebarSearch.isEmpty ? nil : BulkViewedScope.paths(store.filteredSidebarItems.map(\.path))
            if let filtered {
                entry("Files Matching Filter", filtered)
            }
            entry("All Files", .all)
            entry("Deleted Files", .deleted)
            entry("Renamed Without Changes", .pureRenames)
            Divider()
            if let filtered, store.viewedChangeCount(filtered, viewed: false) > 0 {
                Button("Unmark Files Matching Filter" as String) { store.setViewed(filtered, viewed: false) }
            }
            Button("Unmark All" as String) { store.setViewed(.all, viewed: false) }
                .disabled(store.viewedChangeCount(.all, viewed: false) == 0)
        } label: {
            Image(systemName: "checkmark.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mark files viewed in bulk")
        .accessibilityIdentifier("sidebar-bulk-viewed")
    }

    @ViewBuilder
    private func entry(_ title: String, _ scope: BulkViewedScope) -> some View {
        let count = store.viewedChangeCount(scope, viewed: true)
        if count > 0 {
            Button("Mark \(title) Viewed (\(count))" as String) { store.setViewed(scope, viewed: true) }
        }
    }
}
