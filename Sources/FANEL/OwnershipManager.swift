import Foundation
import os

struct OwnerLease: Codable, Sendable {
    let ownerHostname: String
    let acquiredAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case ownerHostname = "owner_hostname"
        case acquiredAt = "acquired_at"
        case expiresAt = "expires_at"
    }
}

/// 2拠点間のオーナー制を管理するActor
actor OwnershipManager {

    static let shared = OwnershipManager()

    private let logger = Logger(subsystem: "com.fanel", category: "OwnershipManager")
    private let lockFilePath: String
    private let leaseDuration: TimeInterval = 15 * 60  // 15分
    private var currentLease: OwnerLease?
    private var idleTimer: Task<Void, Never>?
    private var lastActivity: Date = Date()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.lockFilePath = "\(home)/.fanel/owner.lock"
        // 起動時にロックファイルを読み込み
        loadLease()
    }

    // MARK: - オーナー権限取得

    func acquireOwnership() async -> Bool {
        let myHost = await TailscaleManager.shared.myHostname()
            ?? Host.current().localizedName ?? "unknown"

        // 既に自分がオーナーなら更新
        if let lease = currentLease, lease.ownerHostname == myHost {
            return renewLease(hostname: myHost)
        }

        // 他者がオーナーで期限内なら拒否
        if let lease = currentLease, lease.ownerHostname != myHost, lease.expiresAt > Date() {
            await LogStore.shared.warning("オーナー権限取得失敗: 現在のオーナーは \(lease.ownerHostname)")
            return false
        }

        // 取得（期限切れ or 空き）
        let now = Date()
        let lease = OwnerLease(
            ownerHostname: myHost,
            acquiredAt: now,
            expiresAt: now.addingTimeInterval(leaseDuration)
        )
        currentLease = lease
        saveLease(lease)
        startIdleTimer()

        await LogStore.shared.info("オーナー権限取得: \(myHost)")
        return true
    }

    // MARK: - オーナー権限解放

    func releaseOwnership() async {
        guard let lease = currentLease else { return }

        let myHost = await TailscaleManager.shared.myHostname()
            ?? Host.current().localizedName ?? "unknown"

        if lease.ownerHostname == myHost {
            currentLease = nil
            try? FileManager.default.removeItem(atPath: lockFilePath)
            idleTimer?.cancel()
            idleTimer = nil
            await LogStore.shared.info("オーナー権限解放: \(myHost)")
        }
    }

    // MARK: - 状態確認

    func isOwner() async -> Bool {
        guard let lease = currentLease else { return false }
        let myHost = await TailscaleManager.shared.myHostname()
            ?? Host.current().localizedName ?? "unknown"

        // 期限切れチェック
        if lease.expiresAt <= Date() {
            currentLease = nil
            try? FileManager.default.removeItem(atPath: lockFilePath)
            return false
        }

        return lease.ownerHostname == myHost
    }

    func currentOwner() -> String? {
        guard let lease = currentLease, lease.expiresAt > Date() else { return nil }
        return lease.ownerHostname
    }

    func currentLeaseInfo() -> OwnerLease? {
        guard let lease = currentLease, lease.expiresAt > Date() else { return nil }
        return lease
    }

    // MARK: - アクティビティ記録

    func recordActivity() {
        lastActivity = Date()
        // リース更新
        if let lease = currentLease {
            _ = renewLease(hostname: lease.ownerHostname)
        }
    }

    // MARK: - アイドル自動移譲

    func checkAndTransferIfIdle() async {
        guard let lease = currentLease else { return }
        let myHost = await TailscaleManager.shared.myHostname()
            ?? Host.current().localizedName ?? "unknown"
        guard lease.ownerHostname == myHost else { return }

        let idleTime = Date().timeIntervalSince(lastActivity)
        if idleTime > leaseDuration {
            await LogStore.shared.info("15分アイドル — オーナー権限を自動解放")
            await releaseOwnership()
        }
    }

    // MARK: - アイドルタイマー

    private func startIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000) // 1分ごとチェック
                await checkAndTransferIfIdle()
            }
        }
    }

    // MARK: - リース更新

    private func renewLease(hostname: String) -> Bool {
        let now = Date()
        let lease = OwnerLease(
            ownerHostname: hostname,
            acquiredAt: now,
            expiresAt: now.addingTimeInterval(leaseDuration)
        )
        currentLease = lease
        saveLease(lease)
        return true
    }

    // MARK: - 永続化

    private func loadLease() {
        guard let data = FileManager.default.contents(atPath: lockFilePath) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let lease = try? decoder.decode(OwnerLease.self, from: data) {
            // 期限切れでなければ読み込み
            if lease.expiresAt > Date() {
                currentLease = lease
            } else {
                // 期限切れ — クリーンアップ
                try? FileManager.default.removeItem(atPath: lockFilePath)
            }
        }
    }

    private func saveLease(_ lease: OwnerLease) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(lease) else { return }
        FileManager.default.createFile(atPath: lockFilePath, contents: data)
    }
}
