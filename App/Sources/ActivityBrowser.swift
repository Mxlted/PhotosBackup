import Combine
import Foundation

enum ActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case pending = "Pending"
    case processing = "Processing"
    case failed = "Failed"
    case iCloud = "Waiting for iCloud"
    case completed = "Completed"
    var id: String { rawValue }

    func includes(_ state: UploadItem.State) -> Bool {
        switch self {
        case .all: return true
        case .pending:
            switch state { case .queued, .waitingToRetry: return true; default: return false }
        case .processing: return state.isWorking
        case .failed: if case .failed = state { return true }; return false
        case .iCloud: return state == .waitingForICloud
        case .completed: return state == .done || state == .alreadyBackedUp
        }
    }
}

/// Pure browsing operations never write to the queue. Search uses only the
/// already-displayed local name, never identifiers or diagnostic content.
enum ActivityQuery {
    static func matching(_ items: [UploadItem], filter: ActivityFilter, search: String) -> [UploadItem] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            filter.includes(item.state) && (needle.isEmpty || item.name.localizedStandardContains(needle))
        }
    }

    static func selectedFailures(_ selection: Set<UUID>, in items: [UploadItem]) -> Set<UUID> {
        Set(items.lazy.filter { selection.contains($0.id) && ActivityFilter.failed.includes($0.state) }.map(\.id))
    }
}

/// The queue may publish many progress updates per second. The view throttles
/// these before taking a snapshot, then searches away from the main actor.
/// Cancellation/generation checks keep stale queries from replacing new ones.
@MainActor
final class ActivityBrowser: ObservableObject {
    @Published private(set) var rows: [UploadItem] = []
    @Published private(set) var counts: [ActivityFilter: Int] = [:]
    @Published private(set) var overallCount = 0
    @Published private(set) var failedIDs: Set<UUID> = []
    private var task: Task<Void, Never>?
    private var revision = UUID()

    func refresh(_ items: [UploadItem], filter: ActivityFilter, search: String) {
        task?.cancel()
        let revision = UUID()
        self.revision = revision
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () -> ([UploadItem], [ActivityFilter: Int], Set<UUID>)? in
                var counts: [ActivityFilter: Int] = [:]
                var failures: Set<UUID> = []
                var matches: [UploadItem] = []
                let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
                for (index, item) in items.enumerated() {
                    if index.isMultiple(of: 128), Task.isCancelled { return nil }
                    for category in ActivityFilter.allCases where category.includes(item.state) {
                        counts[category, default: 0] += 1
                    }
                    if ActivityFilter.failed.includes(item.state) { failures.insert(item.id) }
                    if filter.includes(item.state) && (needle.isEmpty || item.name.localizedStandardContains(needle)) {
                        matches.append(item)
                    }
                }
                return (matches, counts, failures)
            }
            let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled, revision == self.revision, let result else { return }
            rows = result.0
            counts = result.1
            failedIDs = result.2
            overallCount = items.count
        }
    }

    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
