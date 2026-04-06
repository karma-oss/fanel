import Foundation

/// CommandRoom.htmlの内容をSwift文字列として保持
/// SPMリソースバンドルの問題を回避しつつ、Resources/CommandRoom.htmlと同期を保つこと
enum CommandRoomHTML {
    static var content: String {
        // Bundle.moduleからの読み込みを試みる
        if let url = Bundle.module.url(
            forResource: "CommandRoom",
            withExtension: "html",
            subdirectory: "Resources"
        ),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            return html
        }

        // フォールバック: 最小限のHTML
        return """
        <!DOCTYPE html>
        <html lang="ja">
        <head><meta charset="UTF-8"><title>FANEL 指令室</title>
        <style>body{background:#0d1117;color:#e6edf3;font-family:system-ui;padding:40px;text-align:center}</style>
        </head>
        <body>
        <h1>FANEL 指令室</h1>
        <p>CommandRoom.html の読み込みに失敗しました。</p>
        <p><a href="/api/status" style="color:#58a6ff">/api/status</a></p>
        </body>
        </html>
        """
    }
}
