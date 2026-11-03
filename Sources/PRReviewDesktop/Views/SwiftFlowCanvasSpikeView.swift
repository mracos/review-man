import Foundation
import SwiftUI
import SwiftFlow
import PRReviewKit

enum SwiftFlowCanvasSpike {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--swiftflow-canvas")
    }
}

/// SwiftFlow-backed rendering spike for the change canvas.
///
/// This deliberately keeps `CanvasTree`, `TreeMetrics`, and `TreePlan` as the
/// application-facing adapter for now. SwiftFlow owns the viewport, pan/zoom,
/// hit testing, node rendering and edge rendering. Keeping the existing tree
/// adapter lets us preserve review-specific behavior while measuring the
/// rendering engine independently before deciding whether to adopt
/// SwiftFlow's auto-layout as a second step.
struct SwiftFlowCanvasSpikeView: View {
    struct NodeData: Equatable, Sendable {
        let canvasID: String
        let path: String
        let name: String
        let isFolder: Bool
        let descendantFileCount: Int
        let commentCount: Int
    }

    @ObservedObject var store: ReviewSessionStore
    let files: [DiffFile]
    @Binding var showCanvas: Bool
    @Binding var zoom: CGFloat

    @State private var collapsedFolderIDs: Set<String> = []
    @State private var nodes: [Node<NodeData>] = []
    @State private var edges: [FlowEdge<EmptyEdgeData>] = []
    @StateObject private var flowInstance = SwiftFlowInstance()

    private var fullTree: CanvasTree { CanvasTree.build(from: files) }

