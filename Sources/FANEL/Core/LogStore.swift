import Foundation
import os

struct LogEntry: Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: String
    let message: String
}

/// アプリ内ログを保持するActor
actor LogStore {

    static let shared = LogStore()

    private let osLogger = Logger(subsystem: "com.fanel", category: "LogStore")
    private var entries: [LogEntry] = []
    private let maxEntries = 200

    private init() {}

    func append(level: String, message: String) {
        let entry = LogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            message: message
        )
        entries.append(entry)

        // 上限を超えたら古いものを削除
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        // OSLogにも出力
        switch level {
        case "error":
            osLogger.error("\(message)")
        case "warning":
            osLogger.warning("\(message)")
        default:
            osLogger.info("\(message)")
        }
    }

    func info(_ message: String) {
        append(level: "info", message: message)
    }

    func warning(_ message: String) {
        append(level: "warning", message: message)
    }

    func error(_ message: String) {
        append(level: "error", message: message)
    }

    /// 直近N件を返す
    func recent(_ count: Int = 50) -> [LogEntry] {
        Array(entries.suffix(count))
    }

    func all() -> [LogEntry] {
        entries
    }
}
