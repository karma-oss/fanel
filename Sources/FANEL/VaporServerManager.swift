import Foundation
import Vapor
import os

enum ServerState: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case stopping
}

/// Vaporサーバーの起動・停止を管理するActor
actor VaporServerManager {

    static let shared = VaporServerManager()

    private let logger = Logger(subsystem: "com.fanel", category: "VaporServerManager")
    private let port: Int = 7384

    private var app: Application?
    private var serverTask: Task<Void, Error>?
    private(set) var state: ServerState = .stopped
    private var bonjourService: NetService?

    private init() {}

    // MARK: - サーバー起動

    func start() async throws {
        guard state == .stopped else {
            throw FANELError.serverAlreadyRunning
        }

        state = .starting
        await LogStore.shared.info("サーバーを起動中 (port: \(port))...")

        do {
            let app = try await Application.make(.production)
            app.http.server.configuration.hostname = "0.0.0.0"
            app.http.server.configuration.port = port

            // ルート登録
            try configureRoutes(app)

            self.app = app

            // バックグラウンドでVaporを起動
            serverTask = Task.detached { [app] in
                try await app.execute()
            }

            state = .running
            await LogStore.shared.info("サーバー起動完了: http://localhost:\(port)")

            // mDNS (Bonjour) 広告開始
            startBonjour()

        } catch {
            state = .stopped
            self.app = nil
            await LogStore.shared.error("サーバー起動失敗: \(error)")
            throw FANELError.serverStartFailed(underlying: error)
        }
    }

    // MARK: - サーバー停止

    func stop() async {
        guard state == .running else { return }

        state = .stopping
        await LogStore.shared.info("サーバーを停止中...")

        stopBonjour()

        if let app = self.app {
            try? await app.asyncShutdown()
        }

        serverTask?.cancel()
        serverTask = nil
        app = nil
        state = .stopped

        await LogStore.shared.info("サーバー停止完了")
    }

    // MARK: - ルート設定

    private func configureRoutes(_ app: Application) throws {
        try Routes.register(app)
    }

    // MARK: - Bonjour (mDNS) 広告

    private func startBonjour() {
        let service = NetService(
            domain: "local.",
            type: "_http._tcp.",
            name: "FANEL指令室",
            port: Int32(port)
        )
        service.publish()
        self.bonjourService = service
        logger.info("Bonjour service published: FANEL指令室._http._tcp.local. on port \(self.port)")
    }

    private func stopBonjour() {
        bonjourService?.stop()
        bonjourService = nil
        logger.info("Bonjour service stopped")
    }

    // MARK: - 状態取得

    func getState() -> ServerState {
        return state
    }
}
