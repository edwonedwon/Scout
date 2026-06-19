import Foundation

public struct DebugEntry: Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let level: Level
    public let tag: String
    public let message: String

    public enum Level: String {
        case info = "ℹ️"
        case success = "✅"
        case warning = "⚠️"
        case error = "❌"
        case network = "🌐"
    }

    public var formatted: String {
        let time = DateFormatter.debugTime.string(from: timestamp)
        return "[\(time)] \(level.rawValue) [\(tag)] \(message)"
    }
}

@MainActor
public final class DebugLogger: ObservableObject {
    public static let shared = DebugLogger()
    @Published public var entries: [DebugEntry] = []

    private init() {}

    public func log(_ message: String, level: DebugEntry.Level = .info, tag: String = "App") {
        let entry = DebugEntry(timestamp: Date(), level: level, tag: tag, message: message)
        entries.append(entry)
        print(entry.formatted)
    }

    public func clear() { entries = [] }
}

extension DateFormatter {
    static let debugTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// Convenience free functions
public func dlog(_ message: String, level: DebugEntry.Level = .info, tag: String = "App") {
    Task { @MainActor in
        DebugLogger.shared.log(message, level: level, tag: tag)
    }
}
