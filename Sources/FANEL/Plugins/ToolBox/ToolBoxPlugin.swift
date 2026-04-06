import Foundation
import Vapor

/// ToolBox管理プラグイン: スクリプト登録・実行
struct ToolBoxPlugin: FANELPlugin {

    let name = "ToolBox"

    func register(routes app: Application) throws {
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

    func onStartup() async {
        await ToolBoxStore.shared.load()
    }
}
