import SwiftUI
import PRReviewKit

/// The inbox: every enabled section's pull requests across repositories,
/// optionally grouped by repository, narrowed by the filter menu. Choosing a
/// pull request opens it in this window.
struct InboxSidebarView: View {
    @ObservedObject var inbox: InboxStore
    @ObservedObject var store: ReviewSessionStore

    var body: some View {
        List {
            if !inbox.filter.labels.isEmpty {
                activeLabelFilter
            }
            ForEach(inbox.sections) { section in
                Section {
                    if !inbox.isCollapsed(section) {
                        sectionRows(section)
                    }
                } header: {
                    sectionHeader(section)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItemGroup {
                filterMenu
                Button {
                    Task { await inbox.refresh() }
                } label: {
                    Label("Refresh Inbox", systemImage: "arrow.clockwise")
                }
                .disabled(inbox.isRefreshing)
                .help("Refresh the inbox")
            }
        }
        .accessibilityIdentifier("inbox-sidebar")
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionRows(_ section: InboxSection) -> some View {
        if inbox.needsSetup(section) {
            Text("Choose organizations for the team section in the filter menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let error = inbox.error(for: section) {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        } else if inbox.rows(for: section).isEmpty {
            Text(inbox.lastRefreshed == nil ? "Loading..." : "Nothing here")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if inbox.groupByRepository {
            ForEach(inbox.groupedRows(for: section), id: \.repository) { group in
                repositoryHeader(group.repository, count: group.rows.count, section: section)
                if !inbox.isRepositoryCollapsed(group.repository) {
                    ForEach(group.rows) { row in
                        rowView(row, showsRepository: false)
                            .padding(.leading, 12)
                    }
                }
            }
        } else {
            ForEach(inbox.rows(for: section)) { row in
                rowView(row, showsRepository: true)
            }
        }
    }

    private func rowView(_ row: PRSummary, showsRepository: Bool) -> some View {
        InboxRowView(row: row, showsRepository: showsRepository, isOpen: row.endpoint == store.review?.endpoint)
            .contentShape(Rectangle())
            .onTapGesture { open(row) }
            .contextMenu { hideRepositoryButton(row.repository) }
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("inbox-row-\(row.repository)#\(row.number)")
    }

    private func repositoryHeader(_ repository: String, count: Int, section: InboxSection) -> some View {
        let collapsed = inbox.isRepositoryCollapsed(repository)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { inbox.toggleRepositoryCollapsed(repository) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Image(systemName: "folder")
                Text(repository)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                if collapsed {
                    Text("\(count)")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show \(repository)'s pull requests" : "Fold \(repository)")
        .contextMenu { hideRepositoryButton(repository) }
        .accessibilityIdentifier("inbox-repo-\(section.id)-\(repository)")
    }

    private func sectionHeader(_ section: InboxSection) -> some View {
        let collapsed = inbox.isCollapsed(section)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { inbox.toggleCollapsed(section) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(section.title)
                Spacer()
                Text(countLabel(inbox.rows(for: section).count))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show \(section.title)" : "Hide \(section.title)")
        .accessibilityIdentifier("inbox-section-\(section.id)")
    }

    private var activeLabelFilter: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.tint)
            Text("Labels: " + inbox.filter.labels.joined(separator: ", "))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Clear") { inbox.clearLabels() }
                .buttonStyle(.link)
        }
        .font(.caption)
        .accessibilityIdentifier("inbox-active-label-filter")
    }

    // MARK: - Filter menu

    private var filterMenu: some View {
        Menu {
            Section("Sections") {
                ForEach(InboxSection.allCases) { section in
                    Toggle(section.title, isOn: Binding(
                        get: { inbox.sections.contains(section) },
                        set: { inbox.setSection(section, enabled: $0) }
                    ))
                }
            }
            Menu("Team Organizations") {
                if inbox.organizations.isEmpty {
                    Text("No organizations")
                }
                ForEach(inbox.organizations, id: \.self) { organization in
                    Toggle(organization, isOn: Binding(
                        get: { inbox.filter.teamOrganizations.contains(organization) },
                        set: { _ in inbox.toggleTeamOrganization(organization) }
                    ))
                }
            }
            Menu("Labels") {
                if inbox.knownLabels.isEmpty {
                    Text("No labels on these pull requests")
                }
                ForEach(inbox.knownLabels, id: \.self) { label in
                    Toggle(label, isOn: Binding(
                        get: { inbox.filter.labels.contains(label) },
                        set: { _ in inbox.toggleLabel(label) }
                    ))
                }
                Divider()
                Button("Clear Label Filter") { inbox.clearLabels() }
                    .disabled(inbox.filter.labels.isEmpty)
            }
            Menu("Repositories") {
                if inbox.knownRepositories.isEmpty {
                    Text("No repositories yet")
                }
                ForEach(inbox.knownRepositories, id: \.self) { repository in
                    Toggle(repository, isOn: Binding(
                        get: { !inbox.isHidden(repository) },
                        set: { _ in inbox.toggleRepository(repository) }
                    ))
                }
            }
            Divider()
            Toggle("Group by Repository", isOn: Binding(
                get: { inbox.groupByRepository },
                set: { inbox.setGroupByRepository($0) }
            ))
        } label: {
            Label("Filter Inbox", systemImage: isFiltered
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .help("Choose sections, organizations, labels and repositories")
        .accessibilityIdentifier("inbox-filter-menu")
    }

    private var isFiltered: Bool {
        !inbox.filter.labels.isEmpty || !inbox.filter.hiddenRepositories.isEmpty
    }

    private func hideRepositoryButton(_ repository: String) -> some View {
        Button("Hide \(repository)") { inbox.hideRepository(repository) }
    }

    // MARK: - Actions

    /// A full page means the search had more than it returned.
    private func countLabel(_ count: Int) -> String {
        count >= InboxStore.pageSize ? "\(count)+" : "\(count)"
    }

    private func open(_ row: PRSummary) {
        guard let endpoint = row.endpoint, endpoint != store.review?.endpoint else { return }
        store.open(reference: endpoint.description)
    }
}

private struct InboxRowView: View {
    let row: PRSummary
    let showsRepository: Bool
    let isOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(verbatim: showsRepository ? "\(row.repository) #\(row.number)" : "#\(row.number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                checksIcon
            }
            Text(row.title)
                .lineLimit(2)
                .fontWeight(isOpen ? .semibold : .regular)
            HStack(spacing: 6) {
                Text(row.author)
                if row.isDraft { Text("draft").foregroundStyle(.orange) }
                if let decision = decisionLabel { Text(decision).foregroundStyle(decisionColor) }
                if row.state != "OPEN" { Text(row.state.lowercased()).foregroundStyle(.purple) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !row.labels.isEmpty {
                labelChips
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isOpen ? Color.accentColor.opacity(0.15) : nil)
    }

    private var labelChips: some View {
        let shown = row.labels.prefix(3)
        return HStack(spacing: 4) {
            ForEach(Array(shown), id: \.name) { label in
                LabelChip(label: label)
            }
            if row.labels.count > shown.count {
                Text(verbatim: "+\(row.labels.count - shown.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var checksIcon: some View {
        switch row.checksState {
        case "SUCCESS":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Checks passed")
        case "FAILURE", "ERROR":
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Checks failed")
        case "PENDING", "EXPECTED":
            Image(systemName: "clock.fill").foregroundStyle(.orange).help("Checks running")
        default:
            EmptyView()
        }
    }

    private var decisionLabel: String? {
        switch row.reviewDecision {
        case "APPROVED": return "approved"
        case "CHANGES_REQUESTED": return "changes requested"
        case "REVIEW_REQUIRED": return "review required"
        default: return nil
        }
    }

    private var decisionColor: Color {
        row.reviewDecision == "APPROVED" ? .green : .orange
    }
}

/// A GitHub label in its own color, with dark or light text for contrast.
private struct LabelChip: View {
    let label: PRLabel

    var body: some View {
        let (background, isLight) = Self.color(hex: label.color)
        Text(label.name)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(background, in: Capsule())
            .foregroundStyle(isLight ? Color.black : Color.white)
    }

    private static func color(hex: String) -> (Color, isLight: Bool) {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return (Color.secondary.opacity(0.3), false) }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return (Color(red: red, green: green, blue: blue), luminance > 0.6)
    }
}
