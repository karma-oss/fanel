import Foundation

enum TaskStatus: String, Codable, Sendable {
    case draft
    case waitingForCouncil
    case waitingForUser
    case running
    case complete
    case waiting
    case error
}

struct TaskEnvelope: Codable, Sendable {
    let id: UUID
    let goal: String
    let status: TaskStatus
    let message: String
    let filesModified: [String]
    let nextAction: String?
    let requiresApproval: Bool
    let createdAt: Date
    let updatedAt: Date
    let councilResult: CouncilResult?

    enum CodingKeys: String, CodingKey {
        case id, goal, status, message
        case filesModified = "files_modified"
        case nextAction = "next_action"
        case requiresApproval = "requires_approval"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case councilResult = "council_result"
    }

    init(id: UUID, goal: String, status: TaskStatus, message: String,
         filesModified: [String] = [], nextAction: String? = nil,
         requiresApproval: Bool = false, createdAt: Date = Date(),
         updatedAt: Date = Date(), councilResult: CouncilResult? = nil) {
        self.id = id
        self.goal = goal
        self.status = status
        self.message = message
        self.filesModified = filesModified
        self.nextAction = nextAction
        self.requiresApproval = requiresApproval
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.councilResult = councilResult
    }
}

/// Claude Codeから返ってくるレスポンスの構造体
struct ClaudeResponse: Codable {
    let status: TaskStatus
    let message: String
    let filesModified: [String]
    let nextAction: String?
    let requiresApproval: Bool

    enum CodingKeys: String, CodingKey {
        case status, message
        case filesModified = "files_modified"
        case nextAction = "next_action"
        case requiresApproval = "requires_approval"
    }

    func toEnvelope(goal: String) -> TaskEnvelope {
        TaskEnvelope(
            id: UUID(),
            goal: goal,
            status: status,
            message: message,
            filesModified: filesModified,
            nextAction: nextAction,
            requiresApproval: requiresApproval
        )
    }
}
