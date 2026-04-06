import Foundation
import Vapor

/// ピア同期プラグイン: Tailscale、PeerSync
struct PeersPlugin: FANELPlugin {

    let name = "Peers"

    func register(routes app: Application) throws {
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
    }

    func onStartup() async {
        await TailscaleManager.shared.startPolling()
        await PeerSyncManager.shared.startSync()
    }

    func onShutdown() async {
        await PeerSyncManager.shared.stopSync()
        await TailscaleManager.shared.stopPolling()
    }
}
