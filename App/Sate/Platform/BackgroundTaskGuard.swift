import Foundation
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

    var isActive: Bool { timeout != nil }

    func begin(name: String = "sate.generation", onExpire: @escaping @MainActor () -> Void) {
        guard timeout == nil else { return }
        expirationHandler = onExpire

        #if canImport(UIKit)
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Documented to run on the main thread, and it must act immediately:
            // hopping through a Task risks suspension before it ever runs.
            MainActor.assumeIsolated { self?.expire() }
        }
        guard identifier != .invalid else {
            // Background execution was refused outright; do not pretend to have time.
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
        UIApplication.shared.endBackgroundTask(identifier)
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
