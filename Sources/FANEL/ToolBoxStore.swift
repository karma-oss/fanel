import Foundation
import os

/// ToolBoxのエントリを管理するActor
actor ToolBoxStore {

    static let shared = ToolBoxStore()

    private let logger = Logger(subsystem: "com.fanel", category: "ToolBoxStore")
    private var entries: [UUID: ToolBoxEntry] = [:]
    private let baseDir: String
    private let scriptsDir: String
    private let entriesFile: String

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.baseDir = "\(home)/.fanel/toolbox"
        self.scriptsDir = "\(home)/.fanel/toolbox/scripts"
        self.entriesFile = "\(home)/.fanel/toolbox/entries.json"
    }

    // MARK: - 初期化

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: scriptsDir, withIntermediateDirectories: true)

        guard fm.fileExists(atPath: entriesFile),
              let data = fm.contents(atPath: entriesFile) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([ToolBoxEntry].self, from: data) {
            for entry in loaded {
                entries[entry.id] = entry
            }
            logger.info("ToolBox loaded: \(loaded.count) entries")
        }
    }

    // MARK: - 永続化

    private func persist() {
        let all = Array(entries.values)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: URL(fileURLWithPath: entriesFile))
    }

    // MARK: - ベクトル類似検索

    func search(query: String, threshold: Float = 0.85) async -> ToolBoxEntry? {
        let queryVec = await EmbeddingEngine.shared.embed(text: query)

        var bestMatch: ToolBoxEntry?
        var bestScore: Float = 0

        for entry in entries.values {
            guard !entry.embedding.isEmpty else { continue }
            let score = await EmbeddingEngine.shared.cosineSimilarity(queryVec, entry.embedding)
            if score > bestScore && score >= threshold {
                bestScore = score
                bestMatch = entry
            }
        }

        if let match = bestMatch {
            logger.info("ToolBox hit: \(match.name) (score: \(bestScore))")
        }

        return bestMatch
    }

    // MARK: - エントリ追加

    func add(entry: ToolBoxEntry, script: String) throws {
        // スクリプト保存
        let scriptURL = URL(fileURLWithPath: entry.scriptPath)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // 実行権限付与
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: entry.scriptPath
        )

        entries[entry.id] = entry
        persist()
        logger.info("ToolBox entry added: \(entry.name)")
    }

    // MARK: - スクリプト実行

    func execute(entry: ToolBoxEntry, args: [String: String] = [:]) async throws -> String {
        let process = Process()
        let scriptPath = entry.scriptPath

        // スクリプトの拡張子で実行方法を決定
        if scriptPath.hasSuffix(".py") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", scriptPath]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
        }

        // 環境変数として引数を渡す
        var env = ProcessInfo.processInfo.environment
        for (key, value) in args {
            env["FANEL_ARG_\(key.uppercased())"] = value
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // タイムアウト10秒
        let processWait = Task.detached { process.waitUntilExit() }
        let timeout = Task {
            try await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            process.terminate()
        }

        await processWait.value
        timeout.cancel()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errOutput = String(data: errData, encoding: .utf8) ?? ""
            throw FANELError.processCrashed(exitCode: process.terminationStatus)
        }

        return output
    }

    // MARK: - 使用回数更新

    func incrementUsage(id: UUID) {
        guard let entry = entries[id] else { return }
        let updated = ToolBoxEntry(
            id: entry.id, name: entry.name, description: entry.description,
            scriptPath: entry.scriptPath, scope: entry.scope,
            sideEffectLevel: entry.sideEffectLevel,
            requiresApproval: entry.requiresApproval,
            safeToRunOnIdle: entry.safeToRunOnIdle,
            rollbackStrategy: entry.rollbackStrategy,
            dryRunSupported: entry.dryRunSupported,
            embedding: entry.embedding,
            usageCount: entry.usageCount + 1,
            lastUsedAt: Date(),
            createdAt: entry.createdAt
        )
        entries[id] = updated
        persist()
    }

    // MARK: - 取得

    func allEntries() -> [ToolBoxEntry] {
        entries.values.sorted { $0.usageCount > $1.usageCount }
    }

    func get(id: UUID) -> ToolBoxEntry? {
        entries[id]
    }

    func remove(id: UUID) {
        entries.removeValue(forKey: id)
        persist()
    }
}
