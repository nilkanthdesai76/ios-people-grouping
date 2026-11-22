import Foundation
import os

/// os.Logger plus an in-memory ring buffer of the last 20 lines for diagnostics.
nonisolated final class AppLog: Sendable {
    static let shared = AppLog()

    private let logger: Logger
    private let lock = OSAllocatedUnfairLock(initialState: [String]())

    private init() {
        logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "PeopleGrouping",
            category: "app"
        )
    }

    func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
        lock.withLock { lines in
            lines.append(message)
            if lines.count > 20 {
                lines.removeFirst(lines.count - 20)
            }
        }
    }

    func recent() -> [String] {
        lock.withLock { $0 }
    }
}