    var body: some View {
        canvasContent
        .onAppear { rebuildGraph() }
        .onChange(of: files) { _ in rebuildGraph(resetCollapse: true) }
        .onChange(of: collapsedFolderIDs) { _ in rebuildGraph() }
        .onChange(of: zoom) { newZoom in
            let current = flowInstance.getViewport().zoom
            guard abs(current - newZoom) > 0.001 else { return }
            flowInstance.zoomTo(newZoom, animated: !AppearanceSettings.reduceMotion)
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewCanvasCollapseAllFoldersRequest)) { note in
            guard targetsThisStore(note) else { return }
            collapsedFolderIDs = Set(fullTree.nodes.lazy.filter(\.isFolder).map(\.id))
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewCanvasExpandAllFoldersRequest)) { note in
            guard targetsThisStore(note) else { return }
            collapsedFolderIDs.removeAll()
        }
    }

    @ViewBuilder
    private var canvasContent: some View {
        if files.isEmpty {
            EmptyStateView(
                icon: "map",
                title: "Nothing to map",
                message: "This pull request has no changed files."
            )
        } else {
            VStack(spacing: 0) {
                toolbar
                Divider()
                flowCanvas
                    .accessibilityIdentifier("change-canvas-pane")
            }
        }
    }

    private var flowCanvas: some View {
        SwiftFlow(
            nodes: nodes,
            edges: edges,
            onNodesChange: { changes in
                nodes = applyNodeChanges(changes, nodes: nodes)
            },
            onEdgesChange: { _ in },
            onConnect: { _ in },
            nodesDraggable: false,
            nodesConnectable: false,
            elementsSelectable: true,
            panOnDrag: true,
            panOnScroll: true,
            zoomOnScroll: false,
            zoomOnPinch: true,
            zoomOnDoubleClick: false,
            fitView: true,
            onViewportChange: { viewport in
                zoom = ChangeCanvasView.clampedZoom(viewport.zoom)
            },
            onNodeClick: { node in activate(node.data) },
            swiftFlowInstance: flowInstance
        ) { node in
            nodeView(node.data)
        } overlay: {
            Background(variant: .dots)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.orange)
            Text("Change canvas")
                .font(.headline)
            Text("SwiftFlow spike")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(fullTree.folderCount) folders · \(fullTree.fileCount) files")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                flowInstance.zoomOut(animated: !AppearanceSettings.reduceMotion)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            Text("\(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 42)
            Button {
                flowInstance.zoomIn(animated: !AppearanceSettings.reduceMotion)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            Button("Reset") {
                flowInstance.zoomTo(ChangeCanvasView.defaultZoom, animated: !AppearanceSettings.reduceMotion)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            Button("Fit") {
                flowInstance.fitView(nodes: nodes, nodeSizes: flowInstance.nodeSizes)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            Button("Collapse all") {
                collapsedFolderIDs = Set(fullTree.nodes.lazy.filter(\.isFolder).map(\.id))
            }
            .buttonStyle(.borderless)
            .font(.caption)
            Button("Expand all") { collapsedFolderIDs.removeAll() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.96))
        .accessibilityIdentifier("change-canvas-toolbar")
    }

    @ViewBuilder
    private func nodeView(_ data: NodeData) -> some View {
        if data.isFolder {
            HStack(spacing: 6) {
                Image(systemName: collapsedFolderIDs.contains(data.canvasID) ? "folder.fill.badge.plus" : "folder.fill")
                    .foregroundStyle(.orange)
                Text(data.name).lineLimit(1)
                Text("\(data.descendantFileCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if data.commentCount > 0 {
                    Label("\(data.commentCount)", systemImage: "bubble.left.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)) }
            .accessibilityLabel("\(data.name) folder, \(data.descendantFileCount) files")
        } else {
            let file = files.first(where: { $0.path == data.path })
            HStack(spacing: 7) {
                Image(systemName: store.review?.viewed.contains(data.path) == true ? "checkmark.circle.fill" : "doc.text")
                    .foregroundStyle(.secondary)
                Text(data.name).lineLimit(1)
                if let file {
                    Text(verbatim: "+\(file.additions) −\(file.deletions)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if data.commentCount > 0 {
                    Label("\(data.commentCount)", systemImage: "bubble.left.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)) }
            .help("\(data.path)\nOpen focused diff")
            .contextMenu {
                Button("Open focused diff") { open(path: data.path) }
                Button(store.review?.viewed.contains(data.path) == true ? "Mark unviewed" : "Mark viewed") {
                    store.toggleViewed(filePath: data.path)
                }
            }
            .accessibilityLabel(data.path)
        }
    }

    private func activate(_ data: NodeData) {
        if data.isFolder {
            if collapsedFolderIDs.contains(data.canvasID) {
                collapsedFolderIDs.remove(data.canvasID)
            } else {
                collapsedFolderIDs.insert(data.canvasID)
            }
        } else {
            open(path: data.path)
        }
    }

    private func open(path: String) {
        store.select(filePath: path)
        showCanvas = false
    }

    private func rebuildGraph(resetCollapse: Bool = false) {
        let tree = fullTree
        if resetCollapse {
            collapsedFolderIDs = Set(tree.nodes.lazy.filter(\.isFolder).map(\.id))
        }
        let visibleTree = tree.hidingDescendants(of: collapsedFolderIDs)
        let commentCountsByPath = Dictionary(uniqueKeysWithValues: (store.review?.sidebarItems ?? []).map {
            ($0.path, $0.threadCount)
        })
        let fullCommentCounts = tree.subtreeCommentCounts(byPath: commentCountsByPath)
        let commentCountByID = Dictionary(uniqueKeysWithValues: zip(tree.nodes.map(\.id), fullCommentCounts))

        // Keep the existing deterministic tree layout for this first spike so
        // performance comparisons isolate SwiftFlow's rendering/viewport from
        // a simultaneous layout-algorithm change.
        let sizes = visibleTree.nodes.enumerated().map { index, node in
            if node.isFolder {
                return TreeMetrics.folderSize(
                    for: node.name,
                    descendantFileCount: visibleTree.subtreeFileCounts[index],
                    commentCount: commentCountByID[node.id, default: 0]
                )
            }
            return TreeMetrics.fileSize(
                for: node.file,
                commentCount: commentCountsByPath[node.path, default: 0]
            )
        }
        let plan = TreePlan.compute(
            sizes: sizes,
            depths: visibleTree.depths,
            parents: visibleTree.parents,
            columnGap: TreeMetrics.columnGap,
            rowGap: TreeMetrics.rowGap,
            padding: TreeMetrics.padding
        )

        nodes = visibleTree.nodes.enumerated().map { index, node in
            let frame = plan.frames[index]
            return Node(
                id: node.id,
                position: XYPosition(x: frame.minX, y: frame.minY),
                data: NodeData(
                    canvasID: node.id,
                    path: node.path,
                    name: node.name,
                    isFolder: node.isFolder,
                    descendantFileCount: visibleTree.subtreeFileCounts[index],
                    commentCount: commentCountByID[node.id, default: 0]
                ),
                width: frame.width,
                height: frame.height,
                draggable: false,
                selectable: true,
                connectable: false,
                deletable: false,
                sourcePosition: .right,
                targetPosition: .left
            )
        }

        edges = visibleTree.parents.enumerated().compactMap { childIndex, parentIndex in
            guard let parentIndex else { return nil }
            return FlowEdge(
                id: "edge:\(visibleTree.nodes[parentIndex].id)->\(visibleTree.nodes[childIndex].id)",
                source: visibleTree.nodes[parentIndex].id,
                target: visibleTree.nodes[childIndex].id,
                type: .smoothstep
            )
        }
    }

    private func targetsThisStore(_ note: Notification) -> Bool {
        guard let target = note.object as? ReviewSessionStore else { return true }
        return target === store
    }
}
