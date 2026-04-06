import Foundation
import os

/// 各アイドルタスクを実際に実行するActor
actor IdleTaskRunner {

    static let shared = IdleTaskRunner()

    private let logger = Logger(subsystem: "com.fanel", category: "IdleTaskRunner")

    private init() {}

    // MARK: - Priority 0: ソースインデックス更新

    func runSelfIndex() async -> String {
        return await SelfIndexer.shared.indexSources()
    }

    // MARK: - Priority 0.5: セルフレビュー

    func runSelfReview() async -> String {
        return await SelfReviewer.shared.reviewAll()
    }

    // MARK: - Priority 1: 自己進化サイクル

    func runSelfEvolution() async -> String {
        return await SelfEvolutionOrchestrator.shared.runEvolutionCycle()
    }

    // MARK: - Priority 2: 新モデルの自動ベンチマーク

    func runPendingBenchmarks() async -> String {
        let models = await ModelRegistry.shared.allModels()
        let pending = models.filter { $0.status == .experimental && $0.layer <= 3 }

        if pending.isEmpty { return "ベンチマーク対象なし" }

        for model in pending {
            if Task.isCancelled { return "中断" }
            await LogStore.shared.info("[Idle] ベンチマーク実行: \(model.name)")
            await ModelRegistry.shared.runBenchmark(modelId: model.id)
        }

        return "ベンチマーク完了: \(pending.count)モデル"
    }

    // MARK: - Priority 2: ToolBox未カバー領域スクリプト自動生成

    func generateMissingScripts() async -> String {
        // 直近のタスクからToolBox未登録パターンを探す
        let tasks = await TaskStore.shared.recent(20)
        let completedTasks = tasks.filter { $0.status == .complete && $0.filesModified.isEmpty }

        var generated = 0
        for task in completedTasks {
            if Task.isCancelled { return "中断 (生成: \(generated)件)" }

            // 既にToolBoxにあるか確認
            let existing = await ToolBoxStore.shared.search(query: task.goal, threshold: 0.8)
            if existing != nil { continue }

            // スクリプト化候補
            await ToolBoxManager.shared.considerRegistration(task: task)
            generated += 1
        }

        return generated > 0 ? "スクリプト候補: \(generated)件処理" : "新規候補なし"
    }

    // MARK: - Priority 3: コード改善提案

    func generateImprovementSuggestions() async -> String {
        // Hayabusaが利用可能な場合のみ
        guard await HayabusaClient.shared.isAvailable() else {
            return "Hayabusa未起動 — スキップ"
        }

        if Task.isCancelled { return "中断" }

        let prompt = "FANELプロジェクトの改善提案を3つ、JSON配列で簡潔に回答してください。例: [\"提案1\", \"提案2\", \"��案3\"]"

        do {
            let models = await ModelRegistry.shared.allModels()
            let model = models.first(where: { $0.layer <= 3 && $0.status == .active })
            guard let m = model else { return "利用可能なローカルモデルなし" }

            let result = try await HayabusaClient.shared.complete(model: m.name, prompt: prompt)
            await LogStore.shared.info("[Idle] 改善提案: \(String(result.prefix(200)))")
            return "改善提案生成完了"
        } catch {
            return "改善提案失敗: \(error)"
        }
    }

    // MARK: - Priority 4: Git自動push

    func autoGitPush() async -> String {
        guard await OwnershipManager.shared.isOwner() else {
            return "非オーナー — Git pushスキップ"
        }

        if Task.isCancelled { return "中断" }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let branch = "fanel/idle-\(formatter.string(from: Date()))"

        do {
            try await PeerSyncManager.shared.pushToGit(branch: branch)
            return "Git push完了: \(branch)"
        } catch {
            return "Git push失敗: \(error)"
        }
    }
}
