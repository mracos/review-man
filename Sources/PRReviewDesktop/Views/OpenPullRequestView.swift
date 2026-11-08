import SwiftUI

/// Reusable open-PR form used by both the welcome screen and the loaded-state
/// Open Pull Request sheet. Sharing one form keeps validation identical.
public struct OpenPullRequestForm: View {
    @ObservedObject public var store: ReviewSessionStore
    @Binding public var reference: String
    /// Runs as an open starts, so a sheet holding the form can close and
    /// uncover the loading screen.
    private let onOpen: () -> Void

    public init(store: ReviewSessionStore, reference: Binding<String>, onOpen: @escaping () -> Void = {}) {
        self.store = store
        self._reference = reference
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(spacing: 14) {
            TextField("https://github.com/owner/repo/pull/123 or owner/repo#123", text: $reference)
                .textFieldStyle(.roundedBorder)
                .onSubmit { open() }
                .accessibilityIdentifier("open-reference-field")

            HStack(spacing: 12) {
                Button("Open Pull Request") { open() }
                    .buttonStyle(.borderedProminent)
                    .disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("open-pr-button")
                Button("Open demo") {
                    onOpen()
                    store.openDemo()
                }
                    .accessibilityIdentifier("open-demo-button")
            }

            Text("Bare numbers (e.g. 123) work from the terminal launcher, which knows your repository. Use a full URL or owner/repo#number here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            if let banner = store.banner {
                Label(banner.text, systemImage: banner.isError ? "exclamationmark.triangle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(banner.isError ? .red : .secondary)
                    .accessibilityIdentifier("open-banner")
            }
        }
    }

    private func open() {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onOpen()
        store.open(reference: trimmed)
    }
}

/// The initial window content: enter a PR URL or shorthand, open the demo, or
/// learn about bare numbers.
public struct OpenPullRequestView: View {
    @ObservedObject public var store: ReviewSessionStore
    @State private var reference = ""

    public init(store: ReviewSessionStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("PR Review")
                .font(.title)
            Text("Review GitHub pull requests with inline comments, replies, and reviews.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            OpenPullRequestForm(store: store, reference: $reference)
                .frame(maxWidth: 420)

            DependencyStatusCard(store: store)
                .frame(maxWidth: 420)
        }
        .padding(40)
        .onAppear { store.startDependencyCheckIfNeeded() }
        .accessibilityElement(children: .contain)
    }
}
