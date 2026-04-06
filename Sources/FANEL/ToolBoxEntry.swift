import Foundation

enum ToolScope: String, Codable, Sendable {
    case global
    case projectScoped
    case trusted
    case experimental
}

struct ToolBoxEntry: Codable, Sendable {
    let id: UUID
    let name: String
    let description: String
    let scriptPath: String
    let scope: ToolScope
    let sideEffectLevel: Int       // 0=読み取りのみ〜3=破壊的変更
    let requiresApproval: Bool
    let safeToRunOnIdle: Bool
    let rollbackStrategy: String?
    let dryRunSupported: Bool
    let embedding: [Float]
    let usageCount: Int
    let lastUsedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, description, scope, embedding
        case scriptPath = "script_path"
        case sideEffectLevel = "side_effect_level"
        case requiresApproval = "requires_approval"
        case safeToRunOnIdle = "safe_to_run_on_idle"
        case rollbackStrategy = "rollback_strategy"
        case dryRunSupported = "dry_run_supported"
        case usageCount = "usage_count"
        case lastUsedAt = "last_used_at"
        case createdAt = "created_at"
    }

    func withUsageIncremented() -> ToolBoxEntry {
        ToolBoxEntry(id: id, name: name, description: description,
                     scriptPath: scriptPath, scope: scope,
                     sideEffectLevel: sideEffectLevel,
                     requiresApproval: requiresApproval,
                     safeToRunOnIdle: safeToRunOnIdle,
                     rollbackStrategy: rollbackStrategy,
                     dryRunSupported: dryRunSupported,
                     embedding: embedding,
                     usageCount: usageCount + 1,
                     lastUsedAt: Date(), createdAt: createdAt)
    }
}
