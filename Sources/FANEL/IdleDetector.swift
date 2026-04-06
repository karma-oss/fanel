import Foundation
import os

/// アイドル状態��検知するActor
actor IdleDetector {

    static let shared = IdleDetector()

    private let logger = Logger(subsystem: "com.fanel", category: "IdleDetector")
    private var lastActivity: Date = Date()
    private var monitorTask: Task<Void, Never>?
    private var _isIdle = false
    private var onIdleStart: (() async -> Void)?
    private var onIdleEnd: (() async -> Void)?

    // デバッグ: 環境変数 FANEL_IDLE_SECONDS で秒数変更可（デフォルト300秒=5分）
    private let idleThreshold: TimeInterval = {
        if let envVal = ProcessInfo.processInfo.environment["FANEL_IDLE_SECONDS"],
           let secs = Double(envVal) {
            return secs
        }
        return 300 // 5分
    }()

    private init() {}

    // MARK: - コールバック設定

    func setCallbacks(onStart: @escaping () async -> Void, onEnd: @escaping () async -> Void) {
        self.onIdleStart = onStart
        self.onIdleEnd = onEnd
    }

    // MARK: - アクティビティ記録

    func recordActivity() {
        lastActivity = Date()
        if _isIdle {
            _isIdle = false
            logger.info("アイドル終了 — アクティビティ検知")
            Task { await onIdleEnd?() }
        }
    }

    // MARK: - 状態確認

    func isIdle() -> Bool { _isIdle }

    func idleDuration() -> TimeInterval {
        Date().timeIntervalSince(lastActivity)
    }

    func idleThresholdSeconds() -> TimeInterval { idleThreshold }

    // MARK: - 監視開始・停��

    func startMonitoring() {
        logger.info("アイドル検知開始 (閾値: \(Int(self.idleThreshold))秒)")
        monitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000) // 10秒ごとチェック
                let idle = Date().timeIntervalSince(self.lastActivity)
                if idle >= self.idleThreshold && !self._isIdle {
                    self._isIdle = true
                    self.logger.info("[Idle] アイドル開始 (\(Int(idle))秒非アクティ���)")
                    await LogStore.shared.info("[Idle] アイドル開始")
                    await self.onIdleStart?()
                }
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }
}
