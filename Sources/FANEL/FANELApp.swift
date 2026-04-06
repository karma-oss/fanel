import AppKit
import os

/// FANEL メニューバー常駐アプリのエントリーポイント
@main
struct FANELApp {

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // Dockに表示しない

        let delegate = FANELAppDelegate()
        app.delegate = delegate

        app.run() // メインスレッドのRunLoopを開始
    }
}

// MARK: - AppDelegate

final class FANELAppDelegate: NSObject, NSApplicationDelegate {

    private let logger = Logger(subsystem: "com.fanel", category: "App")
    private var statusItem: NSStatusItem!
    private var serverRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("FANEL starting...")
        setupStatusItem()

        // サーバー自動起動 + ModelRegistry監視開始
        Task {
            await LogStore.shared.info("FANEL 起動")
            await ProjectStore.shared.load()
            await ToolBoxStore.shared.load()
            await ModelRegistry.shared.startMonitoring()
            await TailscaleManager.shared.startPolling()
            let _ = await OwnershipManager.shared.acquireOwnership()
            await PeerSyncManager.shared.startSync()
            await IdleDetector.shared.setCallbacks(
                onStart: { await IdleTaskScheduler.shared.startIdleCycle() },
                onEnd: { await IdleTaskScheduler.shared.suspendIdleCycle() }
            )
            await IdleDetector.shared.startMonitoring()
            do {
                try await VaporServerManager.shared.start()
                await MainActor.run {
                    updateIcon(running: true)
                }
            } catch {
                logger.error("Auto-start failed: \(error.localizedDescription)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await IdleDetector.shared.stopMonitoring()
            await IdleTaskScheduler.shared.suspendIdleCycle()
            await PeerSyncManager.shared.stopSync()
            await OwnershipManager.shared.releaseOwnership()
            await TailscaleManager.shared.stopPolling()
            await ModelRegistry.shared.stopMonitoring()
            await VaporServerManager.shared.stop()
        }
    }

    // MARK: - メニューバー設定

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
            // SF Symbolsが使えない環境を考慮してテキスト表示
            button.title = running ? "🟢 FANEL" : "⏹ FANEL"
        }
    }

    // MARK: - メニューアクション

    @objc private func startServer() {
        Task {
            do {
                try await VaporServerManager.shared.start()
                await MainActor.run {
                    updateIcon(running: true)
                }
                logger.info("Server started on port 7384")
            } catch {
                logger.error("Server start failed: \(error.localizedDescription)")
                await LogStore.shared.error("サーバー起動失敗: \(error)")
            }
        }
    }

    @objc private func stopServer() {
        Task {
            await VaporServerManager.shared.stop()
            await MainActor.run {
                updateIcon(running: false)
            }
            logger.info("Server stopped")
        }
    }

    @objc private func openCommandRoom() {
        let urlString: String
        if serverRunning {
            urlString = "http://localhost:7384"
        } else {
            // サーバーが停止中でもURLを開く（エラーはブラウザ側で表示）
            urlString = "http://localhost:7384"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        Task {
            await VaporServerManager.shared.stop()
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
