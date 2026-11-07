import SwiftUI

/// The Settings window: shortcuts, plus GitHub behaviour that writes to
/// github.com and therefore stays opt-in.
@MainActor
public struct ReviewSettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
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

@MainActor
struct GeneralSettingsView: View {
    @AppStorage(OpeningPane.key) private var pane = OpeningPane.lastOverview
    @AppStorage(OpeningPreferences.diffLayoutKey) private var diffLayout = DiffPresentation.unified
    @AppStorage(OpeningSidebar.key) private var sidebar = OpeningSidebar.unchanged

    var body: some View {
        Form {
            Picker("Open pull requests in", selection: $pane) {
                ForEach(OpeningPane.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings-opening-pane")
            Picker("Diff layout", selection: $diffLayout) {
                ForEach(DiffPresentation.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings-opening-diff-layout")
            Picker("Sidebar", selection: $sidebar) {
                ForEach(OpeningSidebar.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings-opening-sidebar")
            Text("Applied each time a pull request opens; the toolbar still switches them while you review. On very big pull requests the list or a file opens faster than the canvas.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 420)
    }
}
