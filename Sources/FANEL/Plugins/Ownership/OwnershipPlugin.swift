import Foundation
import Vapor

/// オーナーシップ管理プラグイン
struct OwnershipPlugin: FANELPlugin {

    let name = "Ownership"

    func register(routes app: Application) throws {
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
    }

    func onStartup() async {
        let _ = await OwnershipManager.shared.acquireOwnership()
    }

    func onShutdown() async {
        await OwnershipManager.shared.releaseOwnership()
    }
}
