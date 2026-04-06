import Foundation
import Vapor

/// アイドル管理プラグイン: IdleDetector、IdleTaskScheduler、IdleTaskRunner
struct IdlePlugin: FANELPlugin {

    let name = "Idle"

    func register(routes app: Application) throws {
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
    }

    func onStartup() async {
        await IdleDetector.shared.setCallbacks(
            onStart: { await IdleTaskScheduler.shared.startIdleCycle() },
            onEnd: { await IdleTaskScheduler.shared.suspendIdleCycle() }
        )
        await IdleDetector.shared.startMonitoring()
    }

    func onShutdown() async {
        await IdleDetector.shared.stopMonitoring()
        await IdleTaskScheduler.shared.suspendIdleCycle()
    }

    func onIdle() async {
        await IdleTaskScheduler.shared.startIdleCycle()
    }

    func onActivity() async {
        await IdleTaskScheduler.shared.suspendIdleCycle()
    }
}
