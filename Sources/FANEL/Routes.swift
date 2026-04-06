import Foundation
import Vapor

struct Routes {

    static func register(_ app: Application) throws {
        // GET / → 指令室HTML
        app.get { req async throws -> Response in
            let html = CommandRoomHTML.content
            return Response(
                status: .ok,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: .init(string: html)
            )
        }

        // GET /api/status → サーバー状態
        app.get("api", "status") { req async throws -> Response in
            let state = await VaporServerManager.shared.getState()
            let hayabusaUp = await HayabusaClient.shared.isAvailable()
            let toolboxCount = await ToolBoxStore.shared.allEntries().count
            let isOwner = await OwnershipManager.shared.isOwner()
            let owner = await OwnershipManager.shared.currentOwner() ?? "(none)"
            let tsConnected = await TailscaleManager.shared.isConnected()
            let tsInstalled = TailscaleManager.shared.isInstalled()
            let idle = await IdleDetector.shared.isIdle()
            let idleTask = await IdleTaskScheduler.shared.currentIdleTask()
            let status: [String: Any] = [
                "status": state.rawValue,
                "version": "0.7.0",
                "phase": "7",
                "hayabusa": hayabusaUp ? "online" : "offline",
                "toolbox_entries": toolboxCount,
                "is_owner": isOwner,
                "owner": owner,
                "tailscale": tsInstalled ? (tsConnected ? "connected" : "disconnected") : "not_installed",
                "idle": idle,
                "idle_task": idleTask ?? NSNull()
            ]
            let data = try JSONSerialization.data(
                withJSONObject: status,
                options: [.prettyPrinted, .sortedKeys]
            )
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: data)
            )
        }

        // GET /api/projects → ダミープロジェクト一覧
        app.get("api", "projects") { req async throws -> Response in
            let projects: [[String: Any]] = [
                [
                    "id": UUID().uuidString,
                    "name": "FANEL",
                    "path": "/Users/tanimura/Desktop/FANAL",
                    "status": "active",
                    "last_activity": ISO8601DateFormatter().string(from: Date())
                ],
                [
                    "id": UUID().uuidString,
                    "name": "SampleProject",
                    "path": "/Users/tanimura/Projects/sample",
                    "status": "idle",
                    "last_activity": ISO8601DateFormatter().string(
                        from: Date().addingTimeInterval(-3600)
                    )
                ]
            ]
            let data = try JSONSerialization.data(
                withJSONObject: projects,
                options: [.prettyPrinted, .sortedKeys]
            )
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: data)
            )
        }

        // POST /api/tasks → Council→WorkerPool経由でタスク送信（オーナーのみ）
        app.post("api", "tasks") { req async throws -> Response in
            // Tailscale接続中はオーナーチェック
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
            return try jsonResponse(envelope)
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
            return try jsonResponse(envelope)
        }

        // GET /api/logs
        app.get("api", "logs") { req async throws -> Response in
            let logs = await LogStore.shared.recent(50)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(logs)
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: data)
            )
        }

        // MARK: - Model Registry API

        // GET /api/models → モデル一覧
        app.get("api", "models") { req async throws -> Response in
            let models = await ModelRegistry.shared.allModels()
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(models)
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: data)
            )
        }

        // POST /api/models/:id/enable
        app.post("api", "models", ":modelId", "enable") { req async throws -> Response in
            guard let idStr = req.parameters.get("modelId"),
                  let id = UUID(uuidString: idStr) else {
                throw Abort(.badRequest, reason: "Invalid model ID")
            }
            await ModelRegistry.shared.enable(id: id)
            return Response(status: .ok, body: .init(string: "{\"ok\":true}"))
        }

        // POST /api/models/:id/disable
        app.post("api", "models", ":modelId", "disable") { req async throws -> Response in
            guard let idStr = req.parameters.get("modelId"),
                  let id = UUID(uuidString: idStr) else {
                throw Abort(.badRequest, reason: "Invalid model ID")
            }
            await ModelRegistry.shared.disable(id: id)
            return Response(status: .ok, body: .init(string: "{\"ok\":true}"))
        }

        // POST /api/models/:id/benchmark
        app.post("api", "models", ":modelId", "benchmark") { req async throws -> Response in
            guard let idStr = req.parameters.get("modelId"),
                  let id = UUID(uuidString: idStr) else {
                throw Abort(.badRequest, reason: "Invalid model ID")
            }
            Task { await ModelRegistry.shared.runBenchmark(modelId: id) }
            return Response(status: .accepted, body: .init(string: "{\"ok\":true,\"message\":\"benchmark started\"}"))
        }

        // MARK: - Idle API

        // GET /api/idle/status
        app.get("api", "idle", "status") { req async throws -> Response in
            let idle = await IdleDetector.shared.isIdle()
            let duration = await IdleDetector.shared.idleDuration()
            let currentTask = await IdleTaskScheduler.shared.currentIdleTask()
            let running = await IdleTaskScheduler.shared.isRunning()
            let result: [String: Any] = [
                "idle": idle,
                "idle_duration_seconds": Int(duration),
                "idle_cycle_running": running,
                "current_task": currentTask ?? NSNull()
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // GET /api/idle/history
        app.get("api", "idle", "history") { req async throws -> Response in
            let history = await IdleTaskScheduler.shared.recentHistory(10)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(history)
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // POST /api/idle/suspend
        app.post("api", "idle", "suspend") { req async throws -> Response in
            await IdleTaskScheduler.shared.suspendIdleCycle()
            return Response(status: .ok, body: .init(string: "{\"ok\":true}"))
        }

        // POST /api/idle/resume
        app.post("api", "idle", "resume") { req async throws -> Response in
            await IdleTaskScheduler.shared.startIdleCycle()
            return Response(status: .ok, body: .init(string: "{\"ok\":true}"))
        }

        // MARK: - Ownership & Peers API

        // GET /api/ownership
        app.get("api", "ownership") { req async throws -> Response in
            let isOwner = await OwnershipManager.shared.isOwner()
            let lease = await OwnershipManager.shared.currentLeaseInfo()
            var result: [String: Any] = ["is_owner": isOwner]
            if let l = lease {
                result["owner"] = l.ownerHostname
                result["acquired_at"] = ISO8601DateFormatter().string(from: l.acquiredAt)
                result["expires_at"] = ISO8601DateFormatter().string(from: l.expiresAt)
            } else {
                result["owner"] = NSNull()
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // POST /api/ownership/acquire
        app.post("api", "ownership", "acquire") { req async throws -> Response in
            let success = await OwnershipManager.shared.acquireOwnership()
            let body = success ? "{\"ok\":true}" : "{\"ok\":false,\"reason\":\"ownership conflict\"}"
            return Response(status: success ? .ok : .conflict, body: .init(string: body))
        }

        // POST /api/ownership/release
        app.post("api", "ownership", "release") { req async throws -> Response in
            await OwnershipManager.shared.releaseOwnership()
            return Response(status: .ok, body: .init(string: "{\"ok\":true}"))
        }

        // GET /api/peers
        app.get("api", "peers") { req async throws -> Response in
            let ts = await TailscaleManager.shared.status()
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(ts)
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // GET /api/sync/status
        app.get("api", "sync", "status") { req async throws -> Response in
            let syncStatus = await PeerSyncManager.shared.syncStatus()
            let data = try JSONSerialization.data(withJSONObject: syncStatus, options: [.prettyPrinted, .sortedKeys])
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // MARK: - Progress API

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

        // MARK: - ToolBox API

        // GET /api/toolbox → エントリ一覧
        app.get("api", "toolbox") { req async throws -> Response in
            let entries = await ToolBoxStore.shared.allEntries()
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: data)
            )
        }

        // POST /api/toolbox → 手動登録
        app.post("api", "toolbox") { req async throws -> Response in
            struct ToolBoxRequest: Content {
                let name: String
                let description: String
                let script: String
            }
            let tbReq = try req.content.decode(ToolBoxRequest.self)
            let embedding = await EmbeddingEngine.shared.embed(text: tbReq.description)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let id = UUID()
            let entry = ToolBoxEntry(
                id: id, name: tbReq.name, description: tbReq.description,
                scriptPath: "\(home)/.fanel/toolbox/scripts/\(id).sh",
                scope: .experimental, sideEffectLevel: 0,
                requiresApproval: false, safeToRunOnIdle: true,
                rollbackStrategy: nil, dryRunSupported: false,
                embedding: embedding, usageCount: 0,
                lastUsedAt: nil, createdAt: Date()
            )
            try await ToolBoxStore.shared.add(entry: entry, script: tbReq.script)
            return Response(status: .created, body: .init(string: "{\"ok\":true,\"id\":\"\(id)\"}"))
        }

        // DELETE /api/toolbox/:id → 削除
        app.delete("api", "toolbox", ":entryId") { req async throws -> Response in
            guard let idStr = req.parameters.get("entryId"),
                  let id = UUID(uuidString: idStr) else {
                throw Abort(.badRequest, reason: "Invalid entry ID")
            }
            await ToolBoxStore.shared.remove(id: id)
            return Response(status: .ok, body: .init(string: "{\"ok\":true}"))
        }

        // POST /api/toolbox/:id/execute → 手動実行
        app.post("api", "toolbox", ":entryId", "execute") { req async throws -> Response in
            guard let idStr = req.parameters.get("entryId"),
                  let id = UUID(uuidString: idStr) else {
                throw Abort(.badRequest, reason: "Invalid entry ID")
            }
            guard let entry = await ToolBoxStore.shared.get(id: id) else {
                throw Abort(.notFound, reason: "Entry not found")
            }
            let result = try await ToolBoxStore.shared.execute(entry: entry)
            await ToolBoxStore.shared.incrementUsage(id: id)
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(string: "{\"ok\":true,\"output\":\"\(result.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n"))\"}")
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
