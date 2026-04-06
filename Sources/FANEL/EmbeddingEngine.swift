import Foundation
import os

/// テキストをベクトル化するエンジン（TF-IDFベースのローカル実装）
actor EmbeddingEngine {

    static let shared = EmbeddingEngine()

    private let logger = Logger(subsystem: "com.fanel", category: "EmbeddingEngine")
    private let dimensions = 128
    // 日本語の一般的キーワード + プログラミング用語でボキャブラリ構築
    private var vocabulary: [String: Int] = [:]
    private var nextVocabIndex = 0

    private init() {}

    // MARK: - テキストをベクトル化

    func embed(text: String) async -> [Float] {
        let tokens = tokenize(text)
        var vector = [Float](repeating: 0, count: dimensions)

        for token in tokens {
            let idx = vocabIndex(for: token)
            let bucket = idx % dimensions
            vector[bucket] += 1.0
        }

        // L2正規化
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            for i in 0..<vector.count {
                vector[i] /= norm
            }
        }

        return vector
    }

    // MARK: - コサイン類似度

    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - トークナイズ

    private func tokenize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var tokens: [String] = []

        // 英数字の単語
        let asciiPattern = lowered.components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
        tokens.append(contentsOf: asciiPattern)

        // 日本語: 2-gram
        let japanese = lowered.unicodeScalars.filter { $0.value > 0x3000 }
        let japaneseStr = String(String.UnicodeScalarView(japanese))
        let chars = Array(japaneseStr)
        for i in 0..<max(0, chars.count - 1) {
            tokens.append(String(chars[i..<min(i+2, chars.count)]))
        }
        // 1-gram too
        for ch in chars {
            tokens.append(String(ch))
        }

        return tokens
    }

    private func vocabIndex(for token: String) -> Int {
        if let idx = vocabulary[token] {
            return idx
        }
        let idx = nextVocabIndex
        vocabulary[token] = idx
        nextVocabIndex += 1
        return idx
    }
}
