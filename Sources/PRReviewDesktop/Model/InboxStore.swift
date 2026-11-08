import Foundation
import PRReviewKit

/// The app-wide pull request inbox: one search per enabled section, refreshed
/// on demand, on a timer, and whenever its settings change. Shared by every
/// window, so it is fetched once; every setting is remembered across launches.
@MainActor
public final class InboxStore: ObservableObject {

    static let pageSize = 25
    static let defaultSections: [InboxSection] = [.reviewRequested, .myOpen]

    private enum Key {
        static let sections = "PRReview.inbox.sections"
        static let labels = "PRReview.inbox.labels"
        static let hiddenRepositories = "PRReview.inbox.hiddenRepositories"
        static let teamOrganizations = "PRReview.inbox.teamOrganizations"
        static let groupByRepository = "PRReview.inbox.groupByRepository"
        static let collapsed = "PRReview.inbox.collapsedSections"
        static let collapsedRepositories = "PRReview.inbox.collapsedRepositories"
    }

    private struct SectionState {
        var rows: [PRSummary] = []
        var error: String?
        var needsSetup = false
    }

    @Published public private(set) var sections: [InboxSection]
    @Published public private(set) var filter: InboxFilter
    @Published public private(set) var groupByRepository: Bool
    /// The viewer's organizations, offered for the team section.
    @Published public private(set) var organizations: [String] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastRefreshed: Date?
    @Published private var states: [InboxSection: SectionState] = [:]
    @Published private var collapsed: Set<String>
    @Published private var collapsedRepositories: Set<String>

    private let service: GitHubServing
    private let defaults: UserDefaults
    private let refreshesOnChange: Bool
    private var scope: InboxScope?
    private var pollTask: Task<Void, Never>?
    private var refreshAgain = false

