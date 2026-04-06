import Foundation
import os

/// Hayabusa推論エンジンとの通信クライアント
actor HayabusaClient {

    static let shared = HayabusaClient()

    private let logger = Logger(subsystem: "com.fanel", category: "HayabusaClient")
    let baseURL = "http://localhost:8080"
    private let timeoutSeconds: Double = 60

    private init() {}

    // MARK: - ヘルスチェック

    func isAvailable() async -> Bool {
        // Hayabusaは/v1/modelsが未実装の場合があるため、
        // 軽量なcompletionsリクエストでヘルスチェック
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "auto",
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1
        ])
        req.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200
        } catch {
            return false
        }
    }

    // MARK: - 利用可能モデル一覧

    func availableModels() async throws -> [String] {
        // /v1/models を試す
        if let url = URL(string: "\(baseURL)/v1/models") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            if let (data, response) = try? await URLSession.shared.data(for: req),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["data"] as? [[String: Any]] {
                return models.compactMap { $0["id"] as? String }
            }
        }

        // /v1/models が未対応の場合、completionsで取得したmodel名を返す
        guard await isAvailable() else { throw FANELError.hayabusaUnavailable }

        // テストリクエストからmodel名を取得
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "auto",
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1
        ])
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let modelName = json["model"] as? String {
            return [modelName]
        }
        return []
    }

    // MARK: - 推論実行

    func complete(model: String, prompt: String) async throws -> String {
        guard await isAvailable() else {
            throw FANELError.hayabusaUnavailable
        }

        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw FANELError.hayabusaUnavailable
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "あなたはFANELシステムの配下で動作するAIアシスタントです。必ずマーカー形式でレスポンスしてください。\n\n[FANEL_RESPONSE_BEGIN]\n{\"status\": \"complete\", \"message\": \"結果\", \"files_modified\": [], \"next_action\": null, \"requires_approval\": false}\n[FANEL_RESPONSE_END]"],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 2048,
            "temperature": 0.3
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = timeoutSeconds

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.error("Hayabusa returned status \(statusCode)")
            throw FANELError.hayabusaUnavailable
        }

        // OpenAI互換: { "choices": [{ "message": { "content": "..." } }] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw FANELError.jsonParseFailed(rawOutput: String(data: data, encoding: .utf8) ?? "")
        }

        return content
    }

    // MARK: - 簡易ベンチマーク

    func benchmark(model: String) async throws -> (tokensPerSec: Double, qualityScore: Double) {
        guard await isAvailable() else {
            throw FANELError.hayabusaUnavailable
        }

        let startTime = Date()

        // FizzBuzz生成テスト
        let prompt = "Write a FizzBuzz function in Swift. Return only the code, no explanation."
        let result = try await complete(model: model, prompt: prompt)

        let elapsed = Date().timeIntervalSince(startTime)
        let estimatedTokens = Double(result.count) / 4.0
        let tokensPerSec = estimatedTokens / max(elapsed, 0.1)

        // 品質スコア: FizzBuzzのキーワードチェック
        var score = 0.0
        let lower = result.lowercased()
        if lower.contains("fizzbuzz") || lower.contains("fizz") { score += 0.3 }
        if lower.contains("buzz") { score += 0.2 }
        if lower.contains("func") || lower.contains("function") { score += 0.2 }
        if lower.contains("return") || lower.contains("print") { score += 0.15 }
        if lower.contains("%") || lower.contains("mod") { score += 0.15 }

        return (tokensPerSec: tokensPerSec, qualityScore: min(1.0, score))
    }
}
