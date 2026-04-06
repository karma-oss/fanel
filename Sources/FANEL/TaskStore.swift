import Foundation
import os

/// タスクの状態を管理するActor
actor TaskStore {

    static let shared = TaskStore()

    private let logger = Logger(subsystem: "com.fanel", category: "TaskStore")
    private var tasks: [UUID: TaskEnvelope] = [:]
    private var order: [UUID] = []
    private let maxTasks = 20

    private init() {}

    func add(_ task: TaskEnvelope) {
        tasks[task.id] = task
        order.append(task.id)

        while order.count > maxTasks {
            let oldId = order.removeFirst()
            tasks.removeValue(forKey: oldId)
        }

        logger.info("Task added: \(task.id) — \(task.goal)")
    }

    func update(id: UUID, status: TaskStatus, message: String,
                filesModified: [String] = [], nextAction: String? = nil,
                requiresApproval: Bool = false, councilResult: CouncilResult? = nil) {
        guard let existing = tasks[id] else { return }

        let updated = TaskEnvelope(
            id: existing.id,
            goal: existing.goal,
            status: status,
            message: message,
            filesModified: filesModified,
            nextAction: nextAction,
            requiresApproval: requiresApproval,
            createdAt: existing.createdAt,
            updatedAt: Date(),
            councilResult: councilResult ?? existing.councilResult
        )
        tasks[id] = updated
        logger.info("Task updated: \(id) → \(status.rawValue)")
    }

    func get(id: UUID) -> TaskEnvelope? {
        tasks[id]
    }

    func recent(_ count: Int = 20) -> [TaskEnvelope] {
        let ids = order.suffix(count).reversed()
        return ids.compactMap { tasks[$0] }
    }
}
