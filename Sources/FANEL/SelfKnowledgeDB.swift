import Foundation
import os

/// SourceUnit: 1ファイルのインデックス情報
struct SourceUnit: Codable, Sendable {
    let path: String
    let name: String
    let kind: String          // "actor", "struct", "class", "enum", "protocol", "html", "config"
    let summary: String       // 1行の概要
    let dependencies: [String] // import先 or 参照先ファイル名
    let exports: [String]     // 公開メソッド / 型名
    let lineCount: Int
    let lastModified: Date
    var embedding: [Float]?
}

/// ReviewIssue: レビューで検出された問題
struct ReviewIssue: Codable, Sendable {
    let id: UUID
    let role: String          // "architect", "security", etc.
    let severity: String      // "critical", "warning", "info"
    let file: String
    let line: Int?
    let message: String
    let suggestion: String
    let timestamp: Date
}

/// SelfIndex: 永続化する全体構造
struct SelfIndex: Codable, Sendable {
    var units: [SourceUnit]
    var issues: [ReviewIssue]
    var lastIndexedAt: Date?
    var lastReviewedAt: Date?

    enum CodingKeys: String, CodingKey {
        case units, issues
        case lastIndexedAt = "last_indexed_at"
        case lastReviewedAt = "last_reviewed_at"
    }
}

/// ~/.fanel/self/index.json に永続化するDB
actor SelfKnowledgeDB {

    static let shared = SelfKnowledgeDB()

    private let logger = Logger(subsystem: "com.fanel", category: "SelfKnowledgeDB")
    private var index: SelfIndex
    private let filePath: String

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.fanel/self"
        self.filePath = "\(dir)/index.json"

        // ディレクトリ作成
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        // 読み込み
        if let data = FileManager.default.contents(atPath: filePath),
           let loaded = try? JSONDecoder.fanel.decode(SelfIndex.self, from: data) {
            self.index = loaded
        } else {
            self.index = SelfIndex(units: [], issues: [], lastIndexedAt: nil, lastReviewedAt: nil)
        }
    }

    // MARK: - Units

    func allUnits() -> [SourceUnit] { index.units }

    func replaceUnits(_ units: [SourceUnit]) async {
        index.units = units
        index.lastIndexedAt = Date()
        await save()
    }

    func unit(forPath path: String) -> SourceUnit? {
        index.units.first { $0.path == path }
    }

    // MARK: - Issues

    func allIssues() -> [ReviewIssue] { index.issues }

    func replaceIssues(_ issues: [ReviewIssue]) async {
        index.issues = issues
        index.lastReviewedAt = Date()
        await save()
    }

    func addIssues(_ newIssues: [ReviewIssue]) async {
        index.issues.append(contentsOf: newIssues)
        index.lastReviewedAt = Date()
        await save()
    }

    func clearIssues() async {
        index.issues = []
        await save()
    }

    func issuesByRole(_ role: String) -> [ReviewIssue] {
        index.issues.filter { $0.role == role }
    }

    // MARK: - Metadata

    func lastIndexedAt() -> Date? { index.lastIndexedAt }
    func lastReviewedAt() -> Date? { index.lastReviewedAt }

    // MARK: - Summary

    func summary() -> [String: Any] {
        let roleGroups = Dictionary(grouping: index.issues, by: { $0.role })
        var roleSummary: [[String: Any]] = []
        for (role, issues) in roleGroups.sorted(by: { $0.key < $1.key }) {
            let criticals = issues.filter { $0.severity == "critical" }.count
            let warnings = issues.filter { $0.severity == "warning" }.count
            let infos = issues.filter { $0.severity == "info" }.count
            roleSummary.append([
                "role": role,
                "critical": criticals,
                "warning": warnings,
                "info": infos,
                "total": issues.count,
            ])
        }

        return [
            "file_count": index.units.count,
            "total_lines": index.units.reduce(0) { $0 + $1.lineCount },
            "issue_count": index.issues.count,
            "roles": roleSummary,
            "last_indexed_at": index.lastIndexedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "last_reviewed_at": index.lastReviewedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
        ]
    }

    // MARK: - Persistence

    private func save() async {
        do {
            let data = try JSONEncoder.fanel.encode(index)
            try data.write(to: URL(fileURLWithPath: filePath))
        } catch {
            logger.error("SelfKnowledgeDB save failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - JSONEncoder/Decoder extension

private extension JSONEncoder {
    static let fanel: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let fanel: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
