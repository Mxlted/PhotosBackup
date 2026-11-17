import XCTest
@testable import PhotosBackup

final class ActivityBrowserTests: XCTestCase {
    private func item(_ state: UploadItem.State, name: String = "Local Display Name") -> UploadItem {
        var item = UploadItem(source: .asset(localIdentifier: UUID().uuidString), name: name)
        item.state = state
        return item
    }

    func testFiltersSeparateWorkingPendingCloudFailuresAndSuccessfulCompletions() {
        let states: [UploadItem.State] = [.queued, .waitingToRetry(attempt: 1), .exporting,
            .hashing(fraction: 0.5), .checkingDuplicate, .uploading(fraction: 0.5), .finalizing,
            .waitingForICloud, .failed(reason: "Needs attention", retryable: true), .done, .alreadyBackedUp, .cancelled]
        let items = states.map { item($0) }
        let expected: [ActivityFilter: Int] = [.all: 12, .pending: 2, .processing: 5, .iCloud: 1, .failed: 1, .completed: 2]
        for (filter, count) in expected {
            XCTAssertEqual(ActivityQuery.matching(items, filter: filter, search: "").count, count)
        }
        XCTAssertEqual(items.map(\.state), states, "browsing cannot mutate queue state")
    }

    func testSearchOnlyMatchesDisplayedNameAndCombinesWithFilter() {
        let items = [item(.done, name: "Café.JPG"), item(.queued, name: "cafe-original.JPG"),
                     item(.failed(reason: "Café", retryable: false), name: "Other.JPG")]
        XCTAssertEqual(ActivityQuery.matching(items, filter: .all, search: " café ").count, 2)
        XCTAssertEqual(ActivityQuery.matching(items, filter: .completed, search: "café").map(\.id), [items[0].id])
        XCTAssertTrue(ActivityQuery.matching(items, filter: .all, search: items[0].source.assetIdentifier!).isEmpty)
    }

    func testSelectionDropsRemovedRetriedAndCompletedRows() {
        let failed = item(.failed(reason: "Retry", retryable: true))
        let working = item(.uploading(fraction: 0))
        let complete = item(.done)
        let selection: Set<UUID> = [failed.id, working.id, complete.id, UUID()]
        XCTAssertEqual(ActivityQuery.selectedFailures(selection, in: [failed, working, complete]), [failed.id])
    }

    func testLargeQueueQueryKeepsStableIdentitiesAndOrder() {
        let items = (0..<20_000).map { index in item(index.isMultiple(of: 3) ? .done : .queued, name: "Photo \(index)") }
        let matches = ActivityQuery.matching(items, filter: .completed, search: "Photo 1")
        XCTAssertEqual(matches.map(\.id), items.filter { $0.state == .done && $0.name.contains("Photo 1") }.map(\.id))
        XCTAssertEqual(Set(items.map(\.id)).count, 20_000)
    }

    func testDefaultWindowShowsActiveRowsUpcomingWorkAndRecentCompletions() {
        let completed = (0..<1000).map { _ in item(.done) }
        let active = [item(.uploading(fraction: 0.5)), item(.failed(reason: "Retry", retryable: true))]
        let waiting = (0..<5000).map { _ in item(.queued) }
        let all = completed + active + waiting
        let visible = ActivityQuery.visible(all, summarized: true, limit: ActivityQuery.pageSize)
        XCTAssertEqual(visible.map(\.id), (Array(completed.suffix(50)) + active + Array(waiting.prefix(20))).map(\.id))
        let expanded = ActivityQuery.visible(all, summarized: true, limit: ActivityQuery.pageSize * 2)
        XCTAssertTrue(Set(visible.map(\.id)).isSubset(of: Set(expanded.map(\.id))))
        XCTAssertLessThan(expanded.count, all.count)
        let manyFailures = (0..<1000).map { _ in item(.failed(reason: "Retry", retryable: true)) }
        let current = item(.uploading(fraction: 0.2))
        XCTAssertTrue(ActivityQuery.visible(manyFailures + [current], summarized: true, limit: 200).contains(current),
                      "old failures must not hide the upload currently running")
    }

    func testSearchAndFiltersCanRevealRowsOmittedByTheDefaultWindow() {
        let all = (0..<500).map { item(.done, name: "Photo \($0)") }
        let matches = ActivityQuery.matching(all, filter: .completed, search: "Photo 1")
        XCTAssertEqual(ActivityQuery.visible(matches, summarized: false, limit: 200), matches)
        let page = ActivityQuery.visible(all, summarized: false, limit: 200)
        let expanded = ActivityQuery.visible(all, summarized: false, limit: 400)
        XCTAssertEqual(page.count, 200)
        XCTAssertEqual(Array(expanded.prefix(200)), page)
    }
}
