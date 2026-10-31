import SwiftUI
import PRReviewKit

/// Path, viewed checkbox and "viewed + next" for the file in the focused diff,
/// so finishing a file never needs the sidebar or the toolbar.
struct FocusedFileBar: View {
    @ObservedObject var store: ReviewSessionStore
    let file: DiffFile

    var body: some View {
        let isViewed = store.review?.viewed.contains(file.path) ?? false
        HStack(spacing: 10) {
            Text(file.path)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Toggle("Viewed", isOn: Binding(
                get: { isViewed },
                set: { _ in store.toggleViewed(filePath: file.path) }
            ))
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("focused-file-viewed")
            Button("Viewed & Next") {
                store.markViewedAndAdvance()
            }
            .help("Mark this file viewed and open the next unviewed file")
            .accessibilityIdentifier("focused-file-viewed-next")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }
}
