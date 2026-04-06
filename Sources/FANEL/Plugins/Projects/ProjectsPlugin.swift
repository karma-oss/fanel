import Foundation
import Vapor

/// プロジェクト管理プラグイン
struct ProjectsPlugin: FANELPlugin {

    let name = "Projects"

    func register(routes app: Application) throws {
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
    }

    func onStartup() async {
        await ProjectStore.shared.load()
    }
}
