import Foundation
import os

/// Thread-safe logging settings shared by `YapsSupport.logLevel` and `YapsSupport.logHandler`.
/// Log lines never contain message text, identity values, metadata values or tokens.
enum Log {
    typealias Handler = @Sendable (SupportLogLevel, String) -> Void

    private struct Settings {
        var level: SupportLogLevel = .info
        var handler: Handler?
    }

    private static let settings = OSAllocatedUnfairLock(initialState: Settings())
    private static let logger = Logger(subsystem: "ai.yaps.support", category: "YapsSupport")

    static var level: SupportLogLevel {
        get { settings.withLock { $0.level } }
        set { settings.withLock { $0.level = newValue } }
    }

    static var handler: Handler? {
        get { settings.withLock { $0.handler } }
        set { settings.withLock { $0.handler = newValue } }
    }

    static func error(_ message: @autoclosure () -> String) { emit(.error, message) }
    static func info(_ message: @autoclosure () -> String) { emit(.info, message) }
    static func debug(_ message: @autoclosure () -> String) { emit(.debug, message) }

    private static func emit(_ level: SupportLogLevel, _ message: () -> String) {
        let (current, handler) = settings.withLock { ($0.level, $0.handler) }
        guard level != .off, level <= current else { return }
        let text = message()
        if let handler {
            handler(level, text)
            return
        }
        switch level {
        case .error: logger.error("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        default: logger.debug("\(text, privacy: .public)")
        }
    }

    /// Setup-check output is always printed to the console, regardless of level or handler.
    static func setupCheck(_ message: String) {
        print("[YapsSupport] \(message)")
        logger.notice("[YapsSupport] \(message, privacy: .public)")
    }
}
