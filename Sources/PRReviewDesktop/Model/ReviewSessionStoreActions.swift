import Foundation
import PRReviewKit

/// Pull request actions (merge, approve, ready, close...). The permission
/// state is fetched after every load or refresh; an action refreshes the
/// review afterwards so the header shows the new state.
extension ReviewSessionStore {

    func loadActionState() {
        actionStateTask?.cancel()
        guard let endpoint = review?.endpoint, !demoSession else {
            actionState = nil
            return
        }
        actionStateTask = Task { [weak self] in
            do {
                guard let self else { return }
                let state = try await self.service.fetchActionState(endpoint)
                try Task.checkCancellation()
                guard self.review?.endpoint == endpoint else { return }
                self.actionState = state
            } catch is CancellationError {
                // Superseded by a newer load or refresh.
            } catch {
                // Controls stay hidden; reviewing still works without them.
                AppLog.failure("actions", context: "Could not fetch pull request permissions", error: error)
                self?.actionState = nil
            }
        }
    }

    /// Approves directly, or, with unsent drafts, opens the submit sheet set
    /// to Approve so the drafts go out with the approval instead of staying
    /// behind.
    public func approve() {
        if review?.drafts.isEmpty == false {
            beginSubmit()
            submitEvent = .approve
        } else {
            perform(.approve)
        }
    }

    public func perform(_ action: PRAction) {
        guard runningAction == nil, let endpoint = review?.endpoint, !demoSession else { return }
        runningAction = action
        actionTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.service.perform(action, on: endpoint)
                self.runningAction = nil
                self.refresh(completionMessage: Self.doneMessage(for: action))
            } catch {
                guard let self else { return }
                self.runningAction = nil
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                self.banner = SessionBanner(text: "\(Self.title(for: action)) failed: \(message)", isError: true)
            }
        }
    }

    public static func title(for action: PRAction) -> String {
        switch action {
        case .merge(let method): return method.title
        case .approve: return "Approve"
        case .markReady: return "Ready for review"
        case .convertToDraft: return "Convert to draft"
        case .close: return "Close"
        case .reopen: return "Reopen"
        }
    }

    static func doneMessage(for action: PRAction) -> String {
        switch action {
        case .merge: return "Merged."
        case .approve: return "Approved."
        case .markReady: return "Marked ready for review."
        case .convertToDraft: return "Converted to draft."
        case .close: return "Closed."
        case .reopen: return "Reopened."
        }
    }
}
