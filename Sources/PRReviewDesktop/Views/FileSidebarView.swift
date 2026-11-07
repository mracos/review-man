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
        let fileRows = FileSidebarTreeNode.visibleRows(
            of: FileSidebarTreeNode.build(from: store.filteredSidebarItems),
            collapsed: collapsedFolderPaths
        )

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
                        // Folder rows can be selected too (with the keyboard
                        // or a click beside the label); they are not files,
                        // so they never change the focus.
                        guard store.review?.fileIndexByPath[selection] != nil else {
                            store.objectWillChange.send()
                            return
                        }
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
                if fileRows.isEmpty {
                    Label("No matching files", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sidebar-no-file-matches")
                } else {
                    ForEach(fileRows) { row in
                        SidebarFileTreeRow(
                            store: store,
                            node: row.node,
                            depth: row.depth,
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

/// One row of the sidebar's folder tree, indented by its depth. Folders
/// toggle on click; their contents are separate rows (see `FileSidebarRow`).
private struct SidebarFileTreeRow: View {
    @ObservedObject var store: ReviewSessionStore
    let node: FileSidebarTreeNode
    let depth: Int
    @Binding var collapsedFolderPaths: Set<String>
    let highlightedSearchPath: String?

    private static let indent: CGFloat = 14

    var body: some View {
        if let item = node.item {
            let isBestSearchMatch = item.path == highlightedSearchPath
            SidebarFileItemRow(store: store, item: item, displayName: node.name)
                // Lines files up with their folder's name, past the chevron.
                .padding(.leading, CGFloat(depth) * Self.indent + (depth > 0 ? Self.indent : 0))
                .tag(item.path)
                .listRowBackground(isBestSearchMatch ? Color.accentColor.opacity(0.18) : Color.clear)
                .accessibilityIdentifier("sidebar-row-\(item.path)")
                .accessibilityHint(isBestSearchMatch ? "Best matching file for the active filter" : "")
        } else {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folderExpansion.wrappedValue ? 90 : 0))
                    .frame(width: 10)
                folderLabel
            }
            .padding(.leading, CGFloat(depth) * Self.indent)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleFolderExpansion)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebar-folder-\(node.path)")
            .accessibilityLabel("\(node.name), folder, \(node.fileCount) \(node.fileCount == 1 ? "file" : "files")")
            .accessibilityValue(folderExpansion.wrappedValue ? "expanded" : "collapsed")
            .accessibilityAddTraits(.isButton)
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
                Text("+\(additions) −\(deletions)")
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

/// One sidebar row. The tree is shown as a flat list with indentation
/// rather than nested disclosure groups: SwiftUI's outline list can trip an
/// internal assertion and crash while collapsing nested folders.
struct FileSidebarRow: Identifiable {
    let node: FileSidebarTreeNode
    let depth: Int

    var id: String { node.id }
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

    /// The rows the sidebar shows, depth first, skipping what is inside a
    /// collapsed folder.
    static func visibleRows(of tree: [FileSidebarTreeNode], collapsed: Set<String>) -> [FileSidebarRow] {
        var rows: [FileSidebarRow] = []
        func walk(_ nodes: [FileSidebarTreeNode], depth: Int) {
            for node in nodes {
                rows.append(FileSidebarRow(node: node, depth: depth))
                if node.item == nil, !collapsed.contains(node.id) {
                    walk(node.children, depth: depth + 1)
                }
            }
        }
        walk(tree, depth: 0)
        return rows
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
