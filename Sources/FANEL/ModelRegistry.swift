import Foundation
import os

enum ModelStatus: String, Codable, Sendable {
    case active
    case inactive
    case benchmarking
    case experimental
}

struct ModelProfile: Codable, Sendable {
    let id: UUID
    let name: String
    let filePath: String
    let fileSizeMB: Int
    let layer: Int          // 1〜4
    let tokensPerSec: Double
    let qualityScore: Double
    let memoryMB: Int
    let status: ModelStatus
    let profiledAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, layer, status
        case filePath = "file_path"
        case fileSizeMB = "file_size_mb"
        case tokensPerSec = "tokens_per_sec"
        case qualityScore = "quality_score"
        case memoryMB = "memory_mb"
        case profiledAt = "profiled_at"
    }
}

/// 利用可能なモデルを管理するActor
actor ModelRegistry {

    static let shared = ModelRegistry()

    private let logger = Logger(subsystem: "com.fanel", category: "ModelRegistry")
    private let modelsDir: String
    private var models: [UUID: ModelProfile] = [:]
    private var scanTask: Task<Void, Never>?
    private var isBenchmarking = false

    private let extraModelDirs: [String]

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.modelsDir = "\(home)/.hayabusa/models"
        self.extraModelDirs = [
            "\(home)/Desktop/名称未設定フォルダ/hayabusa/models"
        ]
    }

    // MARK: - 初期化・スキャン開始

    func startMonitoring() {
        // 初回スキャン
        Task { await scanModels() }

        // 定期スキャン（30秒ごと）
        scanTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                await scanModels()
            }
        }

        // Claude Code (Layer 4) を常に登録
        registerClaudeCode()
    }

    func stopMonitoring() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - モデルスキャン

    private func scanModels() {
        let fm = FileManager.default

        // ディレクトリ作成
        if !fm.fileExists(atPath: modelsDir) {
            try? fm.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
        }

        // 全モデルディレクトリをスキャン
        var allFiles: [(dir: String, file: String)] = []
        for dir in [modelsDir] + extraModelDirs {
            if let files = try? fm.contentsOfDirectory(atPath: dir) {
                for f in files where f.hasSuffix(".gguf") {
                    allFiles.append((dir: dir, file: f))
                }
            }
        }

        for entry in allFiles {
            let fullPath = "\(entry.dir)/\(entry.file)"
            let file = entry.file

            // 既に登録済みか確認
            if models.values.contains(where: { $0.filePath == fullPath }) { continue }

            // 新しいモデル検出
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let fileSize = attrs[.size] as? Int else { continue }

            let sizeMB = fileSize / (1024 * 1024)
            let layer = classifyBySize(sizeMB: sizeMB)
            let name = String(file.dropLast(5)) // .gguf除去

            let profile = ModelProfile(
                id: UUID(),
                name: name,
                filePath: fullPath,
                fileSizeMB: sizeMB,
                layer: layer,
                tokensPerSec: 0,
                qualityScore: 0,
                memoryMB: 0,
                status: .experimental,
                profiledAt: Date()
            )

            models[profile.id] = profile
            logger.info("New model detected: \(name) (\(sizeMB)MB → Layer \(layer))")

            Task { await LogStore.shared.info("モデル検出: \(name) (\(sizeMB)MB → Layer \(layer))") }
        }
    }

    // MARK: - サイズベース分類

    private func classifyBySize(sizeMB: Int) -> Int {
        switch sizeMB {
        case 0..<2048:    return 1  // 2GB以下
        case 2048..<8192: return 2  // 2〜8GB
        case 8192..<40960: return 3 // 8〜40GB
        default:          return 4  // 40GB以上
        }
    }

    // MARK: - Claude Code登録

    private func registerClaudeCode() {
        let claudeId = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        if models[claudeId] != nil { return }

        models[claudeId] = ModelProfile(
            id: claudeId,
            name: "claude-code",
            filePath: "/Applications/cmux.app/Contents/Resources/bin/claude",
            fileSizeMB: 0,
            layer: 4,
            tokensPerSec: 0,
            qualityScore: 1.0,
            memoryMB: 0,
            status: .active,
            profiledAt: Date()
        )
    }

    // MARK: - 手動追加

    func addManual(name: String, filePath: String, layer: Int) {
        let profile = ModelProfile(
            id: UUID(),
            name: name,
            filePath: filePath,
            fileSizeMB: 0,
            layer: min(4, max(1, layer)),
            tokensPerSec: 0,
            qualityScore: 0,
            memoryMB: 0,
            status: .experimental,
            profiledAt: Date()
        )
        models[profile.id] = profile
        logger.info("Model added manually: \(name) (Layer \(layer))")
    }

    // MARK: - 更新

    func update(id: UUID, name: String?, layer: Int?, statusStr: String?) {
        guard let m = models[id] else { return }
        let newStatus: ModelStatus
        if let s = statusStr, let parsed = ModelStatus(rawValue: s) {
            newStatus = parsed
        } else {
            newStatus = m.status
        }
        models[id] = ModelProfile(
            id: m.id,
            name: name ?? m.name,
            filePath: m.filePath,
            fileSizeMB: m.fileSizeMB,
            layer: layer ?? m.layer,
            tokensPerSec: m.tokensPerSec,
            qualityScore: m.qualityScore,
            memoryMB: m.memoryMB,
            status: newStatus,
            profiledAt: m.profiledAt
        )
        logger.info("Model updated: \(self.models[id]!.name)")
    }

    // MARK: - ベンチマーク実行

    func runBenchmark(modelId: UUID) async {
        guard var model = models[modelId] else { return }
        guard model.layer <= 3 else { return } // Claude Codeはベンチマーク不要
        guard !isBenchmarking else {
            await LogStore.shared.warning("別のベンチマークが実行中です")
            return
        }

        isBenchmarking = true
        defer { isBenchmarking = false }

        // ステータス更新
        models[modelId] = ModelProfile(
            id: model.id, name: model.name, filePath: model.filePath,
            fileSizeMB: model.fileSizeMB, layer: model.layer,
            tokensPerSec: model.tokensPerSec, qualityScore: model.qualityScore,
            memoryMB: model.memoryMB, status: .benchmarking, profiledAt: model.profiledAt
        )

        await LogStore.shared.info("ベンチマーク開始: \(model.name)")

        do {
            let result = try await HayabusaClient.shared.benchmark(model: model.name)

            // Layer再分類（品質スコアで調整）
            var layer = model.layer
            if result.qualityScore < 0.3 && layer > 1 { layer = max(1, layer - 1) }
            if result.qualityScore > 0.8 && layer < 3 { layer = min(3, layer + 1) }

            let updated = ModelProfile(
                id: model.id, name: model.name, filePath: model.filePath,
                fileSizeMB: model.fileSizeMB, layer: layer,
                tokensPerSec: result.tokensPerSec,
                qualityScore: result.qualityScore,
                memoryMB: model.fileSizeMB, // 近似値
                status: .active, profiledAt: Date()
            )
            models[modelId] = updated

            await LogStore.shared.info("ベンチマーク完了: \(model.name) — \(String(format: "%.1f", result.tokensPerSec)) tok/s, quality=\(String(format: "%.2f", result.qualityScore)), Layer \(layer)")
        } catch {
            // ベンチマーク失敗 → experimentalに戻す
            models[modelId] = ModelProfile(
                id: model.id, name: model.name, filePath: model.filePath,
                fileSizeMB: model.fileSizeMB, layer: model.layer,
                tokensPerSec: 0, qualityScore: 0, memoryMB: 0,
                status: .experimental, profiledAt: Date()
            )
            await LogStore.shared.error("ベンチマーク失敗: \(model.name) — \(error)")
        }
    }

    // MARK: - モデル取得

    func allModels() -> [ModelProfile] {
        models.values.sorted { $0.layer < $1.layer || ($0.layer == $1.layer && $0.name < $1.name) }
    }

    func modelsForLayer(_ layer: Int) -> [ModelProfile] {
        models.values.filter { $0.layer == layer && $0.status == .active }
    }

    func bestModelForLayer(_ layer: Int) -> ModelProfile? {
        modelsForLayer(layer)
            .sorted { $0.qualityScore > $1.qualityScore }
            .first
    }

    func get(id: UUID) -> ModelProfile? {
        models[id]
    }

    // MARK: - モデル有効/無効

    func enable(id: UUID) {
        guard var model = models[id] else { return }
        models[id] = ModelProfile(
            id: model.id, name: model.name, filePath: model.filePath,
            fileSizeMB: model.fileSizeMB, layer: model.layer,
            tokensPerSec: model.tokensPerSec, qualityScore: model.qualityScore,
            memoryMB: model.memoryMB, status: .active, profiledAt: model.profiledAt
        )
    }

    func disable(id: UUID) {
        guard var model = models[id] else { return }
        models[id] = ModelProfile(
            id: model.id, name: model.name, filePath: model.filePath,
            fileSizeMB: model.fileSizeMB, layer: model.layer,
            tokensPerSec: model.tokensPerSec, qualityScore: model.qualityScore,
            memoryMB: model.memoryMB, status: .inactive, profiledAt: model.profiledAt
        )
    }
}
