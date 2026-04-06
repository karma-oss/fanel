import Foundation
import os

/// Claude Codeの出力からJSONを抽出するパーサー
/// 4パターン対応: 完全JSON / JSON断片 / プレーンテキスト / stderr混入
struct LooseJSONParser {

    private static let logger = Logger(subsystem: "com.fanel", category: "LooseJSONParser")

    private static let beginMarker = "[FANEL_RESPONSE_BEGIN]"
    private static let endMarker = "[FANEL_RESPONSE_END]"

    /// メイン解析メソッド: マーカー優先 → ブレーススキャン → nil
    static func parse(_ rawOutput: String) -> ClaudeResponse? {
        logger.debug("Parsing output (\(rawOutput.count) chars)")

        // 1. マーカーで囲まれた部分を優先抽出
        if let markerJSON = extractByMarker(rawOutput) {
            logger.info("Extracted JSON via markers")
            return decode(markerJSON)
        }

        // 2. ブレーススキャンでJSON部分を探す
        if let braceJSON = extractByBraceScan(rawOutput) {
            logger.info("Extracted JSON via brace scan")
            return decode(braceJSON)
        }

        // 3. どちらも失敗
        logger.warning("No JSON found in output")
        return nil
    }

    // MARK: - マーカー抽出

    private static func extractByMarker(_ text: String) -> String? {
        guard let beginRange = text.range(of: beginMarker),
              let endRange = text.range(of: endMarker, range: beginRange.upperBound..<text.endIndex)
        else {
            return nil
        }

        let extracted = String(text[beginRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !extracted.isEmpty else { return nil }
        return extracted
    }

    // MARK: - ブレーススキャン

    private static func extractByBraceScan(_ text: String) -> String? {
        // 行ごとにstderrプレフィックス等を除去してから結合
        let cleaned = text
            .components(separatedBy: .newlines)
            .map { line -> String in
                // stderr混入パターン: 行頭の "error:" や "warning:" 等を除外
                if line.hasPrefix("error:") || line.hasPrefix("warning:") ||
                   line.hasPrefix("stderr:") || line.hasPrefix("debug:") {
                    return ""
                }
                return line
            }
            .joined(separator: "\n")

        var depth = 0
        var startIndex: String.Index?
        var inString = false
        var escaped = false

        for (offset, char) in cleaned.enumerated() {
            let idx = cleaned.index(cleaned.startIndex, offsetBy: offset)

            if escaped {
                escaped = false
                continue
            }

            if char == "\\" && inString {
                escaped = true
                continue
            }

            if char == "\"" {
                inString.toggle()
                continue
            }

            if inString { continue }

            if char == "{" {
                if depth == 0 {
                    startIndex = idx
                }
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0, let start = startIndex {
                    let endIdx = cleaned.index(after: idx)
                    let candidate = String(cleaned[start..<endIdx])
                    // 最も外側の完全なJSONオブジェクトを返す
                    if isValidJSON(candidate) {
                        return candidate
                    }
                    // リセットして次を探す
                    startIndex = nil
                }
                if depth < 0 {
                    depth = 0
                    startIndex = nil
                }
            }
        }

        return nil
    }

    // MARK: - デコード

    /// 文字列からブレーススキャンで最初の完全なJSONオブジェクトを抽出
    static func extractFirstJSON(_ text: String) -> String? {
        var depth = 0
        var start: String.Index?
        var inStr = false
        var esc = false
        for (offset, ch) in text.enumerated() {
            let idx = text.index(text.startIndex, offsetBy: offset)
            if esc { esc = false; continue }
            if ch == "\\" && inStr { esc = true; continue }
            if ch == "\"" { inStr.toggle(); continue }
            if inStr { continue }
            if ch == "{" { if depth == 0 { start = idx }; depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0, let s = start {
                    let candidate = String(text[s...idx])
                    if isValidJSON(candidate) { return candidate }
                    start = nil
                }
                if depth < 0 { depth = 0; start = nil }
            }
        }
        return nil
    }

    private static func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func decode(_ jsonString: String) -> ClaudeResponse? {
        guard let data = jsonString.data(using: .utf8) else { return nil }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(ClaudeResponse.self, from: data)
        } catch {
            logger.error("JSON decode error: \(error.localizedDescription)")

            // フォールバック: 部分的にでも解析を試みる
            return decodeLoose(data)
        }
    }

    /// 必須フィールドが欠けている場合のフォールバックデコード
    private static func decodeLoose(_ data: Data) -> ClaudeResponse? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let statusStr = dict["status"] as? String ?? "complete"
        let status = TaskStatus(rawValue: statusStr) ?? .complete
        let message = dict["message"] as? String ?? ""
        let files = dict["files_modified"] as? [String] ?? []
        let next = dict["next_action"] as? String
        let approval = dict["requires_approval"] as? Bool ?? false

        return ClaudeResponse(
            status: status,
            message: message,
            filesModified: files,
            nextAction: next,
            requiresApproval: approval
        )
    }
}
