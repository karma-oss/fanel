import Foundation
import Vapor

/// タスク実行プラグイン: Council→WorkerPool→タスク履歴
struct TasksPlugin: FANELPlugin {

    let name = "Tasks"

    func register(routes app: Application) throws {
        // POST /api/tasks → Council→WorkerPool経由でタスク送信（オーナーのみ）
        app.post("api", "tasks") { req async throws -> Response in
            let tsConnected = await TailscaleManager.shared.isConnected()
            if tsConnected {
                let isOwner = await OwnershipManager.shared.isOwner()
                if !isOwner {
                    let owner = await OwnershipManager.shared.currentOwner() ?? "unknown"
                    throw Abort(.forbidden, reason: "読み取り専用モード: オーナーは \(owner)")
                }
                await OwnershipManager.shared.recordActivity()
            }

            struct TaskRequest: Content {
                let goal: String
            }
            let taskReq = try req.content.decode(TaskRequest.self)
            let envelope = await TaskOrchestrator.shared.submit(goal: taskReq.goal)
            return try Self.jsonResponse(envelope)
        }

        // GET /api/tasks → タスク履歴
        app.get("api", "tasks") { req async throws -> Response in
            let tasks = await TaskStore.shared.recent(20)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(tasks)
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: data)
            )
        }

        // POST /api/tasks/:id/answer
        app.post("api", "tasks", ":taskId", "answer") { req async throws -> Response in
            struct AnswerRequest: Content {
                let answer: String
            }
            guard let taskIdStr = req.parameters.get("taskId"),
                  let taskId = UUID(uuidString: taskIdStr) else {
                throw Abort(.badRequest, reason: "Invalid task ID")
            }
            let answerReq = try req.content.decode(AnswerRequest.self)
            guard let envelope = await TaskOrchestrator.shared.answerAndResume(
                taskId: taskId, answer: answerReq.answer
            ) else {
                throw Abort(.notFound, reason: "Task not found")
            }
            return try Self.jsonResponse(envelope)
        }

        // GET /api/progress → 全タスクの進捗サマリー
        app.get("api", "progress") { req async throws -> Response in
            let tasks = await TaskStore.shared.recent(20)
            let active = tasks.filter { $0.status == .running || $0.status == .waitingForCouncil || $0.status == .waitingForUser }

            var allBlockers: [String] = []
            var milestones: [[String: Any]] = []
            var progressSum = 0
            var progressCount = 0

            for t in tasks {
                if let c = t.councilResult {
                    if c.progressScore >= 0 {
                        progressSum += c.progressScore
                        progressCount += 1
                    }
                    allBlockers.append(contentsOf: c.blockers)
                    if !c.currentMilestone.isEmpty {
                        milestones.append([
                            "task_id": t.id.uuidString,
                            "goal": t.goal,
                            "milestone": c.currentMilestone,
                            "progress": c.progressScore
                        ])
                    }
                }
            }

            let overall = progressCount > 0 ? progressSum / progressCount : -1

            let summary: [String: Any] = [
                "overall_progress": overall,
                "active_tasks": active.count,
                "total_tasks": tasks.count,
                "blockers": Array(Set(allBlockers)),
                "recent_milestones": milestones.prefix(10).map { $0 }
            ]

            let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: data)
            )
        }
    }

    private static func jsonResponse(_ envelope: TaskEnvelope) throws -> Response {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: data)
        )
    }
}
