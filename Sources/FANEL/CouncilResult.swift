import Foundation

struct ReviewPolicy: Codable, Sendable {
    let maxLayer: Int
    let requiresApproval: Bool

    enum CodingKeys: String, CodingKey {
        case maxLayer = "max_layer"
        case requiresApproval = "requires_approval"
    }
}

struct CouncilResult: Codable, Sendable {
    // 既存フィールド
    let goal: String
    let constraints: [String]
    let complexity: Int
    let executionPlan: [String]
    let reviewPolicy: ReviewPolicy
    let questionsForUser: [String]
    let risks: [String]
    let consensusReached: Bool
    let claudeAnalysis: String
    let codexAnalysis: String

    // 進捗トラッキング（全てoptional・デフォルト値あり）
    let progressScore: Int           // 0〜100, -1=不明
    let remainingSlices: [String]
    let blockers: [String]
    let currentMilestone: String
    let estimatedSlices: Int         // 残り作業スライス数

    enum CodingKeys: String, CodingKey {
        case goal, constraints, complexity, risks, blockers
        case executionPlan = "execution_plan"
        case reviewPolicy = "review_policy"
        case questionsForUser = "questions_for_user"
        case consensusReached = "consensus_reached"
        case claudeAnalysis = "claude_analysis"
        case codexAnalysis = "codex_analysis"
        case progressScore = "progress_score"
        case remainingSlices = "remaining_slices"
        case currentMilestone = "current_milestone"
        case estimatedSlices = "estimated_slices"
    }

    // 後方互換デコード
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal = try c.decode(String.self, forKey: .goal)
        constraints = try c.decodeIfPresent([String].self, forKey: .constraints) ?? []
        complexity = try c.decodeIfPresent(Int.self, forKey: .complexity) ?? 0
        executionPlan = try c.decodeIfPresent([String].self, forKey: .executionPlan) ?? []
        reviewPolicy = try c.decodeIfPresent(ReviewPolicy.self, forKey: .reviewPolicy)
            ?? ReviewPolicy(maxLayer: 1, requiresApproval: false)
        questionsForUser = try c.decodeIfPresent([String].self, forKey: .questionsForUser) ?? []
        risks = try c.decodeIfPresent([String].self, forKey: .risks) ?? []
        consensusReached = try c.decodeIfPresent(Bool.self, forKey: .consensusReached) ?? true
        claudeAnalysis = try c.decodeIfPresent(String.self, forKey: .claudeAnalysis) ?? ""
        codexAnalysis = try c.decodeIfPresent(String.self, forKey: .codexAnalysis) ?? ""
        progressScore = try c.decodeIfPresent(Int.self, forKey: .progressScore) ?? -1
        remainingSlices = try c.decodeIfPresent([String].self, forKey: .remainingSlices) ?? []
        blockers = try c.decodeIfPresent([String].self, forKey: .blockers) ?? []
        currentMilestone = try c.decodeIfPresent(String.self, forKey: .currentMilestone) ?? ""
        estimatedSlices = try c.decodeIfPresent(Int.self, forKey: .estimatedSlices) ?? 0
    }

    // 直接初期化（既存コードとの互換）
    init(goal: String, constraints: [String], complexity: Int,
         executionPlan: [String], reviewPolicy: ReviewPolicy,
         questionsForUser: [String], risks: [String],
         consensusReached: Bool, claudeAnalysis: String, codexAnalysis: String,
         progressScore: Int = -1, remainingSlices: [String] = [],
         blockers: [String] = [], currentMilestone: String = "",
         estimatedSlices: Int = 0) {
        self.goal = goal
        self.constraints = constraints
        self.complexity = complexity
        self.executionPlan = executionPlan
        self.reviewPolicy = reviewPolicy
        self.questionsForUser = questionsForUser
        self.risks = risks
        self.consensusReached = consensusReached
        self.claudeAnalysis = claudeAnalysis
        self.codexAnalysis = codexAnalysis
        self.progressScore = progressScore
        self.remainingSlices = remainingSlices
        self.blockers = blockers
        self.currentMilestone = currentMilestone
        self.estimatedSlices = estimatedSlices
    }
}

/// ClaudeまたはCodexから返ってくる分析レスポンスの中間型
struct CouncilAnalysis: Codable, Sendable {
    let complexity: Int
    let constraints: [String]
    let executionPlan: [String]
    let risks: [String]
    let questionsForUser: [String]
    let progressScore: Int
    let remainingSlices: [String]
    let blockers: [String]
    let currentMilestone: String
    let estimatedSlices: Int

    enum CodingKeys: String, CodingKey {
        case complexity, constraints, risks, blockers
        case executionPlan = "execution_plan"
        case questionsForUser = "questions_for_user"
        case progressScore = "progress_score"
        case remainingSlices = "remaining_slices"
        case currentMilestone = "current_milestone"
        case estimatedSlices = "estimated_slices"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        complexity = try c.decodeIfPresent(Int.self, forKey: .complexity) ?? 0
        constraints = try c.decodeIfPresent([String].self, forKey: .constraints) ?? []
        executionPlan = try c.decodeIfPresent([String].self, forKey: .executionPlan) ?? []
        risks = try c.decodeIfPresent([String].self, forKey: .risks) ?? []
        questionsForUser = try c.decodeIfPresent([String].self, forKey: .questionsForUser) ?? []
        progressScore = try c.decodeIfPresent(Int.self, forKey: .progressScore) ?? -1
        remainingSlices = try c.decodeIfPresent([String].self, forKey: .remainingSlices) ?? []
        blockers = try c.decodeIfPresent([String].self, forKey: .blockers) ?? []
        currentMilestone = try c.decodeIfPresent(String.self, forKey: .currentMilestone) ?? ""
        estimatedSlices = try c.decodeIfPresent(Int.self, forKey: .estimatedSlices) ?? 0
    }

    init(complexity: Int, constraints: [String], executionPlan: [String],
         risks: [String], questionsForUser: [String],
         progressScore: Int = -1, remainingSlices: [String] = [],
         blockers: [String] = [], currentMilestone: String = "",
         estimatedSlices: Int = 0) {
        self.complexity = complexity
        self.constraints = constraints
        self.executionPlan = executionPlan
        self.risks = risks
        self.questionsForUser = questionsForUser
        self.progressScore = progressScore
        self.remainingSlices = remainingSlices
        self.blockers = blockers
        self.currentMilestone = currentMilestone
        self.estimatedSlices = estimatedSlices
    }
}
