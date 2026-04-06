import Foundation
import os

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

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: scriptsDir, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: entriesFile),
              let data = fm.contents(atPath: entriesFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([ToolBoxEntry].self, from: data) {
            for entry in loaded { entries[entry.id] = entry }
            logger.info("ToolBox loaded: \(loaded.count) entries")
        }
    }

    private func persist() {
        let all = Array(entries.values)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: URL(fileURLWithPath: entriesFile))
    }

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
        return bestMatch
    }

    // #2 Fix: scriptPathが安全なディレクトリ内かバリデーション
    func add(entry: ToolBoxEntry, script: String) throws {
        let resolvedPath = (entry.scriptPath as NSString).standardizingPath
        let resolvedScriptsDir = (scriptsDir as NSString).standardizingPath
        guard resolvedPath.hasPrefix(resolvedScriptsDir) else {
            throw FANELError.resourceNotFound(name: "scriptPath must be inside \(scriptsDir)")
        }

        let scriptURL = URL(fileURLWithPath: entry.scriptPath)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: entry.scriptPath
        )
        entries[entry.id] = entry
        persist()
        logger.info("ToolBox entry added: \(entry.name)")
    }

    // #2 Fix + #15 Fix: stdout/stderrを並列読み取り、パス検証追加
    func execute(entry: ToolBoxEntry, args: [String: String] = [:]) async throws -> String {
        let resolvedPath = (entry.scriptPath as NSString).standardizingPath
        let resolvedScriptsDir = (scriptsDir as NSString).standardizingPath
        guard resolvedPath.hasPrefix(resolvedScriptsDir) else {
            throw FANELError.resourceNotFound(name: "scriptPath outside safe directory")
        }

        let process = Process()
        if entry.scriptPath.hasSuffix(".py") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", entry.scriptPath]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [entry.scriptPath]
        }

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

        // #15 Fix: 並列読み取りでデッドロック防止
        let stdoutRead = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrRead = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let processWait = Task.detached { process.waitUntilExit() }
        let timeout = Task {
            try await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            process.terminate()
        }

        await processWait.value
        timeout.cancel()

        let outData = await stdoutRead.value
        let _ = await stderrRead.value
        let output = String(data: outData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw FANELError.processCrashed(exitCode: process.terminationStatus)
        }
        return output
    }

    func incrementUsage(id: UUID) {
        guard let e = entries[id] else { return }
        entries[id] = e.withUsageIncremented()
        persist()
    }

    func allEntries() -> [ToolBoxEntry] {
        entries.values.sorted { $0.usageCount > $1.usageCount }
    }

    func get(id: UUID) -> ToolBoxEntry? { entries[id] }

    func remove(id: UUID) {
        entries.removeValue(forKey: id)
        persist()
    }
}
