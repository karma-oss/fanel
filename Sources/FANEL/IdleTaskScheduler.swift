import Foundation
import os

struct IdleHistoryEntry: Codable, Sendable {
    let id: UUID
    let taskName: String
    let result: String
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case id, result, timestamp
        case taskName = "task_name"
    }
}

/// アイドル時のタスクを順番に実行するActor
actor IdleTaskScheduler {

    static let shared = IdleTaskScheduler()

    private let logger = Logger(subsystem: "com.fanel", category: "IdleTaskScheduler")
    private var cycleTask: Task<Void, Never>?
    private var _currentTask: String?
    private var _isRunning = false
    private var history: [IdleHistoryEntry] = []
    private let maxHistory = 50

    private init() {}

    // MARK: - アイドルサイクル開始

    func startIdleCycle() async {
        guard !_isRunning else { return }
        _isRunning = true
        await LogStore.shared.info("[Idle] アイドルサイクル開始")

        cycleTask = Task {
            await runCycle()
        }
    }

    // MARK: - アイドルサイクル中断

    func suspendIdleCycle() {
        guard _isRunning else { return }
        _isRunning = false
        _currentTask = nil
        cycleTask?.cancel()
        cycleTask = nil
        logger.info("[Idle] アイドルサイクル中断")
    }

    // MARK: - メインサイクル

    private func runCycle() async {
        let tasks: [(name: String, run: () async -> String)] = [
            ("ソースインデックス", { await IdleTaskRunner.shared.runSelfIndex() }),
            ("セルフレビュー", { await IdleTaskRunner.shared.runSelfReview() }),
            ("自己進化サイクル", { await IdleTaskRunner.shared.runSelfEvolution() }),
            ("新モデルベンチマーク", { await IdleTaskRunner.shared.runPendingBenchmarks() }),
            ("ToolBoxスクリプト生成", { await IdleTaskRunner.shared.generateMissingScripts() }),
            ("コード改善提案", { await IdleTaskRunner.shared.generateImprovementSuggestions() }),
            ("Git自動push", { await IdleTaskRunner.shared.autoGitPush() }),
        ]

        for (name, run) in tasks {
            if Task.isCancelled || !_isRunning { break }

            _currentTask = name
            await LogStore.shared.info("[Idle] 実行中: \(name)")

            let result = await run()

            if Task.isCancelled || !_isRunning { break }

            let entry = IdleHistoryEntry(
                id: UUID(),
                taskName: name,
                result: result,
                timestamp: Date()
            )
            history.append(entry)
            if history.count > maxHistory {
                history.removeFirst(history.count - maxHistory)
            }

            await LogStore.shared.info("[Idle] 完了: \(name) — \(result)")

            // 次のタスクまで30秒待機（即停止可能）
            if Task.isCancelled || !_isRunning { break }
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
        }

        _currentTask = nil
        _isRunning = false
        await LogStore.shared.info("[Idle] アイドルサイクル完了")
    }

    // MARK: - 状態取得

    func currentIdleTask() -> String? { _currentTask }
    func isRunning() -> Bool { _isRunning }

    func recentHistory(_ count: Int = 10) -> [IdleHistoryEntry] {
        Array(history.suffix(count).reversed())
    }
}