    public init(service: GitHubServing, defaults: UserDefaults = .standard, refreshesOnChange: Bool = true) {
        self.service = service
        self.defaults = defaults
        self.refreshesOnChange = refreshesOnChange
        let stored = defaults.stringArray(forKey: Key.sections).map { Set($0) }
        sections = InboxSection.allCases.filter { stored?.contains($0.rawValue) ?? Self.defaultSections.contains($0) }
        filter = InboxFilter(
            labels: defaults.stringArray(forKey: Key.labels) ?? [],
            hiddenRepositories: defaults.stringArray(forKey: Key.hiddenRepositories) ?? [],
            teamOrganizations: defaults.stringArray(forKey: Key.teamOrganizations) ?? []
        )
        groupByRepository = defaults.object(forKey: Key.groupByRepository) as? Bool ?? true
        collapsed = Set(defaults.stringArray(forKey: Key.collapsed) ?? [])
        collapsedRepositories = Set(defaults.stringArray(forKey: Key.collapsedRepositories) ?? [])
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Reading

    public func rows(for section: InboxSection) -> [PRSummary] {
        states[section]?.rows ?? []
    }

    public func error(for section: InboxSection) -> String? {
        states[section]?.error
    }

    /// True for a team section with no organizations chosen yet.
    public func needsSetup(_ section: InboxSection) -> Bool {
        states[section]?.needsSetup ?? false
    }

    /// A section's rows by repository. Rows arrive most recently updated
    /// first, so repositories keep that order by their newest pull request.
    public func groupedRows(for section: InboxSection) -> [(repository: String, rows: [PRSummary])] {
        var order: [String] = []
        var byRepository: [String: [PRSummary]] = [:]
        for row in rows(for: section) {
            if byRepository[row.repository] == nil { order.append(row.repository) }
            byRepository[row.repository, default: []].append(row)
        }
        return order.map { (repository: $0, rows: byRepository[$0] ?? []) }
    }

    /// Labels on the loaded pull requests plus the ones filtered on, for the
    /// label menu.
    public var knownLabels: [String] {
        var names = Set(filter.labels)
        for state in states.values {
            for row in state.rows { names.formUnion(row.labels.map(\.name)) }
        }
        return names.sorted()
    }

    /// Repositories on the loaded pull requests plus the hidden ones, so a
    /// hidden repository can be switched back on.
    public var knownRepositories: [String] {
        var names = Set(filter.hiddenRepositories)
        for state in states.values {
            names.formUnion(state.rows.map(\.repository))
        }
        return names.sorted()
    }

    public func isHidden(_ repository: String) -> Bool {
        filter.hiddenRepositories.contains(repository)
    }

    public func isRepositoryCollapsed(_ repository: String) -> Bool {
        collapsedRepositories.contains(repository)
    }

    public func isCollapsed(_ section: InboxSection) -> Bool {
        collapsed.contains(section.rawValue)
    }

    // MARK: - Customizing

    public func setSection(_ section: InboxSection, enabled: Bool) {
        var enabledSet = Set(sections)
        if enabled { enabledSet.insert(section) } else { enabledSet.remove(section) }
        sections = InboxSection.allCases.filter(enabledSet.contains)
        defaults.set(sections.map(\.rawValue), forKey: Key.sections)
        changed()
    }

    public func toggleLabel(_ name: String) {
        updateFilter { filter in
            if let index = filter.labels.firstIndex(of: name) {
                filter.labels.remove(at: index)
            } else {
                filter.labels.append(name)
            }
        }
    }

    public func clearLabels() {
        updateFilter { $0.labels = [] }
    }

    public func hideRepository(_ repository: String) {
        updateFilter { filter in
            if !filter.hiddenRepositories.contains(repository) { filter.hiddenRepositories.append(repository) }
        }
    }

    public func showRepository(_ repository: String) {
        updateFilter { $0.hiddenRepositories.removeAll { $0 == repository } }
    }

    public func toggleRepository(_ repository: String) {
        if isHidden(repository) {
            showRepository(repository)
        } else {
            hideRepository(repository)
        }
    }

    public func toggleRepositoryCollapsed(_ repository: String) {
        if collapsedRepositories.remove(repository) == nil {
            collapsedRepositories.insert(repository)
        }
        defaults.set(collapsedRepositories.sorted(), forKey: Key.collapsedRepositories)
    }

    public func toggleTeamOrganization(_ organization: String) {
        updateFilter { filter in
            if let index = filter.teamOrganizations.firstIndex(of: organization) {
                filter.teamOrganizations.remove(at: index)
            } else {
                filter.teamOrganizations.append(organization)
            }
        }
    }

    public func setGroupByRepository(_ grouped: Bool) {
        groupByRepository = grouped
        defaults.set(grouped, forKey: Key.groupByRepository)
    }

    public func toggleCollapsed(_ section: InboxSection) {
        if collapsed.remove(section.rawValue) == nil {
            collapsed.insert(section.rawValue)
        }
        defaults.set(collapsed.sorted(), forKey: Key.collapsed)
    }

    private func updateFilter(_ change: (inout InboxFilter) -> Void) {
        change(&filter)
        defaults.set(filter.labels, forKey: Key.labels)
        defaults.set(filter.hiddenRepositories, forKey: Key.hiddenRepositories)
        defaults.set(filter.teamOrganizations, forKey: Key.teamOrganizations)
        changed()
    }

    private func changed() {
        guard refreshesOnChange else { return }
        Task { await refresh() }
    }

    // MARK: - Fetching

    /// Runs every enabled section's search concurrently. A refresh asked for
    /// while one runs is not dropped: it runs once more afterwards, so the
    /// latest settings always win.
    public func refresh() async {
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            await fetchSections()
        } while refreshAgain
    }

    private func fetchSections() async {
        if scope == nil {
            do {
                let fetched = try await service.fetchViewerScope()
                scope = fetched
                organizations = fetched.organizations
            } catch {
                AppLog.failure("inbox", context: "Fetching the viewer's organizations failed", error: error)
            }
        }

        let current = sections
        let filter = self.filter
        let service = self.service
        await withTaskGroup(of: (InboxSection, Result<[PRSummary], Error>?).self) { group in
            for section in current {
                guard let query = section.searchQuery(filter: filter) else {
                    group.addTask { (section, nil) }
                    continue
                }
                group.addTask {
                    do {
                        return (section, .success(try await service.searchPullRequests(query: query, first: Self.pageSize)))
                    } catch {
                        return (section, .failure(error))
                    }
                }
            }
            for await (section, result) in group {
                switch result {
                case nil:
                    states[section] = SectionState(needsSetup: true)
                case .success(let rows):
                    states[section] = SectionState(rows: rows)
                case .failure(let error):
                    AppLog.failure("inbox", context: "Inbox search failed; section=\(section.rawValue)", error: error)
                    states[section, default: SectionState()].error = "\(error)"
                }
            }
        }
        lastRefreshed = Date()
        AppLog.info("inbox", "Refreshed inbox; sections=\(current.count)")
    }

    /// Refreshes now and then every `interval` until the store goes away;
    /// calling it again while polling is a no-op.
    public func startPolling(every interval: Duration = .seconds(300)) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }
}
