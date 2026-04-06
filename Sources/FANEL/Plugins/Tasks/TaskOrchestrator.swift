import Foundation
import os

/// チャットからの指示をToolBox→Council→WorkerPoolに渡して結果を返すActor
actor TaskOrchestrator {

    static let shared = TaskOrchestrator()

    private let logger = Logger(subsystem: "com.fanel", category: "TaskOrchestrator")
    private var isProcessing = false

    private init() {}

    // MARK: - タスク送信（Layer 0→Council→WorkerPool）

    func submit(goal: String) async -> TaskEnvelope {
        let taskId = UUID()

        let envelope = TaskEnvelope(
            id: taskId, goal: goal, status: .draft,
            message: "処理中..."
        )
        await TaskStore.shared.add(envelope)
        await LogStore.shared.info("タスク受付: \(goal) (id: \(taskId))")
        await IdleDetector.shared.recordActivity()

        // Layer 0: ToolBox検索（排他制御の外で実行 → 即応答）
        if let hit = await ToolBoxManager.shared.search(goal: goal) {
            await LogStore.shared.info("⚡ ToolBox実行（AI不使用）: \(hit.entry.name)")
            await TaskStore.shared.update(
                id: taskId, status: .complete,
                message: hit.result.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return await TaskStore.shared.get(id: taskId) ?? envelope
        }

        // Layer 0.5: 簡易タスクはCouncil省略
        if shouldSkipCouncil(goal: goal) {
            if isProcessing {
                let msg = "別のタスクが実行中です。完了までお待ちください。"
                await TaskStore.shared.update(id: taskId, status: .waiting, message: msg)
                await LogStore.shared.warning(msg)
                return await TaskStore.shared.get(id: taskId) ?? envelope
            }
            isProcessing = true
            await LogStore.shared.info("Council省略（簡易タスク判定）: \(goal)")
            let fastCouncil = CouncilResult(
                goal: goal, constraints: [], complexity: 0,
                executionPlan: ["直接実行"],
                reviewPolicy: ReviewPolicy(maxLayer: 2, requiresApproval: false),
                questionsForUser: [], risks: [],
                consensusReached: true,
                claudeAnalysis: "(Council省略)", codexAnalysis: "(未使用)"
            )
            let result = await executeViaWorkerPool(taskId: taskId, goal: goal, council: fastCouncil)
            if let completed = await TaskStore.shared.get(id: taskId) {
                Task { await ToolBoxManager.shared.considerRegistration(task: completed) }
            }
            isProcessing = false
            return result
        }

        // Council分析（ロック外で実行 → 並行タスクをブロックしない）
        await TaskStore.shared.update(id: taskId, status: .waitingForCouncil,
                                       message: "参謀会議中...")
        let council = await CouncilManager.shared.analyze(goal: goal)
        await TaskStore.shared.update(id: taskId, status: .waitingForCouncil,
                                       message: "参謀会議完了",
                                       councilResult: council)
        await LogStore.shared.info("参謀会議完了: consensus=\(council.consensusReached), complexity=\(council.complexity)")

        if !council.executionPlan.isEmpty {
            await LogStore.shared.info("実行計画: \(council.executionPlan.joined(separator: " → "))")
        }

        // questionsForUser → 逆質問
        if !council.questionsForUser.isEmpty {
            let questions = council.questionsForUser.joined(separator: "\n")
            await TaskStore.shared.update(
                id: taskId, status: .waitingForUser,
                message: questions,
                requiresApproval: true,
                councilResult: council
            )
            await LogStore.shared.warning("ユーザーへの質問: \(questions)")
            return await TaskStore.shared.get(id: taskId) ?? envelope
        }

        // 排他制御（実行直前にロック取得）
        if isProcessing {
            let msg = "別のタスクが実行中です。完了までお待ちください。"
            await TaskStore.shared.update(id: taskId, status: .waiting, message: msg)
            await LogStore.shared.warning(msg)
            return await TaskStore.shared.get(id: taskId) ?? envelope
        }

        isProcessing = true

        // WorkerPoolで実行
        let result = await executeViaWorkerPool(taskId: taskId, goal: goal, council: council)

        // タスク完了後: ToolBox登録候補を判定
        if let completed = await TaskStore.shared.get(id: taskId) {
            Task { await ToolBoxManager.shared.considerRegistration(task: completed) }
        }

        isProcessing = false
        return result
    }

    // MARK: - Council省略判定

    private func shouldSkipCouncil(goal: String) -> Bool {
        let length = goal.count
        let dangerKeywords = ["削除", "delete", "drop", "rm ", "全て", "移行", "migration", "refactor", "全部", "一括"]
        let hasDanger = dangerKeywords.contains { goal.lowercased().contains($0) }
        return length <= 150 && !hasDanger
    }

    // MARK: - ユーザー回答を受けてタスク再開

    func answerAndResume(taskId: UUID, answer: String) async -> TaskEnvelope? {
        guard let task = await TaskStore.shared.get(id: taskId) else { return nil }
        guard task.status == .waitingForUser else { return task }

        await LogStore.shared.info("ユーザー回答: \(answer) (task: \(taskId))")
        await IdleDetector.shared.recordActivity()

        let extendedGoal = "\(task.goal)\n\nユーザーからの追加情報: \(answer)"

        let council = task.councilResult ?? CouncilResult(
            goal: extendedGoal, constraints: [], complexity: 0,
            executionPlan: ["直接実行"],
            reviewPolicy: ReviewPolicy(maxLayer: 1, requiresApproval: false),
            questionsForUser: [], risks: [], consensusReached: true,
            claudeAnalysis: "", codexAnalysis: ""
        )

        // 排他制御（実行直前にロック取得）
        if isProcessing {
            await TaskStore.shared.update(id: taskId, status: .waiting,
                                           message: "別のタスクが実行中です。")
            return await TaskStore.shared.get(id: taskId)
        }

        isProcessing = true

        await TaskStore.shared.update(id: taskId, status: .running,
                                       message: "Worker選択中...",
                                       councilResult: council)
        let currentTask = await TaskStore.shared.get(id: taskId)!
        let updatedTask = TaskEnvelope(
            id: currentTask.id, goal: extendedGoal, status: .running,
            message: currentTask.message, createdAt: currentTask.createdAt,
            councilResult: council
        )

        do {
            let result = try await WorkerPool.shared.execute(task: updatedTask, councilResult: council)
            if let completed = await TaskStore.shared.get(id: taskId) {
                Task { await ToolBoxManager.shared.considerRegistration(task: completed) }
            }
            isProcessing = false
            return result
        } catch {
            let msg = "Worker実行エラー: \(error)"
            await TaskStore.shared.update(id: taskId, status: .error, message: msg,
                                           councilResult: council)
            await LogStore.shared.error(msg)
            isProcessing = false
            return await TaskStore.shared.get(id: taskId)
        }
    }

    // MARK: - WorkerPool経由実行

    private func executeViaWorkerPool(taskId: UUID, goal: String,
                                       council: CouncilResult) async -> TaskEnvelope {
        let worker = await WorkerPool.shared.selectWorker(for: council.complexity)
        await LogStore.shared.info("Worker選択: Layer \(worker.layer) (\(worker.modelName))")

        let task = await TaskStore.shared.get(id: taskId)!

        do {
            return try await WorkerPool.shared.execute(task: task, councilResult: council)
        } catch {
            let msg = "Worker実行エラー: \(error)"
            await TaskStore.shared.update(id: taskId, status: .error, message: msg,
                                           councilResult: council)
            await LogStore.shared.error(msg)
            return await TaskStore.shared.get(id: taskId)!
        }
    }
}
