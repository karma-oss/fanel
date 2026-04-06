import Foundation
import Vapor

/// プラグインプロトコル: 1機能1プラグインの疎結合アーキテクチャ
protocol FANELPlugin: Sendable {
    /// プラグイン名
    var name: String { get }

    /// ルート登録
    func register(routes app: Application) throws

    /// 起動時処理
    func onStartup() async

    /// 停止時処理
    func onShutdown() async

    /// アイドル開始
    func onIdle() async

    /// アクティビティ再開
    func onActivity() async
}

/// デフォルト実装（各プラグインで不要なメソッドは省略可能）
extension FANELPlugin {
    func onStartup() async {}
    func onShutdown() async {}
    func onIdle() async {}
    func onActivity() async {}
}
