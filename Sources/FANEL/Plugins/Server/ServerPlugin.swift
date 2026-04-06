import Foundation
import Vapor

/// サーバー基盤プラグイン: HTML配信、ステータス、ログAPI
struct ServerPlugin: FANELPlugin {

    let name = "Server"

    func register(routes app: Application) throws {
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
                "version": "0.8.0",
                "phase": "8",
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
    }
}
