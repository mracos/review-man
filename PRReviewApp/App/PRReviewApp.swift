import SwiftUI
import AppKit
import PRReviewKit
import PRReviewDesktop

/// The macOS application entry point. Each review window owns its own
/// `ReviewSessionStore`; `WindowGroup(for:)` gives one window per key and
/// `AppCoordinator` owns the stores and URL routing.
@main
struct PRReviewApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup("PR Review", for: String.self) { $key in
            ReviewWindowView(store: coordinator.store(for: key))
                .background(OpenWindowProxy())
                .environmentObject(coordinator)
                .onOpenURL { url in
                    coordinator.handle(url: url)
                }
                .onAppear {
                    // UI-test/demo launch path: --demo opens the offline
                    // sample review without gh, persistence, or dependency
                    // checks. --demo defaults to the .large load-test scale;
                    // see AppCoordinator for --demo-scale / --demo-files.
                    coordinator.consumeAutoOpenDemo()
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            ReviewCommands()
        }

        Settings {
            ReviewSettingsView()
        }
    }
}

/// Owns per-window session stores (keyed by the WindowGroup value) and routes
/// incoming URLs and new-window requests. Window creation uses `openWindow`,
/// which is only available from a view context, so a small proxy view inside
/// each window observes these requests and performs the open.
@MainActor
final class AppCoordinator: ObservableObject {

    @Published var pendingOpenReference: String?

    /// Weak per-window stores: a review window's view hierarchy holds the only
    /// strong reference to its `ReviewSessionStore`, so when the window closes
    /// the store (and its tasks and line cache) is released. The next lookup
    /// for the same key creates a fresh store. Dead entries are pruned on
    /// every lookup, keeping the dictionary from growing with closed windows.
    private var stores: [String: WeakStoreBox] = [:]
    private let autoOpenDemoRequest: DemoAutoOpen?

    /// Parses the demo launch arguments once. `--demo` opens the offline demo
    /// at the `.large` load-test scale by default; `--demo-scale
    /// <small|medium|large|xlarge>` picks a named tier, and
    /// `--demo-files N --demo-lines M` builds a custom-sized PR (the custom
    /// counts win over the named scale).
    init() {
        let args = CommandLine.arguments
        AppLog.info("app", "Application coordinator initialized; argumentCount=\(args.count)")
        guard args.contains("--demo") else {
            autoOpenDemoRequest = nil
            return
        }
        var scale = DemoScale.large
        var files: Int?
        var lines: Int?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--demo-scale":
                if i + 1 < args.count, let parsed = DemoScale.parse(args[i + 1]) { scale = parsed }
                i += 2
            case "--demo-files":
                if i + 1 < args.count, let v = Int(args[i + 1]), v > 0 { files = v }
                i += 2
            case "--demo-lines":
                if i + 1 < args.count, let v = Int(args[i + 1]), v > 0 { lines = v }
                i += 2
            default:
                i += 1
            }
        }
        autoOpenDemoRequest = DemoAutoOpen(scale: scale, files: files, lines: lines)
    }

    /// Consumed once per process; opens the requested demo review on the
    /// first blank window.
    func consumeAutoOpenDemo() {
        guard let request = autoOpenDemoRequest else { return }
        if let files = request.files, let lines = request.lines {
            store(for: nil).openDemo(scale: request.scale, files: files, lines: lines)
        } else {
            store(for: nil).openDemo(scale: request.scale)
        }
    }

    func store(for key: String?) -> ReviewSessionStore {
        let resolvedKey = key ?? "default"
        // Prune entries whose window has closed (store deallocated).
        stores = stores.filter { $0.value.store != nil }
        if let existing = stores[resolvedKey]?.store {
            AppLog.debug("window", "Reusing store for key=\(resolvedKey)")
            return existing
        }
        // The preference-backed resolver is shared: a user-selected executable
        // affects normal PR operations, not just the health check.
        let preference = GitHubExecutablePreference()
        let resolver = GitHubExecutableResolver(overrideURL: preference.selectedExecutableURL)
        let store = ReviewSessionStore(
            service: GitHubClient(resolver: resolver),
            persistence: ReviewPersistence.shared,
            preference: preference
        )
        stores[resolvedKey] = WeakStoreBox(store)
        AppLog.info("window", "Created store for key=\(resolvedKey)")
        return store
    }

    /// Accepts `pr-review://open/<owner>/<repo>/<number>` (from the terminal
    /// launcher) and plain `https://github.com/...` URLs.
    func handle(url: URL) {
        guard let reference = ReviewURLCoordinator.reference(for: url) else {
            AppLog.warning("url", "Ignored unsupported incoming URL; scheme=\(url.scheme ?? "none"); host=\(url.host ?? "none")")
            return
        }
        AppLog.info("url", "Accepted incoming URL; reference=\(reference)")
        // The proxy view inside each window observes this and calls
        // openWindow(value:) — creating or focusing the keyed window.
        pendingOpenReference = reference
    }

    /// Called by the proxy view to actually open/focus a window.
    func consumePendingOpen(_ open: OpenWindowAction) {
        guard let reference = pendingOpenReference else { return }
        pendingOpenReference = nil
        open(value: reference)
    }
}

/// Hosted inside every review window: observes new-window/open requests and
/// performs the `openWindow(value:)` call, which SwiftUI routes to the
/// WindowGroup — creating a fresh window for a new value or focusing the
/// existing window for the same value (duplicate-window policy).
struct OpenWindowProxy: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(coordinator.$pendingOpenReference) { reference in
                if let reference {
                    AppLog.info("window", "Opening or focusing window for key=\(reference)")
                    openWindow(value: reference)
                    coordinator.pendingOpenReference = nil
                }
            }
    }
}

/// A parsed `--demo` launch request: a named scale plus optional custom
/// file/line counts (which override the named scale).
private struct DemoAutoOpen {
    let scale: DemoScale
    let files: Int?
    let lines: Int?
}

/// Holds a store weakly so `AppCoordinator` never keeps a closed window's
/// session (and its rendered-line cache and tasks) alive.
private final class WeakStoreBox {
    weak var store: ReviewSessionStore?
    init(_ store: ReviewSessionStore) {
        self.store = store
    }
}
