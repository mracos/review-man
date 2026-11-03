import SwiftUI
import PRReviewKit

/// The PR title bar: number, title, author, state, branch direction, review
/// decision, and aggregate stats.
public struct PullRequestHeaderView: View {
    public let review: ReviewPresentation

    public init(review: ReviewPresentation) {
        self.review = review
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let pr = review.pr {
                    Text(verbatim: "#\(pr.number)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(pr.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    stateBadge(pr)
                }
            }
            HStack(spacing: 12) {
                if let pr = review.pr {
                    Label(pr.author, systemImage: "person.circle")
                    Label("\(pr.headRefName) → \(pr.baseRefName)", systemImage: "arrow.triangle.branch")
                    if let decision = reviewDecisionLabel {
                        Text(decision)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(verbatim: "+\(pr.additions)  −\(pr.deletions)  · \(pr.changedFiles) files")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-header")
    }

    @ViewBuilder
    private func stateBadge(_ pr: PRInfo) -> some View {
        let (label, color): (String, SwiftUI.Color) = {
            if pr.state == "MERGED" { return ("MERGED", .purple) }
            if pr.state == "CLOSED" { return ("CLOSED", .red) }
            if pr.isDraft { return ("DRAFT", .orange) }
            return ("OPEN", .green)
        }()
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var reviewDecisionLabel: String? {
        guard let decision = review.pr?.reviewDecision else { return nil }
        switch decision {
        case "APPROVED": return "approved"
        case "CHANGES_REQUESTED": return "changes requested"
        case "REVIEW_REQUIRED": return "review required"
        default: return decision.lowercased()
        }
    }
}
