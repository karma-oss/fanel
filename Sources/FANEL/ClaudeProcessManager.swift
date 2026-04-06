import Foundation
import os

/// Claude Codeプロセスをサブプロセスとして起動・制御するActor
actor ClaudeProcessManager {

    private let logger = Logger(subsystem: "com.fanel", category: "ClaudeProcessManager")
    private let timeoutSeconds: Int
    private let maxRetries: Int
    private let claudePath: String

    init(timeoutSeconds: Int = 30, maxRetries: Int = 1) async throws {
        self.timeoutSeconds = timeoutSeconds
        self.maxRetries = maxRetries
        self.claudePath = try ClaudeProcessManager.resolveClaudePath()
    }

    // MARK: - Claude Codeパスの動的解決

    private static func resolveClaudePath() throws -> String {
        // 既知のパスを先にチェック
        let knownPaths = [
            "/usr/local/bin/claude",
            "/Applications/cmux.app/Contents/Resources/bin/claude"
        ]

        for path in knownPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // which claude で動的取得
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["claude"]

        let pipe = Pipe()
        whichProcess.standardOutput = pipe

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            // fall through
        }

        throw FANELError.claudeNotFound
    }

    // MARK: - プロンプト送信（リトライ付き）

    func send(prompt: String) async throws -> String {
        var lastError: FANELError?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                logger.info("Retrying (attempt \(attempt + 1))...")
            }

            do {
                let result = try await executeOnce(prompt: prompt)
                return result
            } catch let error as FANELError {
                lastError = error
                logger.error("Attempt \(attempt + 1) failed: \(error.description)")
            } catch {
                lastError = .processStartFailed(underlying: error)
                logger.error("Attempt \(attempt + 1) failed: \(error.localizedDescription)")
            }
        }

        throw FANELError.retryExhausted(lastError: lastError ?? .claudeNotFound)
    }

    // MARK: - 1回分のプロセス実行

    private func executeOnce(prompt: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["--print", prompt]

        // 作業ディレクトリをアクティブプロジェクトに設定
        let activeProject = await ProjectStore.shared.activeProject()
        let projectRoot = activeProject?.path ?? FileManager.default.currentDirectoryPath
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw FANELError.processStartFailed(underlying: error)
        }

        let pid = process.processIdentifier
        logger.info("Claude process started (PID: \(pid))")

        // タイムアウト用タスク
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds) * 1_000_000_000)
            return true
        }

        // Stdout/Stderr読み取り（別スレッドでブロッキング読み取り）
        let stdoutTask = Task.detached { () -> String in
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }

        let stderrTask = Task.detached { () -> String in
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }

        // プロセス完了 or タイムアウトを待つ
        let processTask = Task.detached {
            process.waitUntilExit()
        }

        // タイムアウトとプロセス完了のレース
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await processTask.value
                return false // プロセス完了
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds) * 1_000_000_000)
                    return true // タイムアウト
                } catch {
                    return false // キャンセルされた
                }
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        timeoutTask.cancel()

        if timedOut {
            process.terminate()
            stdoutTask.cancel()
            stderrTask.cancel()
            throw FANELError.timeout(seconds: timeoutSeconds)
        }

        let stderrOutput = await stderrTask.value
        if !stderrOutput.isEmpty {
            logger.warning("stderr: \(stderrOutput.prefix(500))")
        }

        if process.terminationStatus != 0 {
            // クラッシュ検知
            logger.error("Process crashed (exit code: \(process.terminationStatus))")
            throw FANELError.processCrashed(exitCode: process.terminationStatus)
        }

        let stdoutOutput = await stdoutTask.value

        guard !stdoutOutput.isEmpty else {
            throw FANELError.jsonParseFailed(rawOutput: "(empty output)")
        }

        return stdoutOutput
    }
}
