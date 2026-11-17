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
    static let pageSize = 200

    /// Keep the default view useful during a large backup: active/attention
    /// rows, the next waiting items, and recent completions. Filters and search
    /// page through all matches; Show More expands either view.
    static func visible(_ matches: [UploadItem], summarized: Bool, limit: Int) -> [UploadItem] {
        guard summarized else { return Array(matches.prefix(limit)) }
        let extra = max(0, limit - pageSize)
        var queued: [Int] = []
        var finished: [Int] = []
        var working: [Int] = []
        var other: [Int] = []
        for (index, item) in matches.enumerated() {
            switch item.state {
            case .queued: queued.append(index)
            case .done, .alreadyBackedUp: finished.append(index)
            default:
                if item.state.isWorking { working.append(index) }
                else { other.append(index) }
            }
        }
        let indices = IndexSet(working + queued.prefix(20 + extra) + finished.suffix(50 + extra) + other.prefix(limit))
        return indices.map { matches[$0] }
    }

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
    @Published private(set) var matchingCount = 0
    @Published private(set) var failedIDs: Set<UUID> = []
    private var task: Task<Void, Never>?
    private var revision = UUID()

    func refresh(_ items: [UploadItem], filter: ActivityFilter, search: String, limit: Int = ActivityQuery.pageSize) {
        task?.cancel()
        let revision = UUID()
        self.revision = revision
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () -> ([UploadItem], [ActivityFilter: Int], Set<UUID>, Int)? in
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
                return (ActivityQuery.visible(matches, summarized: filter == .all && needle.isEmpty, limit: limit),
                        counts, failures, matches.count)
            }
            let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled, revision == self.revision, let result else { return }
            rows = result.0
            counts = result.1
            failedIDs = result.2
            overallCount = items.count
            matchingCount = result.3
        }
    }

    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
