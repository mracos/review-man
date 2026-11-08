import Foundation

/// Finds a pull request in free text, such as a selection handed over by the
/// Services menu: a link may carry extra path (`/files`, `#diff-1`) and a
/// shorthand `owner/repo#123` may sit among other words. The earliest one wins.
public enum PullRequestTextScanner {

    private static let name = "[A-Za-z0-9_.-]+"
    private static let link = try! NSRegularExpression(
        pattern: "https://github\\.com/(\(name))/(\(name))/pull/(\\d+)"
    )
    private static let shorthand = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_./-])(\(name))/(\(name))#(\\d+)\\b"
    )

    public static func endpoint(in text: String) -> PREndpoint? {
        let range = NSRange(text.startIndex..., in: text)
        let matches = [link, shorthand]
            .compactMap { $0.firstMatch(in: text, range: range) }
            .sorted { $0.range.location < $1.range.location }
        for match in matches {
            let part = { (index: Int) in (text as NSString).substring(with: match.range(at: index)) }
            if let number = Int(part(3)),
               let endpoint = PREndpoint(validatingOwner: part(1), repo: part(2), number: number) {
                return endpoint
            }
        }
        return nil
    }
}
