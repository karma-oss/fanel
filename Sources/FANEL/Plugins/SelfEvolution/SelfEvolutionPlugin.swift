import Foundation
import Vapor

/// 自己進化プラグイン: インデックス、レビュー、パッチ、進化サイクル
struct SelfEvolutionPlugin: FANELPlugin {

    let name = "SelfEvolution"

    func register(routes app: Application) throws {
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
}
