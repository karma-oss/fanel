import Foundation
import os

struct TailscalePeer: Codable, Sendable {
    let hostname: String
    let online: Bool
    let tailscaleIP: String

    enum CodingKeys: String, CodingKey {
        case hostname, online
        case tailscaleIP = "tailscale_ip"
    }
}

struct TailscaleStatus: Codable, Sendable {
    let connected: Bool
    let myHostname: String
    let peers: [TailscalePeer]

    enum CodingKeys: String, CodingKey {
        case connected, peers
        case myHostname = "my_hostname"
    }
}

/// Tailscale接続状態を管理するActor
actor TailscaleManager {

    static let shared = TailscaleManager()

    private let logger = Logger(subsystem: "com.fanel", category: "TailscaleManager")
    private var installed = false
    private var cachedStatus: TailscaleStatus?
    private var pollTask: Task<Void, Never>?
    private let fanelPort = 7384

    private init() {
        self.installed = Self.checkInstalled()
    }

    private static func checkInstalled() -> Bool {
        let paths = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                     "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        for p in paths {
            if FileManager.default.isExecutableFile(atPath: p) { return true }
        }
        // which tailscale
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["tailscale"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch { return false }
    }

    private func tailscalePath() -> String? {
        let paths = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        for p in paths {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    // MARK: - ポーリング

    func startPolling() {
        guard installed else {
            logger.info("Tailscale未インストール — ローカルモードで動作")
            return
        }
        pollTask = Task {
            while !Task.isCancelled {
                await refreshStatus()
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - ステータス取得

    func status() async -> TailscaleStatus {
        if let cached = cachedStatus { return cached }
        await refreshStatus()
        return cachedStatus ?? TailscaleStatus(connected: false, myHostname: Host.current().localizedName ?? "unknown", peers: [])
    }

    func isConnected() async -> Bool {
        (await status()).connected
    }

    func myHostname() async -> String? {
        (await status()).myHostname
    }

    func peerFANELEndpoint() async -> String? {
        let s = await status()
        guard let peer = s.peers.first(where: { $0.online }) else { return nil }
        return "http://\(peer.tailscaleIP):\(fanelPort)"
    }

    func isInstalled() -> Bool { installed }

    // MARK: - リフレッシュ

    private func refreshStatus() {
        guard installed, let path = tailscalePath() else {
            cachedStatus = TailscaleStatus(connected: false,
                                            myHostname: Host.current().localizedName ?? "unknown",
                                            peers: [])
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["status", "--json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            cachedStatus = TailscaleStatus(connected: false,
                                            myHostname: Host.current().localizedName ?? "unknown",
                                            peers: [])
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            cachedStatus = TailscaleStatus(connected: false,
                                            myHostname: Host.current().localizedName ?? "unknown",
                                            peers: [])
            return
        }

        let selfNode = json["Self"] as? [String: Any]
        let myHost = (selfNode?["HostName"] as? String) ?? Host.current().localizedName ?? "unknown"
        let online = (selfNode?["Online"] as? Bool) ?? false

        var peers: [TailscalePeer] = []
        if let peerMap = json["Peer"] as? [String: [String: Any]] {
            for (_, peerInfo) in peerMap {
                let host = peerInfo["HostName"] as? String ?? ""
                let peerOnline = peerInfo["Online"] as? Bool ?? false
                let ips = peerInfo["TailscaleIPs"] as? [String] ?? []
                let ip = ips.first ?? ""
                if !host.isEmpty {
                    peers.append(TailscalePeer(hostname: host, online: peerOnline, tailscaleIP: ip))
                }
            }
        }

        cachedStatus = TailscaleStatus(connected: online, myHostname: myHost, peers: peers)
    }
}
