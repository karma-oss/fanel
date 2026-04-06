import Foundation
import os

struct WorkerConfig: Sendable {
    let layer: Int
    let modelName: String
    let useHayabusa: Bool   // false = Claude Code
}

/// complexityに応じてWorkerを選択・実行するActor
actor WorkerPool {

    static let shared = WorkerPool()

    private let logger = Logger(subsystem: "com.fanel", category: "WorkerPool")
    private var claudeManager: ClaudeProcessManager?

    private init() {}

    // MARK: - タスク実行

    func execute(task: TaskEnvelope, councilResult: CouncilResult) async throws -> TaskEnvelope {
        let complexity = councilResult.complexity
        let worker = await selectWorker(for: complexity)

        await LogStore.shared.info("Worker選択: Layer \(worker.layer) (\(worker.modelName)) — complexity=\(complexity)")
        await TaskStore.shared.update(
            id: task.id, status: .running,
            message: "Layer \(worker.layer) で実行中 (\(worker.modelName))...",
            councilResult: councilResult
        )

        if worker.useHayabusa {
            return await executeWithHayabusa(task: task, worker: worker, council: councilResult)
        } else {
            return await executeWithClaude(task: task, council: councilResult)
        }
    }

    // MARK: - Worker選択

    func selectWorker(for complexity: Int) async -> WorkerConfig {
        let targetLayer = min(4, max(1, complexity + 1))

        // 対象Layerから上位に向けてモデルを探す
        for layer in targetLayer...4 {
            if layer == 4 {
                return WorkerConfig(layer: 4, modelName: "claude-code", useHayabusa: false)
            }

            // Hayabusaが利用可能か確認
            let hayabusaUp = await HayabusaClient.shared.isAvailable()
            if !hayabusaUp {
                logger.info("Hayabusa unavailable, escalating to Layer 4")
                continue
            }

            if let model = await ModelRegistry.shared.bestModelForLayer(layer) {
                return WorkerConfig(layer: layer, modelName: model.name, useHayabusa: true)
            }
        }

        // フォールバック: Claude Code
        return WorkerConfig(layer: 4, modelName: "claude-code", useHayabusa: false)
    }

    // MARK: - Hayabusa実行

    private func executeWithHayabusa(task: TaskEnvelope, worker: WorkerConfig,
                                      council: CouncilResult) async -> TaskEnvelope {
        let prompt = buildPrompt(goal: task.goal, council: council)

        do {
            let rawOutput = try await HayabusaClient.shared.complete(
                model: worker.modelName, prompt: prompt
            )
            await LogStore.shared.info("Hayabusa応答受信 (Layer \(worker.layer), \(rawOutput.count)文字)")

            if let response = LooseJSONParser.parse(rawOutput) {
                await TaskStore.shared.update(
                    id: task.id, status: response.status,
                    message: response.message,
                    filesModified: response.filesModified,
                    nextAction: response.nextAction,
                    requiresApproval: response.requiresApproval,
                    councilResult: council
                )
                return await TaskStore.shared.get(id: task.id)!
            } else {
                let trimmed = String(rawOutput.prefix(500))
                await TaskStore.shared.update(
                    id: task.id, status: .complete, message: trimmed,
                    councilResult: council
                )
                return await TaskStore.shared.get(id: task.id)!
            }
        } catch {
            await LogStore.shared.warning("Hayabusa Layer \(worker.layer) 失敗: \(error) → Claude Codeにフォールバック")
            // フォールバック: Claude Code
            return await executeWithClaude(task: task, council: council)
        }
    }

    // MARK: - Claude Code実行

    private func executeWithClaude(task: TaskEnvelope, council: CouncilResult) async -> TaskEnvelope {
        await TaskStore.shared.update(
            id: task.id, status: .running,
            message: "Layer 4 で実行中 (claude-code)...",
            councilResult: council
        )

        // ClaudeProcessManager初期化
        if claudeManager == nil {
            do {
                claudeManager = try await ClaudeProcessManager(timeoutSeconds: 60, maxRetries: 1)
            } catch {
                let msg = "Claude Code初期化失敗: \(error)"
                await TaskStore.shared.update(id: task.id, status: .error, message: msg,
                                               councilResult: council)
                await LogStore.shared.error(msg)
                return await TaskStore.shared.get(id: task.id)!
            }
        }

        let prompt = buildPrompt(goal: task.goal, council: council)

        do {
            let rawOutput = try await claudeManager!.send(prompt: prompt)
            await LogStore.shared.info("Claude Code応答受信 (\(rawOutput.count)文字)")

            if let response = LooseJSONParser.parse(rawOutput) {
                await TaskStore.shared.update(
                    id: task.id, status: response.status,
                    message: response.message,
                    filesModified: response.filesModified,
                    nextAction: response.nextAction,
                    requiresApproval: response.requiresApproval,
                    councilResult: council
                )
            } else {
                let trimmed = String(rawOutput.prefix(500))
                await TaskStore.shared.update(
                    id: task.id, status: .complete, message: trimmed,
                    councilResult: council
                )
            }
        } catch {
            let msg = "Claude Code実行エラー: \(error)"
            await TaskStore.shared.update(id: task.id, status: .error, message: msg,
                                           councilResult: council)
            await LogStore.shared.error(msg)
        }

        return await TaskStore.shared.get(id: task.id)!
    }

    // MARK: - プロンプト組み立て

    private func buildPrompt(goal: String, council: CouncilResult) -> String {
        var prompt = """
        あなたはFANELというシステムの配下で動作しています。
        必ずマーカー形式でレスポンスして���ださい。

        [FANEL_RESPONSE_BEGIN]
        {
          "status": "complete",
          "message": "実行結果の説明",
          "files_modified": [],
          "next_action": null,
          "requires_approval": false
        }
        [FANEL_RESPONSE_END]

        """

        if !council.executionPlan.isEmpty || council.progressScore >= 0 {
            prompt += "\n参謀会議の結果:\n"
            prompt += "- 複雑度: \(council.complexity)/3\n"
            if !council.currentMilestone.isEmpty {
                prompt += "- 現在地: \(council.currentMilestone)\n"
            }
            if council.progressScore >= 0 {
                prompt += "- 達成度: \(council.progressScore)%\n"
            }
            if council.estimatedSlices > 0 {
                prompt += "- 残りスライス: \(council.estimatedSlices)個\n"
            }
            if !council.remainingSlices.isEmpty {
                prompt += "- 未完了タスク: \(council.remainingSlices.joined(separator: ", "))\n"
            }
            if !council.blockers.isEmpty {
                prompt += "- ブロッカー: \(council.blockers.joined(separator: ", "))\n"
            }
            if !council.executionPlan.isEmpty {
                prompt += "- 実行計画: \(council.executionPlan.joined(separator: " → "))\n"
            }
            if !council.constraints.isEmpty {
                prompt += "- 制約: \(council.constraints.joined(separator: ", "))\n"
            }
            if !council.risks.isEmpty {
                prompt += "- リスク: \(council.risks.joined(separator: ", "))\n"
            }
            prompt += "\n"
        }

        prompt += "\nユーザーの指示: \(goal)"
        return prompt
    }
}
