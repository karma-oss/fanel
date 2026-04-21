import Foundation
import os

/// 7つのレビュー観点でコードを自己レビューするActor（Claude Code経由）
actor SelfReviewer {

    static let shared = SelfReviewer()

    private let logger = Logger(subsystem: "com.fanel", category: "SelfReviewer")
    private var claudeManager: ClaudeProcessManager?

    /// レビューロール定義
    struct ReviewRole: Sendable {
        let name: String
        let label: String
        let prompt: String
    }

    static let roles: [ReviewRole] = [
        ReviewRole(
            name: "architect",
            label: "設計",
            prompt: """
            アーキテクチャレビュー:
            - Actor間の循環依存がないか
            - 単一責務の原則に違反していないか
            - 不要な結合度の高さがないか
            - モジュール境界が適切か
            問題があれば severity(critical/warning/info), file, message, suggestion をJSON配列で回答。
            問題なければ空配列 [] を返してください。
            """
        ),
        ReviewRole(
            name: "security",
            label: "セキュリティ",
            prompt: """
            セキュリティレビュー:
            - コマンドインジェクションの危険がないか
            - 外部入力の検証が不十分でないか
            - 機密情報のハードコードがないか
            - ファイルパストラバーサルの可能性がないか
            問題があれば severity(critical/warning/info), file, message, suggestion をJSON配列で回答。
            問題なければ空配列 [] を返してください。
            """
        ),
        ReviewRole(
            name: "performance",
            label: "性能",
            prompt: """
            パフォーマンスレビュー:
            - 不必要なループや重い処理がないか
            - メモリリークの可能性がないか
            - 非同期処理のデッドロックリスクがないか
            - キャッシュすべき頻出計算がないか
            問題があれば severity(critical/warning/info), file, message, suggestion をJSON配列で回答。
            問題なければ空配列 [] を返してください。
            """
        ),
        ReviewRole(
            name: "readability",
            label: "可読性",
            prompt: """
            可読性レビュー:
            - 関数が長すぎないか（50行超）
            - 命名が不明瞭でないか
            - マジックナンバーがないか
            - 複雑すぎるネストがないか
            問題があれば severity(critical/warning/info), file, message, suggestion をJSON配列で回答。
            問題なければ空配列 [] を返してください。
            """
        ),
        ReviewRole(
            name: "testability",
            label: "テスト",
            prompt: """
            テスタビリティレビュー:
            - テストが書きにくい密結合がないか
            - 副作用の分離が不十分でないか
            - data-testid属性がインタラクティブ要素に付いているか
            - モック化が困難な外部依存がないか
            問題があれば severity(critical/warning/info), file, message, suggestion をJSON配列で回答。
            問題なければ空配列 [] を返してください。
            """
        ),
        ReviewRole(
            name: "operations",
            label: "運用",
            prompt: """
            運用レビュー:
            - ログ出力が十分か
            - エラーハンドリングが適切か
            - 設定の外部化ができているか
            - グレースフルシャットダウンが実装されているか
            問題があれば severity(critical/warning/info), file, message, suggestion をJSON配列で回答。
            問題なければ空配列 [] を返してください。
            """
        ),
        ReviewRole(
            name: "ux",
            label: "UX",
            prompt: """
            UXレビュー (CommandRoom.html):
            - ユーザーフィードバックが即時か
            - エラー状態の表示が適切か
            - 操作の取り消しが可能か
            - レスポンシブデザインに問題がないか
            問題があれば severity(critical/warning/info), file, message, suggestion をJSON配列で回答。
            問題なければ空配列 [] を返してください。
            """
        ),
    ]

    private init() {}

    // MARK: - Claude初期化

    private func ensureClaude() async -> ClaudeProcessManager? {
        if claudeManager == nil {
            do {
                claudeManager = try await ClaudeProcessManager(timeoutSeconds: 120, maxRetries: 1)
            } catch {
                await LogStore.shared.error("[SelfReview] Claude初期化失敗: \(error)")
                return nil
            }
        }
        return claudeManager
    }

    // MARK: - 全ロールレビュー

    /// 全7ロールでレビューを実行（Claude Code経由）
    func reviewAll() async -> String {
        guard let claude = await ensureClaude() else {
            return "Claude Code未検出 — レビュースキップ"
        }

        let units = await SelfKnowledgeDB.shared.allUnits()
        if units.isEmpty {
            return "インデックス未構築 — 先にindexSourcesを実行してください"
        }

        let codeSummary = buildCodeSummary(units: units)
        var allIssues: [ReviewIssue] = []

        for role in Self.roles {
            if Task.isCancelled { return "中断 (完了: \(allIssues.count)件)" }

            await LogStore.shared.info("[SelfReview] \(role.label) レビュー開始")

            let issues = await reviewWithRole(role: role, codeSummary: codeSummary, claude: claude)
            allIssues.append(contentsOf: issues)

            await LogStore.shared.info("[SelfReview] \(role.label): \(issues.count)件検出")
        }

        await SelfKnowledgeDB.shared.replaceIssues(allIssues)
        return "レビュー完了: \(allIssues.count)件 (\(Self.roles.count)ロール)"
    }

    // MARK: - 単一ロールレビュー

    func reviewWithRole(roleName: String) async -> [ReviewIssue] {
        guard let role = Self.roles.first(where: { $0.name == roleName }) else { return [] }
        guard let claude = await ensureClaude() else { return [] }

        let units = await SelfKnowledgeDB.shared.allUnits()
        let codeSummary = buildCodeSummary(units: units)

        return await reviewWithRole(role: role, codeSummary: codeSummary, claude: claude)
    }

    // MARK: - Internal

    private func reviewWithRole(role: ReviewRole, codeSummary: String, claude: ClaudeProcessManager) async -> [ReviewIssue] {
        let prompt = """
        \(role.prompt)

        対象コードの構造:
        \(codeSummary)

        回答はJSON配列のみ出力してください。マーカーやコードブロックは不要です。
        例: [{"severity":"warning","file":"Routes.swift","message":"問題の説明","suggestion":"修正案"}]
        問題なければ: []
        """

        do {
            let raw = try await claude.send(prompt: prompt)
            return parseReviewResponse(raw: raw, role: role.name)
        } catch {
            logger.error("[SelfReview] \(role.name) failed: \(error.localizedDescription)")
            return []
        }
    }

    private func buildCodeSummary(units: [SourceUnit]) -> String {
        var lines: [String] = []
        for unit in units {
            let deps = unit.dependencies.isEmpty ? "" : " → [\(unit.dependencies.joined(separator: ", "))]"
            let exps = unit.exports.isEmpty ? "" : " exports: \(unit.exports.prefix(5).joined(separator: ", "))"
            lines.append("- \(unit.path) (\(unit.kind), \(unit.lineCount)行)\(deps)\(exps)")
            if !unit.summary.isEmpty {
                lines.append("  \(unit.summary)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func parseReviewResponse(raw: String, role: String) -> [ReviewIssue] {
        // FANEL_RESPONSE マーカーからJSON抽出
        var jsonStr = raw
        if let beginRange = raw.range(of: "[FANEL_RESPONSE_BEGIN]"),
           let endRange = raw.range(of: "[FANEL_RESPONSE_END]") {
            jsonStr = String(raw[beginRange.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = jsonStr.data(using: .utf8),
               let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = envelope["message"] as? String {
                jsonStr = message
            }
        }

        // JSON配列を探す
        if let arrayStr = LooseJSONParser.extractFirstJSONArray(jsonStr),
           let data = arrayStr.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return arr.compactMap { dict -> ReviewIssue? in
                guard let message = dict["message"] as? String else { return nil }
                return ReviewIssue(
                    id: UUID(),
                    role: role,
                    severity: dict["severity"] as? String ?? "info",
                    file: dict["file"] as? String ?? "",
                    line: dict["line"] as? Int,
                    message: message,
                    suggestion: dict["suggestion"] as? String ?? "",
                    timestamp: Date()
                )
            }
        }

        // ブレーススキャンでJSONオブジェクトを探す（単一issue）
        if let objStr = LooseJSONParser.extractFirstJSON(jsonStr),
           let data = objStr.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = dict["message"] as? String {
            return [ReviewIssue(
                id: UUID(),
                role: role,
                severity: dict["severity"] as? String ?? "info",
                file: dict["file"] as? String ?? "",
                line: dict["line"] as? Int,
                message: message,
                suggestion: dict["suggestion"] as? String ?? "",
                timestamp: Date()
            )]
        }

        return []
    }
}
