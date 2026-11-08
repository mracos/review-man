import SwiftUI

/// Find in the open file: Return or Cmd-G for the next match, Shift-Return
/// or Shift-Cmd-G for the previous one, Escape to close.
struct FindBar: View {
    @ObservedObject var store: ReviewSessionStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in file", text: Binding(get: { store.findQuery }, set: { store.setFindQuery($0) }))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    if NSEvent.modifierFlags.contains(.shift) { store.findPrevious() } else { store.findNext() }
                    focused = true
                }
                .onExitCommand { store.endFind() }
                .accessibilityIdentifier("find-field")
            if let position = store.findMatchPosition {
                Text(verbatim: position.count == 0 ? "No matches" : "\(position.index) of \(position.count)")
                    .font(.caption)
                    .foregroundStyle(position.count == 0 ? .red : .secondary)
                    .monospacedDigit()
            }
            Button { store.findPrevious() } label: { Image(systemName: "chevron.up") }
                .help("Previous match (Shift-Cmd-G)")
            Button { store.findNext() } label: { Image(systemName: "chevron.down") }
                .help("Next match (Cmd-G)")
            Button("Done") { store.endFind() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .onAppear { focused = true }
        .onChange(of: store.isFinding) { if $0 { focused = true } }
        .accessibilityIdentifier("find-bar")
    }
}
