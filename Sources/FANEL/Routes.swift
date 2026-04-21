import Foundation
import Vapor

struct Routes {

    static func register(_ app: Application) throws {
        // GET / → 指令室HTML
        app.get { req async throws -> Response in
            let html = CommandRoomHTML.content
            return Response(
                status: .ok,
                headers: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Cache-Control": "no-cache, no-store, must-revalidate",
                    "Pragma": "no-cache",
                ],
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

        // GET /api/projects → プロジェクト一覧
        app.get("api", "projects") { req async throws -> Response in
            let projects = await ProjectStore.shared.list()
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(projects)
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // POST /api/projects → プロジェクト追加
        app.post("api", "projects") { req async throws -> Response in
            struct AddRequest: Content {
                let name: String
                let path: String
            }
            let r = try req.content.decode(AddRequest.self)
            let project = await ProjectStore.shared.add(name: r.name, path: r.path)
            await LogStore.shared.info("プロジェクト追加: \(project.name)")
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(project)
            return Response(status: .created, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // DELETE /api/projects/:id → プロジェクト削除
        app.delete("api", "projects", ":projectId") { req async throws -> Response in
            guard let idStr = req.parameters.get("projectId"),
                  let id = UUID(uuidString: idStr) else {
                throw Abort(.badRequest, reason: "Invalid project ID")
            }
            await ProjectStore.shared.remove(id: id)
            return Response(status: .ok, body: .init(string: "{\"ok\":true}"))
        }

        // POST /api/projects/:id/activate → アクティブ切替
        app.post("api", "projects", ":projectId", "activate") { req async throws -> Response in
            guard let idStr = req.parameters.get("projectId"),
                  let id = UUID(uuidString: idStr) else {
                throw Abort(.badRequest, reason: "Invalid project ID")
            }
            await ProjectStore.shared.activate(id: id)
            let name = await ProjectStore.shared.get(id: id)?.name ?? ""
            await LogStore.shared.info("プロジェクト切替: \(name)")
            return Response(status: .ok, body: .init(string: "{\"ok\":true}"))
        }

        // PUT /api/projects/:id → プロジェクト更新
        app.put("api", "projects", ":projectId") { req async throws -> Response in
            struct UpdateRequest: Content {
                let name: String?
                let path: String?
            }
            guard let idStr = req.parameters.get("projectId"),
                  let id = UUID(uuidString: idStr) else {
                throw Abort(.badRequest, reason: "Invalid project ID")
            }
            let r = try req.content.decode(UpdateRequest.self)
            await ProjectStore.shared.update(id: id, name: r.name, path: r.path)
            return Response(status: .ok, body: .init(string: "{\"ok\":true}"))
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

        // POST /api/models → モデル手動追加
        app.post("api", "models") { req async throws -> Response in
            struct AddModelRequest: Content {
                let name: String
                let path: String?
                let layer: Int?
            }
            let r = try req.content.decode(AddModelRequest.self)
            await ModelRegistry.shared.addManual(name: r.name, filePath: r.path ?? "", layer: r.layer ?? 2)
            await LogStore.shared.info("モデル手動追加: \(r.name)")
            return Response(status: .created, body: .init(string: "{\"ok\":true}"))
        }

        // PUT /api/models/:id → モデル更新
        app.put("api", "models", ":modelId") { req async throws -> Response in
            struct UpdateModelRequest: Content {
                let name: String?
                let layer: Int?
                let status: String?
            }
            guard let idStr = req.parameters.get("modelId"),
                  let id = UUID(uuidString: idStr) else {
                throw Abort(.badRequest, reason: "Invalid model ID")
            }
            let r = try req.content.decode(UpdateModelRequest.self)
            await ModelRegistry.shared.update(id: id, name: r.name, layer: r.layer, statusStr: r.status)
            return Response(status: .ok, body: .init(string: "{\"ok\":true}"))
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

        // MARK: - Self-Index / Self-Review API

        // GET /api/self/summary → 自己認識サマリー
        app.get("api", "self", "summary") { req async throws -> Response in
            let summary = await SelfKnowledgeDB.shared.summary()
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // GET /api/self/units → インデックス済みファイル一覧
        app.get("api", "self", "units") { req async throws -> Response in
            let units = await SelfKnowledgeDB.shared.allUnits()
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(units)
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // GET /api/self/issues → 全レビュー結果
        app.get("api", "self", "issues") { req async throws -> Response in
            let role = req.query[String.self, at: "role"]
            let issues: [ReviewIssue]
            if let r = role {
                issues = await SelfKnowledgeDB.shared.issuesByRole(r)
            } else {
                issues = await SelfKnowledgeDB.shared.allIssues()
            }
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(issues)
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // GET /api/self/explain → 自己説明
        app.get("api", "self", "explain") { req async throws -> Response in
            let explanation = await SelfIndexer.shared.explainSelf()
            let data = try JSONSerialization.data(withJSONObject: explanation, options: [.prettyPrinted, .sortedKeys])
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // GET /api/self/graph → 依存グラフ
        app.get("api", "self", "graph") { req async throws -> Response in
            let graph = await SelfIndexer.shared.dependencyGraph()
            let data = try JSONSerialization.data(withJSONObject: graph, options: [.prettyPrinted, .sortedKeys])
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // GET /api/self/impact?file=xxx → 影響ファイル検索
        app.get("api", "self", "impact") { req async throws -> Response in
            guard let file = req.query[String.self, at: "file"] else {
                throw Abort(.badRequest, reason: "file parameter required")
            }
            let impacted = await SelfIndexer.shared.findImpactedFiles(targetFile: file)
            let data = try JSONSerialization.data(withJSONObject: ["file": file, "impacted": impacted], options: [.prettyPrinted, .sortedKeys])
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // POST /api/self/index → 手動インデックス実行
        app.post("api", "self", "index") { req async throws -> Response in
            Task { await SelfIndexer.shared.indexSources() }
            return Response(status: .accepted, body: .init(string: "{\"ok\":true,\"message\":\"indexing started\"}"))
        }

        // POST /api/self/review → 手動レビュー実行
        app.post("api", "self", "review") { req async throws -> Response in
            struct ReviewRequest: Content {
                let role: String?
            }
            let r = try? req.content.decode(ReviewRequest.self)
            if let roleName = r?.role {
                Task {
                    let issues = await SelfReviewer.shared.reviewWithRole(roleName: roleName)
                    await SelfKnowledgeDB.shared.addIssues(issues)
                }
                return Response(status: .accepted, body: .init(string: "{\"ok\":true,\"message\":\"review started for \(roleName)\"}"))
            } else {
                Task { await SelfReviewer.shared.reviewAll() }
                return Response(status: .accepted, body: .init(string: "{\"ok\":true,\"message\":\"full review started\"}"))
            }
        }

        // MARK: - Self-Patch / Evolution API

        // GET /api/self/patches → パッチ履歴
        app.get("api", "self", "patches") { req async throws -> Response in
            let patches = await SelfPatcher.shared.recentPatches(20)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(patches)
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // POST /api/self/patch/:issueId → 特定Issueを修正してpush
        app.post("api", "self", "patch", ":issueId") { req async throws -> Response in
            guard let idStr = req.parameters.get("issueId"),
                  let issueId = UUID(uuidString: idStr) else {
                throw Abort(.badRequest, reason: "Invalid issue ID")
            }
            let issues = await SelfKnowledgeDB.shared.allIssues()
            guard let issue = issues.first(where: { $0.id == issueId }) else {
                throw Abort(.notFound, reason: "Issue not found")
            }
            Task {
                let result = await SelfPatcher.shared.patch(issue: issue)
                await LogStore.shared.info("[API] パッチ結果: \(result.status.rawValue) — \(result.file)")
            }
            return Response(status: .accepted, body: .init(string: "{\"ok\":true,\"message\":\"patching started\"}"))
        }

        // GET /api/self/evolution → 自己進化サイクル状態
        app.get("api", "self", "evolution") { req async throws -> Response in
            let status = await SelfEvolutionOrchestrator.shared.status()
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(status)
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }

        // POST /api/self/evolution/run → 今すぐ自己進化サイクル実行
        app.post("api", "self", "evolution", "run") { req async throws -> Response in
            Task { await SelfEvolutionOrchestrator.shared.runEvolutionCycle() }
            return Response(status: .accepted, body: .init(string: "{\"ok\":true,\"message\":\"evolution cycle started\"}"))
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
