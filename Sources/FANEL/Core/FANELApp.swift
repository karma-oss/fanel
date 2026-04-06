import AppKit
import os

@main
struct FANELApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = FANELAppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class FANELAppDelegate: NSObject, NSApplicationDelegate {

    private let logger = Logger(subsystem: "com.fanel", category: "App")
    private var statusItem: NSStatusItem!
    private var serverRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("FANEL starting...")
        setupStatusItem()

        Task {
            await LogStore.shared.info("FANEL 起動")

            // プラグイン登録
            await PluginRegistry.shared.register(ServerPlugin())
            await PluginRegistry.shared.register(ProjectsPlugin())
            await PluginRegistry.shared.register(TasksPlugin())
            await PluginRegistry.shared.register(ModelsPlugin())
            await PluginRegistry.shared.register(OwnershipPlugin())
            await PluginRegistry.shared.register(PeersPlugin())
            await PluginRegistry.shared.register(ToolBoxPlugin())
            await PluginRegistry.shared.register(IdlePlugin())
            await PluginRegistry.shared.register(SelfEvolutionPlugin())

            // 全プラグイン起動
            await PluginRegistry.shared.startupAll()

            do {
                try await VaporServerManager.shared.start()
                await MainActor.run { self.updateIcon(running: true) }
            } catch {
                logger.error("Auto-start failed: \(error.localizedDescription)")
            }
        }
    }

    // #1 Fix: セマフォで同期的にシャットダウン完了を待つ
    func applicationWillTerminate(_ notification: Notification) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await VaporServerManager.shared.stop()
            await PluginRegistry.shared.shutdownAll()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(running: false)

        let menu = NSMenu()
        let startItem = NSMenuItem(title: "サーバー起動", action: #selector(startServer), keyEquivalent: "s")
        startItem.target = self
        menu.addItem(startItem)
        let stopItem = NSMenuItem(title: "サーバー停止", action: #selector(stopServer), keyEquivalent: "x")
        stopItem.target = self
        menu.addItem(stopItem)
        menu.addItem(NSMenuItem.separator())
        let openItem = NSMenuItem(title: "指令室を開く", action: #selector(openCommandRoom), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func updateIcon(running: Bool) {
        serverRunning = running
        if let button = statusItem.button {
            button.title = running ? "🟢 FANEL" : "⏹ FANEL"
        }
    }

    @objc private func startServer() {
        Task {
            do {
                try await VaporServerManager.shared.start()
                await MainActor.run { self.updateIcon(running: true) }
            } catch {
                await LogStore.shared.error("サーバー起動失敗: \(error)")
            }
        }
    }

    @objc private func stopServer() {
        Task {
            await VaporServerManager.shared.stop()
            await MainActor.run { self.updateIcon(running: false) }
        }
    }

    // #17 Fix: 無意味な分岐を削除
    @objc private func openCommandRoom() {
        if let url = URL(string: "http://localhost:7384") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        Task {
            await VaporServerManager.shared.stop()
            await MainActor.run { NSApplication.shared.terminate(nil) }
        }
    }
}
