import SwiftUI

/// The Settings window: what a pull request opens into, and shortcuts.
@MainActor
public struct ReviewSettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
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
