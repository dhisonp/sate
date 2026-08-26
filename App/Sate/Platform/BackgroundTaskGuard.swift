import Foundation
import OSLog
#if canImport(UIKit)
    import UIKit
#endif

/// Keeps a generation alive for a bounded window after the app is backgrounded,
/// then hands control back so the caller can shut the stream down on its own
/// terms (R4).
///
/// The self-imposed budget matters as much as the system expiration handler: if
/// the OS suspends the process while an SSE parser is still live, `URLSession`
/// can deliver a burst of buffered bytes — or a late error — on the next
/// foreground, into state that has already been committed.
@MainActor
final class BackgroundTaskGuard {
    /// iOS grants roughly 30 s. Expiring at 25 leaves room to flush the tail and
    /// write the transcript before the system stops being polite about it.
    static let budget: TimeInterval = 25

    private var expirationHandler: (@MainActor () -> Void)?
    private var timeout: Task<Void, Never>?
    #if canImport(UIKit)
        private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    init() {}

    deinit {
        timeout?.cancel()
        #if canImport(UIKit)
            let taskID = identifier
            if taskID != .invalid {
                Log.lifecycle.warning("BackgroundTaskGuard deallocated while background task assertion was still active")
                Task { @MainActor in
                    UIApplication.shared.endBackgroundTask(taskID)
                }
            }
        #endif
    }

    var isActive: Bool {
        timeout != nil
    }

    func begin(name: String = "sate.generation", onExpire: @escaping @MainActor () -> Void) {
        guard timeout == nil else { return }
        expirationHandler = onExpire
        Log.lifecycle.info("BackgroundTaskGuard beginning background task assertion: \(name, privacy: .public)")

        #if canImport(UIKit)
            identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                // Documented to run on the main thread, and it must act immediately:
                // hopping through a Task risks suspension before it ever runs.
                Log.lifecycle.notice("System expired background task assertion \(name, privacy: .public)")
                MainActor.assumeIsolated { self?.expire() }
            }
            guard identifier != .invalid else {
                // Background execution was refused outright; do not pretend to have time.
                Log.lifecycle.error("System refused background task assertion for \(name, privacy: .public)")
                expire()
                return
            }
        #endif

        timeout = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.budget * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            Log.lifecycle.notice("Self-imposed background budget (\(Self.budget, format: .fixed(precision: 0))s) expired for \(name, privacy: .public)")
            self?.expire()
        }
    }

    /// Ends the assertion without firing `onExpire` — the normal path when the
    /// app returns to the foreground or the generation finishes.
    func end() {
        timeout?.cancel()
        timeout = nil
        expirationHandler = nil
        #if canImport(UIKit)
            guard identifier != .invalid else { return }
            let taskID = identifier
            Log.lifecycle.info("Ending background task assertion \(taskID.rawValue)")
            UIApplication.shared.endBackgroundTask(taskID)
            identifier = .invalid
        #endif
    }

    private func expire() {
        let handler = expirationHandler
        // Release the assertion before the callback: whatever it does (cancel a
        // stream, write a file) must not be racing our own expiry.
        end()
        handler?()
    }
}
