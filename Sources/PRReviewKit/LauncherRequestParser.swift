import Foundation

/// Pure launcher argument handling for the desktop launcher: parses
/// command-line references into a normalized `pr-review://` URL the app
/// understands. Bare numbers are resolved against the terminal working
/// directory by the caller and normalized here.
public enum LauncherRequestParser {

    /// A parsed launch request.
    public enum Request: Equatable {
        case demo
        case open(reference: String)
        case invalid(reason: String)
    }

    /// Parses the launcher arguments (excluding argv[0]).
    public static func parse(_ args: [String]) -> Request {
        var demo = false
        var reference: String?
        for arg in args {
            switch arg {
            case "--demo":
                demo = true
            case "--help", "-h", "--version", "-V":
                return .invalid(reason: "\(arg) is handled by the launcher itself")
            default:
                if arg.hasPrefix("-") {
                    return .invalid(reason: "Unknown option: \(arg)")
                }
                if reference != nil {
                    return .invalid(reason: "Only one PR reference is accepted.")
                }
                reference = arg
            }
        }
        if demo && reference != nil {
            return .invalid(reason: "--demo cannot be combined with a PR reference.")
        }
        if demo {
            return .demo
        }
        guard let reference else {
            return .invalid(reason: "Missing PR reference.")
        }
        return .open(reference: reference)
    }

    /// Normalizes a qualified reference (full URL or owner/repo#number) into
    /// the `pr-review://open/owner/repo/number` URL the app opens.
    public static func appURL(for reference: String) -> String? {
        guard let endpoint = resolveEndpoint(from: reference) else { return nil }
        return "pr-review://open/\(endpoint.owner)/\(endpoint.repo)/\(endpoint.number)"
    }

    /// Accepts exactly `https://github.com/owner/repo/pull/N` (no leading or
    /// trailing whitespace, no http, no trailing slash, no extra path
    /// components) and `owner/repo#number` (pure parsing; no `gh` involved).
    /// Bare numbers are resolved by the caller.
    public static func resolveEndpoint(from reference: String) -> PREndpoint? {
        let trimmed = reference
        guard trimmed == reference.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if trimmed.hasPrefix("https://github.com/") {
            guard !trimmed.hasSuffix("/") else { return nil }
            // Exactly owner/repo/pull/N with NO empty path components
            // (doubled slashes are rejected).
            let rest = trimmed.dropFirst("https://github.com/".count)
            let path = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard path.count == 4,
                  path.allSatisfy({ !$0.isEmpty }),
                  path[2] == "pull",
                  let number = Int(path[3]), number > 0 else { return nil }
            return PREndpoint(validatingOwner: path[0], repo: path[1], number: number)
        }
        guard trimmed.contains("#") else { return nil }
        let parts = trimmed.split(separator: "#", maxSplits: 1)
        guard parts.count == 2, let number = Int(parts[1]), number > 0 else { return nil }
        let repoParts = parts[0].split(separator: "/")
        guard repoParts.count == 2 else { return nil }
        return PREndpoint(validatingOwner: String(repoParts[0]), repo: String(repoParts[1]), number: number)
    }
}
