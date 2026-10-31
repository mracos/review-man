import SwiftUI

/// The Settings window: shortcuts, plus GitHub behaviour that writes to
/// github.com and therefore stays opt-in.
@MainActor
public struct ReviewSettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            ShortcutSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            GitHubSettingsView()
                .tabItem { Label("GitHub", systemImage: "arrow.triangle.2.circlepath") }
        }
    }
}

@MainActor
struct GitHubSettingsView: View {
    @AppStorage(ViewedSyncPreference.key) private var syncViewed = false

    var body: some View {
        Form {
            Toggle("Sync viewed files with GitHub", isOn: $syncViewed)
                .accessibilityIdentifier("settings-sync-viewed")
            Text("Files marked viewed on github.com show as viewed here, and marking a file here marks it on github.com too. Applies from the next load or refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 420)
    }
}
