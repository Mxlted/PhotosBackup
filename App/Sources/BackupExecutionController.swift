import Foundation

/// Tracks the execution time shared by the queue's independent entry points.
/// Ending one window must not pause work owned by another window or the open
/// app. A URL-session delivery permits only prepared work unless another owner
/// also permits preparation.
@MainActor
final class BackupExecutionController {
    enum Window: Equatable {
        case processing
        case transferDelivery
    }

    private enum Mode: Equatable {
        case foreground, continuedProcessing, processing, transferDelivery, suspended
    }

    private let queue: UploadQueue
    private var windows: [UUID: Window] = [:]
    private var appliedMode: Mode?
    private(set) var isForeground = true
    private var continuedProcessing = false

    init(queue: UploadQueue) { self.queue = queue }

    var hasPreparationWindow: Bool { windows.values.contains { $0 == .processing } }
    var canPrepareWork: Bool { isForeground || continuedProcessing || hasPreparationWindow }
    var hasExecutionTime: Bool { canPrepareWork || !windows.isEmpty }

    func setForeground(_ active: Bool) {
        isForeground = active
        apply()
    }

    func setContinuedProcessing(_ active: Bool) {
        continuedProcessing = active
        apply()
    }

    @discardableResult
    func begin(_ window: Window, foreground: Bool? = nil) -> UUID {
        let id = UUID()
        windows[id] = window
        if let foreground { isForeground = foreground }
        apply()
        return id
    }

    func end(_ id: UUID) {
        guard windows.removeValue(forKey: id) != nil else { return }
        apply()
    }

    private func apply() {
        let mode: Mode
        if isForeground { mode = .foreground }
        else if continuedProcessing { mode = .continuedProcessing }
        else if hasPreparationWindow { mode = .processing }
        else if !windows.isEmpty { mode = .transferDelivery }
        else { mode = .suspended }
        guard mode != appliedMode else { return }
        appliedMode = mode

        switch mode {
        case .foreground, .continuedProcessing:
            queue.setPreparationGuardArmed(true)
            queue.setICloudDownloadsAllowed(true)
            queue.resumeSystemWork()
        case .processing:
            queue.setPreparationGuardArmed(true)
            queue.setICloudDownloadsAllowed(false)
            queue.resumeSystemWork()
        case .transferDelivery:
            // A processing window may have just ended while a delivery is
            // still open. Cancel its unprepared workers even when iCloud was
            // already disabled; only iOS-owned transfers retain execution.
            queue.suspendForBackgroundExpiration()
            // Set the filter before any operation below can pump the queue.
            queue.noteBackgroundTransferCompletionsPending()
            queue.setPreparationGuardArmed(false)
            queue.setICloudDownloadsAllowed(false)
            queue.resumeBackgroundTransferCompletions()
        case .suspended:
            queue.suspendForBackgroundExpiration()
            queue.setICloudDownloadsAllowed(false)
            queue.flushPendingWrites()
        }
    }
}
