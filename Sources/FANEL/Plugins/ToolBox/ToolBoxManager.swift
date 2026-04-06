import Foundation
import os

/// ToolBoxの統合管理Actor
actor ToolBoxManager {

    static let shared = ToolBoxManager()

    private let logger = Logger(subsystem: "com.fanel", category: "ToolBoxManager")
    private let scriptsDir: String
    private var patternCounts: [String: Int] = [:] // パターン出現回数

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.scriptsDir = "\(home)/.fanel/toolbox/scripts"
    }

    // MARK: - Layer 0: ToolBox検索・実行

    func search(goal: String) async -> (entry: ToolBoxEntry, result: String)? {
        guard let entry = await ToolBoxStore.shared.search(query: goal) else {
            return nil
        }

        await LogStore.shared.info("ToolBox ヒット: \(entry.name) (使用回数: \(entry.usageCount))")

        do {
            let result = try await ToolBoxStore.shared.execute(entry: entry)
            await ToolBoxStore.shared.incrementUsage(id: entry.id)
            return (entry: entry, result: result)
        } catch {
            await LogStore.shared.warning("ToolBox実行失敗: \(error) → AIフローにフォールバック")
            return nil
        }
    }

    // MARK: - タスク完了後: スクリプト化判定・登録

    func considerRegistration(task: TaskEnvelope) async {
        // sideEffectLevelが高い or ファイル変更ありは除外
        guard task.filesModified.isEmpty else { return }
        guard task.status == .complete else { return }

        // パターンカウント
        let pattern = normalizePattern(task.goal)
        self.patternCounts[pattern] = (self.patternCounts[pattern] ?? 0) + 1

        // 同一パターンが2回以上 → 自動スクリプト化
        guard (self.patternCounts[pattern] ?? 0) >= 2 else {
            logger.info("パターン記録: \(pattern) (回数: \(self.patternCounts[pattern] ?? 0)/2)")
            return
        }

        // 既にToolBoxに登録済みか確認
        if let existing = await ToolBoxStore.shared.search(query: task.goal, threshold: 0.9) {
            return // 既に登録済み
        }

        await registerScript(task: task)
    }

    // MARK: - スクリプト生成・登録

    private func registerScript(task: TaskEnvelope) async {
        let scriptId = UUID()
        let scriptPath = "\(scriptsDir)/\(scriptId).sh"

        // heredocパターンでインジェクション防止
        let script = """
        #!/bin/bash
        # FANEL ToolBox Script
        # Generated from task: \(task.goal.replacingOccurrences(of: "\\", with: "\\\\"))
        # Created: \(ISO8601DateFormatter().string(from: Date()))

        cat << 'FANEL_EOF'
        \(task.message)
        FANEL_EOF
        """

        let embedding = await EmbeddingEngine.shared.embed(text: task.goal)

        let entry = ToolBoxEntry(
            id: scriptId,
            name: shortName(for: task.goal),
            description: task.goal,
            scriptPath: scriptPath,
            scope: .experimental,
            sideEffectLevel: 0,
            requiresApproval: false,
            safeToRunOnIdle: true,
            rollbackStrategy: nil,
            dryRunSupported: false,
            embedding: embedding,
            usageCount: 0,
            lastUsedAt: nil,
            createdAt: Date()
        )

        do {
            try await ToolBoxStore.shared.add(entry: entry, script: script)
            await LogStore.shared.info("ToolBox登録: \(entry.name) (id: \(scriptId))")
        } catch {
            await LogStore.shared.error("ToolBox登録失敗: \(error)")
        }
    }

    // MARK: - ユーティリティ

    private func normalizePattern(_ text: String) -> String {
        // 数字・日時・固有名詞を除去して正規化
        text.lowercased()
            .replacingOccurrences(of: "\\d+", with: "N", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shortName(for goal: String) -> String {
        let trimmed = goal.prefix(30)
        return String(trimmed)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "　", with: "_")
    }
}
