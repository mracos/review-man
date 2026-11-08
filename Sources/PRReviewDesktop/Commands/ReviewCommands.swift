import SwiftUI
import PRReviewKit

/// SwiftUI Commands for the review window. The active window publishes its
/// observable store with `.focusedSceneObject`, so command enablement refreshes
/// as loading completes and review state changes.
public struct ReviewCommands: Commands {

    @FocusedObject private var focusedStore: ReviewSessionStore?
    @ObservedObject private var shortcutPreferences = ReviewShortcutPreferences.shared

    public init() {}

    public var body: some Commands {
        // The system File > New Window (Cmd-N) is provided by WindowGroup(for:)
        // and is scoped correctly; we only add Open Pull Request.
        CommandGroup(after: .newItem) {
            Button("Open Pull Request…") {
                NotificationCenter.default.post(name: .reviewOpenRequest, object: focusedStore)
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(focusedStore == nil)
        }

        CommandGroup(after: .undoRedo) {
            Button("Undo Draft") {
                focusedStore?.undoDraft()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!availability.canUndo)

            Button("Redo Draft") {
                focusedStore?.redoDraft()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!availability.canRedo)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find in File") {
                focusedStore?.beginFind()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!availability.canFind || focusedStore?.selectedFile == nil)

            Button("Find Next") {
                focusedStore?.findNext()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(focusedStore?.isFinding != true)

            Button("Find Previous") {
                focusedStore?.findPrevious()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(focusedStore?.isFinding != true)

            Button("Focus File Filter") {
                focusedStore?.requestFocus = .sidebarSearch
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(!availability.canFind)
        }

        CommandMenu("Review") {
            Button("Add Comment") {
                focusedStore?.requestFocus = .diff
                NotificationCenter.default.post(name: .reviewAddCommentRequest, object: focusedStore)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!availability.canAddComment)

            Button("Reply") {
                focusedStore?.requestFocus = .diff
                NotificationCenter.default.post(name: .reviewReplyRequest, object: focusedStore)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!availability.canReply)

            Button("Resolve / Unresolve") {
                focusedStore?.requestFocus = .diff
                NotificationCenter.default.post(name: .reviewResolveRequest, object: focusedStore)
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(!availability.canResolve)

            Button("Toggle Viewed") {
                focusedStore?.requestFocus = .diff
                NotificationCenter.default.post(name: .reviewToggleViewedRequest, object: focusedStore)
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .disabled(!availability.canToggleViewed)

            Divider()

            Menu("Hide Comments by…") {
                if let names = focusedStore?.reviewerNames, !names.isEmpty {
                    ForEach(names, id: \.self) { name in
                        Button(name) {
                            focusedStore?.hideReviewer(name)
                        }
                    }
                } else {
                    Text("No commenters yet")
                }
            }
            .disabled(!availability.canHideReviewer)

            Button("Show Hidden Comments") {
                focusedStore?.unhideAllReviewers()
            }
            .disabled(!availability.canShowHiddenComments)

            Divider()

            Button("Submit Review…") {
                focusedStore?.requestFocus = .submitSheet
                NotificationCenter.default.post(name: .reviewSubmitRequest, object: focusedStore)
            }
            .keyboardShortcut(KeyEquivalent.return, modifiers: [.command, .shift])
            .disabled(!availability.canSubmit)

            Button("Refresh") {
                focusedStore?.requestFocus = .diff
                NotificationCenter.default.post(name: .reviewRefreshRequest, object: focusedStore)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!availability.canRefresh)
        }

        CommandMenu("Diff") {
            Button("Unified") {
                NotificationCenter.default.post(
                    name: .reviewDiffPresentationRequest,
                    object: focusedStore,
                    userInfo: ["presentation": DiffPresentation.unified.rawValue]
                )
            }
            .disabled(!availability.canToggleViewed)

            Button("Side by Side") {
                NotificationCenter.default.post(
                    name: .reviewDiffPresentationRequest,
                    object: focusedStore,
                    userInfo: ["presentation": DiffPresentation.sideBySide.rawValue]
                )
            }
            .disabled(!availability.canToggleViewed)

            Divider()

            Button("Toggle Diff Layout") {
                NotificationCenter.default.post(name: .reviewDiffPresentationRequest, object: focusedStore)
            }
            .keyboardShortcut(shortcutPreferences.shortcut(for: .toggleDiffLayout).keyboardShortcut)
            .disabled(!availability.canToggleViewed)
        }

        CommandMenu("Canvas") {
            Button("Find File or Folder…") {
                NotificationCenter.default.post(
                    name: .reviewCanvasSearchRequest,
                    object: focusedStore
                )
            }
            .keyboardShortcut(shortcutPreferences.shortcut(for: .findCanvasNode).keyboardShortcut)
            .disabled(focusedStore == nil)

            Divider()

            Button("Zoom In") {
                NotificationCenter.default.post(
                    name: .reviewCanvasZoomInRequest,
                    object: focusedStore
                )
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(focusedStore == nil)

            Button("Zoom Out") {
                NotificationCenter.default.post(
                    name: .reviewCanvasZoomOutRequest,
                    object: focusedStore
                )
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(focusedStore == nil)

            Button("Reset Zoom") {
                NotificationCenter.default.post(
                    name: .reviewCanvasResetZoomRequest,
                    object: focusedStore
                )
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(focusedStore == nil)

            Divider()

            Button("Collapse Focused Folder One Level") {
                NotificationCenter.default.post(
                    name: .reviewCanvasCollapseFolderRequest,
                    object: focusedStore
                )
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
            .disabled(focusedStore == nil)

            Button("Expand Focused Folder One Level") {
                NotificationCenter.default.post(
                    name: .reviewCanvasExpandFolderRequest,
                    object: focusedStore
                )
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
            .disabled(focusedStore == nil)

            Divider()

            Button("Collapse All Folders") {
                NotificationCenter.default.post(
                    name: .reviewCanvasCollapseAllFoldersRequest,
                    object: focusedStore
                )
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .control, .option])
            .disabled(focusedStore == nil)

            Button("Expand All Folders") {
                NotificationCenter.default.post(
                    name: .reviewCanvasExpandAllFoldersRequest,
                    object: focusedStore
                )
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .control, .option])
            .disabled(focusedStore == nil)
        }

        CommandMenu("Navigate") {
            Button("Toggle Sidebar") {
                NotificationCenter.default.post(name: .reviewToggleSidebarRequest, object: focusedStore)
            }
            .keyboardShortcut(shortcutPreferences.shortcut(for: .toggleSidebar).keyboardShortcut)

            Divider()

            Button("Collapse All Folders") {
                NotificationCenter.default.post(name: .reviewCollapseAllFoldersRequest, object: focusedStore)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(!availability.canFind)

            Button("Expand All Folders") {
                NotificationCenter.default.post(name: .reviewExpandAllFoldersRequest, object: focusedStore)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(!availability.canFind)

            Divider()

            Button("Previous File") {
                NotificationCenter.default.post(name: .reviewPreviousFileRequest, object: focusedStore)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next File") {
                NotificationCenter.default.post(name: .reviewNextFileRequest, object: focusedStore)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Hunk") {
                NotificationCenter.default.post(name: .reviewPreviousHunkRequest, object: focusedStore)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option, .shift])
            Button("Next Hunk") {
                NotificationCenter.default.post(name: .reviewNextHunkRequest, object: focusedStore)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
        }
    }

    private var availability: ReviewCommandAvailability {
        guard let store = focusedStore else {
            return ReviewCommandAvailability(context: ReviewCommandContext(
                state: .welcome, isDemo: false, hasSelectedFile: false,
                hasCommentableSelection: false, selectedThreadIsActive: false,
                selectedThreadHasRootComment: false, canUndo: false, canRedo: false,
                draftEditorOpen: false, submitHidden: true, isSubmitting: false,
                canSubmit: false, hasPRURL: false
            ))
        }
        return ReviewCommandAvailability(context: store.commandContext())
    }
}

public extension Notification.Name {
    static let reviewNewWindowRequest = Notification.Name("review.newWindow")
    static let reviewOpenRequest = Notification.Name("review.open")
    static let reviewFindRequest = Notification.Name("review.find")
    static let reviewAddCommentRequest = Notification.Name("review.addComment")
    static let reviewReplyRequest = Notification.Name("review.reply")
    static let reviewResolveRequest = Notification.Name("review.resolve")
    static let reviewToggleViewedRequest = Notification.Name("review.toggleViewed")
    static let reviewSubmitRequest = Notification.Name("review.submit")
    static let reviewRefreshRequest = Notification.Name("review.refresh")
    static let reviewToggleSidebarRequest = Notification.Name("review.toggleSidebar")
    static let reviewDiffPresentationRequest = Notification.Name("review.diffPresentation")
    static let reviewCollapseAllFoldersRequest = Notification.Name("review.collapseAllFolders")
    static let reviewExpandAllFoldersRequest = Notification.Name("review.expandAllFolders")
    static let reviewCanvasSearchRequest = Notification.Name("review.canvasSearch")
    static let reviewCanvasZoomInRequest = Notification.Name("review.canvasZoomIn")
    static let reviewCanvasZoomOutRequest = Notification.Name("review.canvasZoomOut")
    static let reviewCanvasResetZoomRequest = Notification.Name("review.canvasResetZoom")
    static let reviewCanvasCollapseFolderRequest = Notification.Name("review.canvasCollapseFolder")
    static let reviewCanvasExpandFolderRequest = Notification.Name("review.canvasExpandFolder")
    static let reviewCanvasCollapseAllFoldersRequest = Notification.Name("review.canvasCollapseAllFolders")
    static let reviewCanvasExpandAllFoldersRequest = Notification.Name("review.canvasExpandAllFolders")
    static let reviewReturnToCanvasRequest = Notification.Name("review.returnToCanvas")
    static let reviewPreviousFileRequest = Notification.Name("review.previousFile")
    static let reviewNextFileRequest = Notification.Name("review.nextFile")
    static let reviewPreviousHunkRequest = Notification.Name("review.previousHunk")
    static let reviewNextHunkRequest = Notification.Name("review.nextHunk")
}
