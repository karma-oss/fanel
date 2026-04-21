import Foundation
import os

struct EvolutionStatus: Codable, Sendable {
    let isRunning: Bool
    let currentPhase: String
    let patchesApplied: Int
    let patchesFailed: Int
    let patchesSkipped: Int
    let lastCycleAt: Date?

    enum CodingKeys: String, CodingKey {
        case isRunning = "is_running"
        case currentPhase = "current_phase"
        case patchesApplied = "patches_applied"
        case patchesFailed = "patches_failed"
        case patchesSkipped = "patches_skipped"
        case lastCycleAt = "last_cycle_at"
    }
}

/// インデックス → レビュー → パッチの自己進化サイクルを管理
actor SelfEvolutionOrchestrator {

    static let shared = SelfEvolutionOrchestrator()

    private let logger = Logger(subsystem: "com.fanel", category: "SelfEvolution")
    private var _isRunning = false
    private var _currentPhase = "idle"
    private var _patchesApplied = 0
    private var _patchesFailed = 0
    private var _patchesSkipped = 0
    private var _lastCycleAt: Date?

    private init() {}

    // MARK: - 自己進化サイクル

    func runEvolutionCycle() async -> String {
        guard !_isRunning else { return "既に実行中" }
        _isRunning = true
        _patchesApplied = 0
        _patchesFailed = 0
        _patchesSkipped = 0

        await LogStore.shared.info("[Evolution] 自己進化サイクル開始")

        // Phase 1: インデックス更新
        _currentPhase = "indexing"
        let indexResult = await SelfIndexer.shared.indexSources()
        await LogStore.shared.info("[Evolution] インデックス: \(indexResult)")

        if Task.isCancelled { return finish("中断") }

        // Phase 2: レビュー実行
        _currentPhase = "reviewing"
        let reviewResult = await SelfReviewer.shared.reviewAll()
        await LogStore.shared.info("[Evolution] レビュー: \(reviewResult)")

        if Task.isCancelled { return finish("中断") }

        // Phase 3: 修正可能なissueをパッチ
        _currentPhase = "patching"
        let issues = await SelfKnowledgeDB.shared.allIssues()
        let patchable = issues.filter { ["critical", "warning"].contains($0.severity) }

        if patchable.isEmpty {
            return finish("修正対象なし")
        }

        let results = await SelfPatcher.shared.patchBatch(issues: Array(patchable))

        for r in results {
            switch r.status {
            case .pushed: _patchesApplied += 1
            case .buildFailed: _patchesFailed += 1
            case .skipped: _patchesSkipped += 1
            }
        }

        let summary = "適用:\(_patchesApplied) 失敗:\(_patchesFailed) スキップ:\(_patchesSkipped)"
        await LogStore.shared.info("[Evolution] パッチ完了 — \(summary)")

        return finish(summary)
    }

    // MARK: - 状態取得

    func status() -> EvolutionStatus {
        EvolutionStatus(
            isRunning: _isRunning,
            currentPhase: _currentPhase,
            patchesApplied: _patchesApplied,
            patchesFailed: _patchesFailed,
            patchesSkipped: _patchesSkipped,
            lastCycleAt: _lastCycleAt
        )
    }

    // MARK: - Internal

    private func finish(_ result: String) -> String {
        _currentPhase = "idle"
        _isRunning = false
        _lastCycleAt = Date()
        return result
    }
}
