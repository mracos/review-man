import SwiftUI
import PRReviewKit

/// Merge, approve, ready/draft and close/reopen for the loaded pull request.
/// Only actions the viewer is allowed to take are shown; merge and close ask
/// for confirmation first.
struct PRActionsBar: View {
    @ObservedObject var store: ReviewSessionStore
    let actions: PRActionState

    @State private var pendingMerge: MergeMethod?
    @State private var confirmingClose = false

    var body: some View {
        HStack(spacing: 8) {
            if store.runningAction != nil {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if actions.canMarkReady {
                Button("Ready for review" as String) { store.perform(.markReady) }
            }
            if actions.canConvertToDraft {
                Button("Convert to draft" as String) { store.perform(.convertToDraft) }
            }
            if actions.canClose {
                Button("Close" as String) { confirmingClose = true }
            }
            if actions.canReopen {
                Button("Reopen" as String) { store.perform(.reopen) }
            }
            if actions.canApprove {
                Button {
                    store.approve()
                } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                .help(store.review?.drafts.isEmpty == false
                      ? "Opens Submit Review so your drafts are sent with the approval"
                      : "Approve this pull request")
            }
            mergeControl
        }
        .controlSize(.small)
        .disabled(store.runningAction != nil)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-actions")
        .confirmationDialog(
            "Merge this pull request?",
            isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
            presenting: pendingMerge
        ) { method in
            Button(method.title) { store.perform(.merge(method)) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Close this pull request without merging?", isPresented: $confirmingClose) {
            Button("Close pull request", role: .destructive) { store.perform(.close) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var mergeControl: some View {
        let methods = actions.mergeMethods
        if let first = methods.first {
            HStack(spacing: 2) {
                Button(first.title) { pendingMerge = first }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                if methods.count > 1 {
                    Menu {
                        ForEach(methods) { method in
                            Button(method.title) { pendingMerge = method }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Other merge methods")
                }
            }
        }
    }
}
