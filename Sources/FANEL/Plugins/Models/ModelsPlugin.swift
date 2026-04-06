import Foundation
import Vapor

/// モデル管理プラグイン: ModelRegistry、Hayabusa、Embedding
struct ModelsPlugin: FANELPlugin {

    let name = "Models"

    func register(routes app: Application) throws {
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
    }

    func onStartup() async {
        await ModelRegistry.shared.startMonitoring()
    }

    func onShutdown() async {
        await ModelRegistry.shared.stopMonitoring()
    }
}
