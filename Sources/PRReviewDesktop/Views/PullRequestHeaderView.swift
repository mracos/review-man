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
                    if let checks = pr.checks {
                        checksLabel(checks)
                    }
                    Spacer()
                    Text(verbatim: "+\(pr.additions)  −\(pr.deletions)  · \(pr.changedFiles) files")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            if let body = review.pr?.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                // Plain text on purpose: PR bodies are untrusted input, and
                // nothing in the app renders markdown or loads remote images.
                DisclosureGroup("Description") {
                    ScrollView {
                        Text(body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
                .font(.caption)
                .accessibilityIdentifier("pr-description")
            }
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

    private func checksLabel(_ checks: PRChecksSummary) -> some View {
        let (icon, color): (String, SwiftUI.Color) = {
            if checks.failed > 0 { return ("xmark.circle", .red) }
            if checks.pending > 0 { return ("clock", .orange) }
            return ("checkmark.circle", .green)
        }()
        let parts = [
            checks.passed > 0 ? "\(checks.passed) passed" : nil,
            checks.failed > 0 ? "\(checks.failed) failed" : nil,
            checks.pending > 0 ? "\(checks.pending) pending" : nil,
        ].compactMap { $0 }
        return Label("checks: " + parts.joined(separator: ", "), systemImage: icon)
            .foregroundStyle(color)
            .accessibilityIdentifier("pr-checks")
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
