import Foundation
import os

/// 2者合意ロジックを管理するActor
actor CouncilManager {

    static let shared = CouncilManager()

    private let logger = Logger(subsystem: "com.fanel", category: "CouncilManager")
    private var claudeManager: ClaudeProcessManager?
    private let codexAvailable: Bool

    private init() {
        // codexのインストール確認
        self.codexAvailable = CouncilManager.checkCodexInstalled()
    }

    private static func checkCodexInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - 分析実行

    func analyze(goal: String) async -> CouncilResult {
        await LogStore.shared.info("参謀会議開始: \(goal)")

        // ClaudeProcessManager初期化
        if claudeManager == nil {
            do {
                claudeManager = try await ClaudeProcessManager(timeoutSeconds: 60, maxRetries: 1)
            } catch {
                await LogStore.shared.error("Claude初期化失敗: \(error)")
                return makeFallbackResult(goal: goal, error: "Claude初期化失敗")
            }
        }

        // 並列分析
        if codexAvailable {
            await LogStore.shared.info("Claude + Codex 並列分析を開始")
            return await analyzeWithBoth(goal: goal)
        } else {
            await LogStore.shared.info("Codex未検出 — Claude単独分析モード")
            return await analyzeWithClaudeOnly(goal: goal)
        }
    }

    // MARK: - 2者並列分析

    private func analyzeWithBoth(goal: String) async -> CouncilResult {
        async let claudeResult = analyzeWithClaude(goal: goal)
        async let codexResult = analyzeWithCodex(goal: goal)

        let claude = await claudeResult
        let codex = await codexResult

        await LogStore.shared.info("Claude分析: complexity=\(claude?.complexity ?? -1)")
        await LogStore.shared.info("Codex分析: complexity=\(codex?.complexity ?? -1)")

        guard let c = claude else {
            // Claude失敗 → Codexのみ
            if let x = codex {
                return buildResult(goal: goal, claude: x, codex: x,
                                   claudeRaw: "(Claude分析失敗)", codexRaw: "Codex分析完了",
                                   consensus: true)
            }
            return makeFallbackResult(goal: goal, error: "両方の分析に失敗")
        }

        guard let x = codex else {
            // Codex失敗 → Claudeのみ
            return buildResult(goal: goal, claude: c, codex: c,
                               claudeRaw: "Claude分析完了", codexRaw: "(Codex分析失敗)",
                               consensus: true)
        }

        // 合意判定
        let consensus = judgeConsensus(claude: c, codex: x)
        return buildResult(goal: goal, claude: c, codex: x,
                           claudeRaw: "Claude分析完了", codexRaw: "Codex分析完了",
                           consensus: consensus)
    }

    // MARK: - Claude単独分析

    private func analyzeWithClaudeOnly(goal: String) async -> CouncilResult {
        let analysis = await analyzeWithClaude(goal: goal)

        guard let a = analysis else {
            return makeFallbackResult(goal: goal, error: "Claude分析失敗")
        }

        await LogStore.shared.info("Claude分析完了: complexity=\(a.complexity)")

        return buildResult(goal: goal, claude: a, codex: a,
                           claudeRaw: "Claude分析完了", codexRaw: "(Codex未使用・Claude単独)",
                           consensus: true)
    }

    // MARK: - Claude分析

    private func analyzeWithClaude(goal: String) async -> CouncilAnalysis? {
        let prompt = """
        あなたはFANELのCouncilメンバーとして要件を分析します。
        現在の目標への達成度と残り作業も必ず分析してください。

        [COUNCIL_RESPONSE_BEGIN]
        {
          "complexity": 0,
          "constraints": ["制約1"],
          "execution_plan": ["手順1"],
          "risks": [],
          "questions_for_user": [],
          "progress_score": 0,
          "remaining_slices": ["未完了タスク1"],
          "blockers": [],
          "current_milestone": "Step 1/1: 実行",
          "estimated_slices": 1
        }
        [COUNCIL_RESPONSE_END]

        complexityのスコアリング:
        - 影響ファイル数が複数 → +1
        - モジュール跨ぎあり → +1
        - 破壊的変更あり → +1
        - 合計を0〜3の範囲で回答

        進捗評価の指針:
        - progress_score: このタスクが完了したとき、全体目標の何%が達成されるか (0〜100)
        - remaining_slices: このタスク完了後に残るサブタスクを具体的に列挙
        - blockers: 人間の判断や確認が必要なもの
        - current_milestone: 「Step X/Y: 内容」形式で現在地を示す
        - estimated_slices: 残りの作業を何スライスで完了できるか (1〜20)

        タスク: \(goal)
        """

        do {
            let raw = try await claudeManager!.send(prompt: prompt)
            return parseCouncilResponse(raw, beginMarker: "[COUNCIL_RESPONSE_BEGIN]", endMarker: "[COUNCIL_RESPONSE_END]")
        } catch {
            logger.error("Claude analysis failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Codex分析

    private func analyzeWithCodex(goal: String) async -> CouncilAnalysis? {
        let prompt = """
        以下のタスクを分析してJSON形式で回答してください。

        タスク: \(goal)

        回答形式:
        {"complexity": 0〜3, "constraints": [], "execution_plan": [], "risks": [], "questions_for_user": []}
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "--model", "gpt-4.1", "--approval-policy", "auto-edit", "-q", prompt]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            logger.error("Codex process start failed: \(error.localizedDescription)")
            return nil
        }

        // タイムアウト付き読み取り
        let readTask = Task.detached { () -> String in
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            process.terminate()
        }

        let processWait = Task.detached {
            process.waitUntilExit()
        }

        await processWait.value
        timeoutTask.cancel()

        let raw = await readTask.value

        if raw.isEmpty {
            logger.warning("Codex returned empty output")
            return nil
        }

        // ブレーススキャンでJSONを探す
        return parseCouncilJSON(raw)
    }

    // MARK: - Council応答パース

    private func parseCouncilResponse(_ raw: String, beginMarker: String, endMarker: String) -> CouncilAnalysis? {
        // マーカー抽出
        if let beginRange = raw.range(of: beginMarker),
           let endRange = raw.range(of: endMarker, range: beginRange.upperBound..<raw.endIndex) {
            let json = String(raw[beginRange.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = json.data(using: .utf8),
               let analysis = try? JSONDecoder().decode(CouncilAnalysis.self, from: data) {
                return analysis
            }
            // フォールバック: ゆるいパース
            if let a = parseCouncilJSON(json) { return a }
        }

        // マーカーなし → ブレーススキャン
        return parseCouncilJSON(raw)
    }

    private func parseCouncilJSON(_ raw: String) -> CouncilAnalysis? {
        // LooseJSONParserのブレーススキャンと同様にJSONを探す
        guard let data = extractFirstJSON(raw)?.data(using: .utf8) else { return nil }

        if let analysis = try? JSONDecoder().decode(CouncilAnalysis.self, from: data) {
            return analysis
        }

        // ゆるいパース
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        return CouncilAnalysis(
            complexity: min(3, max(0, dict["complexity"] as? Int ?? 0)),
            constraints: dict["constraints"] as? [String] ?? [],
            executionPlan: dict["execution_plan"] as? [String] ?? [],
            risks: dict["risks"] as? [String] ?? [],
            questionsForUser: dict["questions_for_user"] as? [String] ?? [],
            progressScore: dict["progress_score"] as? Int ?? -1,
            remainingSlices: dict["remaining_slices"] as? [String] ?? [],
            blockers: dict["blockers"] as? [String] ?? [],
            currentMilestone: dict["current_milestone"] as? String ?? "",
            estimatedSlices: dict["estimated_slices"] as? Int ?? 0
        )
    }

    private func extractFirstJSON(_ text: String) -> String? {
        var depth = 0
        var start: String.Index?
        var inStr = false
        var esc = false

        for (offset, ch) in text.enumerated() {
            let idx = text.index(text.startIndex, offsetBy: offset)
            if esc { esc = false; continue }
            if ch == "\\" && inStr { esc = true; continue }
            if ch == "\"" { inStr.toggle(); continue }
            if inStr { continue }
            if ch == "{" { if depth == 0 { start = idx }; depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0, let s = start {
                    return String(text[s...idx])
                }
            }
        }
        return nil
    }

    // MARK: - 合意判定

    private func judgeConsensus(claude: CouncilAnalysis, codex: CouncilAnalysis) -> Bool {
        // complexityの差が1以内
        let complexityOk = abs(claude.complexity - codex.complexity) <= 1

        // executionPlanのステップ数の差が2以内
        let planOk = abs(claude.executionPlan.count - codex.executionPlan.count) <= 2

        // どちらかがrisksを出した → 質問に積む（buildResultで処理）
        // 上記をすべて満たせば合意
        return complexityOk && planOk
    }

    // MARK: - 結果組み立て

    private func buildResult(goal: String, claude: CouncilAnalysis, codex: CouncilAnalysis,
                             claudeRaw: String, codexRaw: String, consensus: Bool) -> CouncilResult {
        let complexity = min(3, max(claude.complexity, codex.complexity))
        let constraints = Array(Set(claude.constraints + codex.constraints))
        let plan = claude.executionPlan.count >= codex.executionPlan.count
            ? claude.executionPlan : codex.executionPlan

        var questions = Array(Set(claude.questionsForUser + codex.questionsForUser))
        let risks = Array(Set(claude.risks + codex.risks))
        if !risks.isEmpty && questions.isEmpty {
            questions.append("以下のリスクが検出されました。続行しますか？\n" + risks.joined(separator: "\n"))
        }

        let maxLayer: Int
        switch complexity {
        case 0: maxLayer = 1
        case 1, 2: maxLayer = 2
        case 3: maxLayer = 3
        default: maxLayer = 4
        }

        let reviewPolicy = ReviewPolicy(
            maxLayer: maxLayer,
            requiresApproval: !questions.isEmpty || complexity >= 3
        )

        // 進捗: Claudeの値を優先、なければCodex
        let progress = claude.progressScore >= 0 ? claude.progressScore : codex.progressScore
        let remaining = !claude.remainingSlices.isEmpty ? claude.remainingSlices : codex.remainingSlices
        let blk = Array(Set(claude.blockers + codex.blockers))
        let milestone = !claude.currentMilestone.isEmpty ? claude.currentMilestone : codex.currentMilestone
        let slices = claude.estimatedSlices > 0 ? claude.estimatedSlices : codex.estimatedSlices

        return CouncilResult(
            goal: goal,
            constraints: constraints,
            complexity: complexity,
            executionPlan: plan,
            reviewPolicy: reviewPolicy,
            questionsForUser: questions,
            risks: risks,
            consensusReached: consensus,
            claudeAnalysis: claudeRaw,
            codexAnalysis: codexRaw,
            progressScore: progress,
            remainingSlices: remaining,
            blockers: blk,
            currentMilestone: milestone,
            estimatedSlices: slices
        )
    }

    private func makeFallbackResult(goal: String, error: String) -> CouncilResult {
        CouncilResult(
            goal: goal,
            constraints: [],
            complexity: 0,
            executionPlan: ["直接実行"],
            reviewPolicy: ReviewPolicy(maxLayer: 1, requiresApproval: false),
            questionsForUser: [],
            risks: [],
            consensusReached: true,
            claudeAnalysis: error,
            codexAnalysis: "(未使用)"
        )
    }
}
