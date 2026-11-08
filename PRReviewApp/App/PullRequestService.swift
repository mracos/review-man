import AppKit
import PRReviewKit

/// The Services menu's "Open in PR Review" (declared under `NSServices` in
/// Info.plist): opens the first pull request in the selected text, through
/// the same `pr-review://` route as the terminal launcher.
final class PullRequestService: NSObject {
    private let open: (URL) -> Void

    init(open: @escaping (URL) -> Void) {
        self.open = open
    }

    @objc func openPullRequest(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL) ?? ""
        guard let endpoint = PullRequestTextScanner.endpoint(in: text),
              let url = URL(string: "pr-review://open/\(endpoint.owner)/\(endpoint.repo)/\(endpoint.number)") else {
            AppLog.warning("service", "No pull request in the selected text")
            error.pointee = "The selection has no GitHub pull request link or owner/repo#number."
            return
        }
        AppLog.info("service", "Opening \(endpoint) from the Services menu")
        NSApp.activate(ignoringOtherApps: true)
        open(url)
    }
}
