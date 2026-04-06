import Foundation
import Vapor
import os

/// 全プラグインを一元管理するActor
actor PluginRegistry {

    static let shared = PluginRegistry()

    private let logger = Logger(subsystem: "com.fanel", category: "PluginRegistry")
    private var plugins: [FANELPlugin] = []

    private init() {}

    /// プラグイン登録
    func register(_ plugin: FANELPlugin) {
        plugins.append(plugin)
        logger.info("Plugin registered: \(plugin.name)")
    }

    /// 全プラグインのルート登録
    func registerAllRoutes(_ app: Application) throws {
        for plugin in plugins {
            try plugin.register(routes: app)
            logger.info("Routes registered: \(plugin.name)")
        }
    }

    /// 全プラグインの起動処理
    func startupAll() async {
        for plugin in plugins {
            await plugin.onStartup()
            logger.info("Started: \(plugin.name)")
        }
    }

    /// 全プラグインの停止処理（逆順）
    func shutdownAll() async {
        for plugin in plugins.reversed() {
            await plugin.onShutdown()
            logger.info("Stopped: \(plugin.name)")
        }
    }

    /// 全プラグインにアイドル通知
    func notifyIdle() async {
        for plugin in plugins {
            await plugin.onIdle()
        }
    }

    /// 全プラグインにアクティビティ通知
    func notifyActivity() async {
        for plugin in plugins {
            await plugin.onActivity()
        }
    }

    /// 登録済みプラグイン名一覧
    func pluginNames() -> [String] {
        plugins.map { $0.name }
    }
}
