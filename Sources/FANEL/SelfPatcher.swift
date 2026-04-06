import Foundation
import os

enum PatchStatus: String, Codable, Sendable {
    case pushed
    case buildFailed
    case skipped
}

struct PatchResult: Codable, Sendable {
    let id: UUID
    let issueId: UUID
    let role: String
    let file: String
    let message: String
    let status: PatchStatus
    let branch: String?
    let diffSummary: String?
    let buildLog: String?
    let pushedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, role, file, message, status, branch
        case issueId = "issue_id"
        case diffSummary = "diff_summary"
        case buildLog = "build_log"
        case pushedAt = "pushed_at"
        case createdAt = "created_at"
    }
}

/// 自己修正を実行しGitにpushするActor（Claude Code経由）
actor SelfPatcher {

    static let shared = SelfPatcher()

    private let logger = Logger(subsystem: "com.fanel", category: "SelfPatcher")
    private var patchHistory: [PatchResult] = []
    private let maxHistory = 50
    private let maxPatchesPerCycle = 3
    private var claudeManager: ClaudeProcessManager?

    /// 修正禁止ファイル
    private let protectedFiles: Set<String> = [
        "OwnershipManager.swift",
        "TailscaleManager.swift",
        "PeerSyncManager.swift",
        "CouncilManager.swift",
        "FANELApp.swift",
    ]

    /// 修正対象の重要度フィルター
    private let allowedSeverities: Set<String> = ["critical", "warning"]

    private init() {}

    // MARK: - 単一Issue修正

    func patch(issue: ReviewIssue) async -> PatchResult {
        // 保護ファイルチェック
        let fileName = (issue.file as NSString).lastPathComponent
        if protectedFiles.contains(fileName) {
            let result = PatchResult(
                id: UUID(), issueId: issue.id, role: issue.role,
                file: issue.file, message: issue.message,
                status: .skipped, branch: nil, diffSummary: "保護ファイル: \(fileName)",
                buildLog: nil, pushedAt: nil, createdAt: Date()
            )
            appendHistory(result)
            await LogStore.shared.info("[SelfPatch] スキップ（保護ファイル）: \(fileName)")
            return result
        }

        // 重要度フィルター
        guard allowedSeverities.contains(issue.severity) else {
            let result = PatchResult(
                id: UUID(), issueId: issue.id, role: issue.role,
                file: issue.file, message: issue.message,
                status: .skipped, branch: nil, diffSummary: "severity=\(issue.severity) は自動修正対象外",
                buildLog: nil, pushedAt: nil, createdAt: Date()
            )
            appendHistory(result)
            return result
        }

        guard let projectRoot = findProjectRoot() else {
            return makeFailResult(issue: issue, log: "プロジェクトルートが見つかりません")
        }

        let cwd = URL(fileURLWithPath: projectRoot)
        let branch = makeBranchName()

        await LogStore.shared.info("[SelfPatch] 修正開始: \(issue.file) — \(issue.message)")

        // 1. stash で安全バックアップ
        let _ = runGit(["stash"], cwd: cwd)

        // 2. ブランチ作成/チェックアウト
        if runGit(["checkout", "-b", branch], cwd: cwd) != 0 {
            let _ = runGit(["checkout", branch], cwd: cwd)
        }

        // 3. stash pop（元の状態に戻す）
        let _ = runGit(["stash", "pop"], cwd: cwd)

        // 4. Hayabusaで修正コード生成 → ファイル書き込み
        let patchApplied = await generateAndApplyPatch(issue: issue, projectRoot: projectRoot)

        guard patchApplied else {
            // ロールバック
            let _ = runGit(["checkout", "."], cwd: cwd)
            let _ = runGit(["checkout", "-"], cwd: cwd)
            return makeFailResult(issue: issue, log: "パッチ生成失敗")
        }

        // 5. swift build
        let buildOk = await buildCheck(cwd: cwd)
        if !buildOk {
            // ロールバック
            let _ = runGit(["checkout", "."], cwd: cwd)
            let _ = runGit(["checkout", "-"], cwd: cwd)
            let result = PatchResult(
                id: UUID(), issueId: issue.id, role: issue.role,
                file: issue.file, message: issue.message,
                status: .buildFailed, branch: branch,
                diffSummary: "swift build失敗 → ロールバック済み",
                buildLog: "build failed", pushedAt: nil, createdAt: Date()
            )
            appendHistory(result)
            await LogStore.shared.warning("[SelfPatch] ビルド失敗 → ロールバック: \(issue.file)")
            return result
        }

        // 6. diff取得
        let diff = getDiffSummary(cwd: cwd)

        // 7. git add, commit, push
        let _ = runGit(["add", "-A"], cwd: cwd)
        let _ = runGit(["commit", "-m", "[SELF-IMPROVE] \(issue.role): \(issue.message.prefix(60))"], cwd: cwd)
        let pushOk = runGit(["push", "origin", branch], cwd: cwd) == 0

        // 元のブランチに戻る
        let _ = runGit(["checkout", "-"], cwd: cwd)

        let result = PatchResult(
            id: UUID(), issueId: issue.id, role: issue.role,
            file: issue.file, message: issue.message,
            status: pushOk ? .pushed : .buildFailed,
            branch: pushOk ? branch : nil,
            diffSummary: diff,
            buildLog: nil,
            pushedAt: pushOk ? Date() : nil,
            createdAt: Date()
        )
        appendHistory(result)

        if pushOk {
            await LogStore.shared.info("[SelfPatch] push完了: \(branch) — \(issue.file)")
        } else {
            await LogStore.shared.warning("[SelfPatch] push失敗: \(branch)")
        }

        return result
    }

    // MARK: - バッチ修正（最大3件）

    func patchBatch(issues: [ReviewIssue]) async -> [PatchResult] {
        let targets = issues
            .filter { allowedSeverities.contains($0.severity) }
            .filter { !protectedFiles.contains(($0.file as NSString).lastPathComponent) }
            .prefix(maxPatchesPerCycle)

        var results: [PatchResult] = []
        for issue in targets {
            if Task.isCancelled { break }
            let result = await patch(issue: issue)
            results.append(result)
        }
        return results
    }

    // MARK: - 履歴

    func recentPatches(_ count: Int = 20) -> [PatchResult] {
        Array(patchHistory.suffix(count).reversed())
    }

    // MARK: - ビルドチェック

    func buildCheck(cwd: URL) async -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["swift", "build"]
        proc.currentDirectoryURL = cwd
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Internal

    private func ensureClaude() async -> ClaudeProcessManager? {
        if claudeManager == nil {
            do {
                claudeManager = try await ClaudeProcessManager(timeoutSeconds: 120, maxRetries: 1)
            } catch {
                await LogStore.shared.error("[SelfPatch] Claude初期化失敗: \(error)")
                return nil
            }
        }
        return claudeManager
    }

    private func generateAndApplyPatch(issue: ReviewIssue, projectRoot: String) async -> Bool {
        guard let claude = await ensureClaude() else { return false }

        let filePath = "\(projectRoot)/Sources/FANEL/\(issue.file)"
        guard let currentCode = try? String(contentsOfFile: filePath, encoding: .utf8) else { return false }

        // 対象ファイルが大きすぎる場合はスキップ
        guard currentCode.count < 15000 else {
            await LogStore.shared.info("[SelfPatch] ファイルが大きすぎるためスキップ: \(issue.file)")
            return false
        }

        let prompt = """
        以下のSwiftファイルに対して修正を適用してください。

        問題: \(issue.message)
        提案: \(issue.suggestion)
        対象ファイル: \(issue.file)

        現在のコード:
        ```swift
        \(currentCode)
        ```

        修正後のファイル全体をそのまま出力してください。
        コードブロックやマーカーは不要です。修正後のSwiftコードだけを出力してください。
        """

        do {
            let result = try await claude.send(prompt: prompt)

            // コードブロックを除去
            var code = result
            if let startRange = code.range(of: "```swift\n"),
               let endRange = code.range(of: "\n```", options: .backwards) {
                code = String(code[startRange.upperBound..<endRange.lowerBound])
            } else if let startRange = code.range(of: "```\n"),
                      let endRange = code.range(of: "\n```", options: .backwards) {
                code = String(code[startRange.upperBound..<endRange.lowerBound])
            }

            // 最低限のSwiftコードチェック
            guard code.contains("import") || code.contains("func") || code.contains("struct") || code.contains("actor") else {
                await LogStore.shared.warning("[SelfPatch] 生成コードがSwiftに見えない: \(issue.file)")
                return false
            }

            // ファイル書き込み
            try code.write(toFile: filePath, atomically: true, encoding: .utf8)
            return true
        } catch {
            await LogStore.shared.error("[SelfPatch] パッチ生成エラー: \(error.localizedDescription)")
            return false
        }
    }

    private func getDiffSummary(cwd: URL) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "diff", "--stat"]
        proc.currentDirectoryURL = cwd
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private func runGit(_ args: [String], cwd: URL) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git"] + args
        proc.currentDirectoryURL = cwd
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return -1 }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private func makeBranchName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return "fanel/self-improve-\(formatter.string(from: Date()))"
    }

    private func findProjectRoot() -> String? {
        var dir = FileManager.default.currentDirectoryPath
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: "\(dir)/Package.swift") {
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser.path + "/Desktop/fanel"
        if FileManager.default.fileExists(atPath: "\(fallback)/Package.swift") { return fallback }
        return nil
    }

    private func makeFailResult(issue: ReviewIssue, log: String) -> PatchResult {
        let result = PatchResult(
            id: UUID(), issueId: issue.id, role: issue.role,
            file: issue.file, message: issue.message,
            status: .buildFailed, branch: nil, diffSummary: nil,
            buildLog: log, pushedAt: nil, createdAt: Date()
        )
        appendHistory(result)
        return result
    }

    private func appendHistory(_ result: PatchResult) {
        patchHistory.append(result)
        if patchHistory.count > maxHistory {
            patchHistory.removeFirst(patchHistory.count - maxHistory)
        }
    }
}
