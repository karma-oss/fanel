import Foundation
import os

/// 相手拠点のFANELとリアルタイム同期するActor
actor PeerSyncManager {

    static let shared = PeerSyncManager()

    private let logger = Logger(subsystem: "com.fanel", category: "PeerSyncManager")
    private var syncTask: Task<Void, Never>?

    private init() {}

    // MARK: - 同期開始・停止

    func startSync() {
        syncTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if await TailscaleManager.shared.isConnected() {
                    await syncLogs()
                }
            }
        }
    }

    func stopSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    // MARK: - ピアへのping

    func pingPeer() async -> Bool {
        guard let endpoint = await TailscaleManager.shared.peerFANELEndpoint() else {
            return false
        }

        guard let url = URL(string: "\(endpoint)/api/status") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - タスク状態同期

    func syncTaskState(_ task: TaskEnvelope) async {
        guard let endpoint = await TailscaleManager.shared.peerFANELEndpoint() else { return }
        guard let url = URL(string: "\(endpoint)/api/sync/task") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        req.httpBody = try? encoder.encode(task)

        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - ログ同期

    func syncLogs() async {
        // 相手拠点のFANELが起動しているか確認
        guard await pingPeer() else { return }
        // ログ同期は軽量なポーリングのみ（双方向pushは将来Phase）
        logger.debug("Peer sync check completed")
    }

    // MARK: - Git push（アイドル時・安全ポリシー準拠）

    func pushToGit(branch: String) async throws {
        // 安全ポリシー: fanel/idle- ブランチのみ
        guard branch.hasPrefix("fanel/idle-") else {
            throw FANELError.gitPushFailed(reason: "ブランチ名が不正: \(branch). fanel/idle-* のみ許可")
        }

        // オーナーのみ
        guard await OwnershipManager.shared.isOwner() else {
            throw FANELError.gitPushFailed(reason: "オーナーのみgit pushが可能")
        }

        // ビルドチェック
        let buildProc = Process()
        buildProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        buildProc.arguments = ["swift", "build"]
        buildProc.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let buildPipe = Pipe()
        buildProc.standardOutput = buildPipe
        buildProc.standardError = buildPipe

        try buildProc.run()
        buildProc.waitUntilExit()

        guard buildProc.terminationStatus == 0 else {
            throw FANELError.gitPushFailed(reason: "swift build が失敗しました")
        }

        // git checkout -b, add, commit, push
        let commands = [
            ["git", "checkout", "-b", branch],
            ["git", "add", "-A"],
            ["git", "commit", "-m", "FANEL idle auto-commit: \(branch)"],
            ["git", "push", "origin", branch]
        ]

        for cmd in commands {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = cmd
            proc.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try proc.run()
            proc.waitUntilExit()

            if proc.terminationStatus != 0 && cmd[1] != "checkout" {
                // checkout失敗はブランチ既存の場合があるので無視
                throw FANELError.gitPushFailed(reason: "コマンド失敗: \(cmd.joined(separator: " "))")
            }
        }

        await LogStore.shared.info("Git push完了: \(branch)")
    }

    // MARK: - 同期状態

    func syncStatus() async -> [String: Any] {
        let peerOnline = await pingPeer()
        let tailscaleConnected = await TailscaleManager.shared.isConnected()
        let peerEndpoint = await TailscaleManager.shared.peerFANELEndpoint()

        return [
            "tailscale_connected": tailscaleConnected,
            "peer_online": peerOnline,
            "peer_endpoint": peerEndpoint ?? "(none)"
        ]
    }
}
