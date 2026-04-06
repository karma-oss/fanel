import Foundation
import os

/// FANELソースコードを自己インデックスするActor
actor SelfIndexer {

    static let shared = SelfIndexer()

    private let logger = Logger(subsystem: "com.fanel", category: "SelfIndexer")

    private init() {}

    // MARK: - ソースインデックス構築

    /// Sources/FANEL/ 配下の全ファイルをスキャンしてインデックスを更新
    func indexSources() async -> String {
        let projectRoot = findProjectRoot()
        guard let root = projectRoot else {
            return "プロジェクトルートが見つかりません"
        }

        let sourcesDir = "\(root)/Sources/FANEL"
        let fm = FileManager.default

        guard fm.fileExists(atPath: sourcesDir) else {
            return "Sources/FANEL ディレクトリが存在しません"
        }

        var units: [SourceUnit] = []

        // Swift files
        if let enumerator = fm.enumerator(atPath: sourcesDir) {
            while let file = enumerator.nextObject() as? String {
                if Task.isCancelled { return "中断" }

                let fullPath = "\(sourcesDir)/\(file)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }

                let ext = (file as NSString).pathExtension.lowercased()
                guard ["swift", "html", "json"].contains(ext) else { continue }

                if let unit = parseFile(path: fullPath, relativePath: file) {
                    units.append(unit)
                }
            }
        }

        // Package.swift
        let packageSwift = "\(root)/Package.swift"
        if fm.fileExists(atPath: packageSwift),
           let unit = parseFile(path: packageSwift, relativePath: "Package.swift") {
            units.append(unit)
        }

        // CLAUDE.md
        let claudeMd = "\(root)/CLAUDE.md"
        if fm.fileExists(atPath: claudeMd),
           let unit = parseFile(path: claudeMd, relativePath: "CLAUDE.md") {
            units.append(unit)
        }

        // Embeddings生成
        for i in 0..<units.count {
            if Task.isCancelled { return "中断" }
            let text = "\(units[i].name) \(units[i].kind) \(units[i].summary) \(units[i].exports.joined(separator: " "))"
            units[i].embedding = await EmbeddingEngine.shared.embed(text: text)
        }

        await SelfKnowledgeDB.shared.replaceUnits(units)
        await LogStore.shared.info("[SelfIndex] インデックス完了: \(units.count)ファイル")
        return "インデックス完了: \(units.count)ファイル"
    }

    // MARK: - 自己説明

    /// FANELの構造を自然言語で説明する
    func explainSelf() async -> [String: Any] {
        let units = await SelfKnowledgeDB.shared.allUnits()

        let actors = units.filter { $0.kind == "actor" }
        let structs = units.filter { $0.kind == "struct" }
        let totalLines = units.reduce(0) { $0 + $1.lineCount }

        var explanation: [String: Any] = [
            "name": "FANEL",
            "description": "AI駆動型タスクオーケストレーションシステム",
            "file_count": units.count,
            "total_lines": totalLines,
            "actors": actors.map { ["name": $0.name, "summary": $0.summary] },
            "structs": structs.map { ["name": $0.name, "summary": $0.summary] },
        ]

        // コア依存グラフの概要
        let coreActors = actors.filter { ["TaskOrchestrator", "CouncilManager", "WorkerPool", "HayabusaClient"].contains($0.name) }
        explanation["core_flow"] = coreActors.map { "\($0.name): \($0.summary)" }

        return explanation
    }

    // MARK: - 依存グラフ

    /// ファイル間の依存関係グラフを返す
    func dependencyGraph() async -> [[String: Any]] {
        let units = await SelfKnowledgeDB.shared.allUnits()
        return units.map { unit in
            [
                "file": unit.path,
                "name": unit.name,
                "depends_on": unit.dependencies,
                "exports": unit.exports,
            ] as [String: Any]
        }
    }

    // MARK: - 影響ファイル検索

    /// 指定ファイルを変更したとき影響を受けるファイルを返す
    func findImpactedFiles(targetFile: String) async -> [String] {
        let units = await SelfKnowledgeDB.shared.allUnits()
        let targetName = (targetFile as NSString).deletingPathExtension
            .components(separatedBy: "/").last ?? targetFile

        // targetNameをdependenciesに持つファイルを探す
        var impacted: [String] = []
        for unit in units {
            if unit.dependencies.contains(where: { $0.contains(targetName) }) {
                impacted.append(unit.path)
            }
        }
        return impacted
    }

    // MARK: - File Parsing

    private func parseFile(path: String, relativePath: String) -> SourceUnit? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: .newlines)
        let lineCount = lines.count
        let name = (relativePath as NSString).deletingPathExtension
            .components(separatedBy: "/").last ?? relativePath
        let ext = (relativePath as NSString).pathExtension.lowercased()

        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? Date()

        switch ext {
        case "swift":
            return parseSwiftFile(content: content, lines: lines, name: name,
                                  relativePath: relativePath, lineCount: lineCount, modified: modified)
        case "html":
            return SourceUnit(
                path: relativePath, name: name, kind: "html",
                summary: "HTML/CSS/JSフロントエンド",
                dependencies: [], exports: [],
                lineCount: lineCount, lastModified: modified, embedding: nil
            )
        case "json":
            return SourceUnit(
                path: relativePath, name: name, kind: "config",
                summary: "設定ファイル",
                dependencies: [], exports: [],
                lineCount: lineCount, lastModified: modified, embedding: nil
            )
        case "md":
            return SourceUnit(
                path: relativePath, name: name, kind: "config",
                summary: "ドキュメント/設定",
                dependencies: [], exports: [],
                lineCount: lineCount, lastModified: modified, embedding: nil
            )
        default:
            return nil
        }
    }

    private func parseSwiftFile(content: String, lines: [String], name: String,
                                 relativePath: String, lineCount: Int, modified: Date) -> SourceUnit {
        var kind = "struct"
        var summary = ""
        var dependencies: [String] = []
        var exports: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // kind detection
            if trimmed.hasPrefix("actor ") { kind = "actor" }
            else if trimmed.hasPrefix("class ") && !trimmed.contains("//") { kind = "class" }
            else if trimmed.hasPrefix("enum ") && !trimmed.contains("//") { kind = "enum" }
            else if trimmed.hasPrefix("protocol ") { kind = "protocol" }

            // summary from doc comment
            if trimmed.hasPrefix("///") && summary.isEmpty {
                summary = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }

            // dependencies: references to other FANEL types
            if trimmed.contains(".shared") {
                // Extract TypeName from TypeName.shared
                let parts = trimmed.components(separatedBy: ".")
                for (i, part) in parts.enumerated() {
                    if i + 1 < parts.count && parts[i + 1].hasPrefix("shared") {
                        let typeName = part.components(separatedBy: .alphanumerics.inverted).last ?? ""
                        if !typeName.isEmpty && typeName != name {
                            dependencies.append(typeName)
                        }
                    }
                }
            }

            // exports: public/internal func
            if (trimmed.hasPrefix("func ") || trimmed.contains(" func "))
                && !trimmed.hasPrefix("private")
                && !trimmed.hasPrefix("//") {
                if let funcName = extractFuncName(trimmed) {
                    exports.append(funcName)
                }
            }
        }

        // dedupe
        dependencies = Array(Set(dependencies))

        if summary.isEmpty {
            summary = "\(kind.capitalized) \(name)"
        }

        return SourceUnit(
            path: relativePath, name: name, kind: kind,
            summary: summary, dependencies: dependencies, exports: exports,
            lineCount: lineCount, lastModified: modified, embedding: nil
        )
    }

    private func extractFuncName(_ line: String) -> String? {
        guard let funcRange = line.range(of: "func ") else { return nil }
        let afterFunc = String(line[funcRange.upperBound...])
        let name = afterFunc.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
        return name.isEmpty ? nil : String(name)
    }

    // MARK: - Project Root

    private func findProjectRoot() -> String? {
        // Package.swift を探してプロジェクトルートを特定
        var dir = FileManager.default.currentDirectoryPath
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: "\(dir)/Package.swift") {
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }

        // フォールバック: 既知のパス
        let knownPaths = [
            FileManager.default.homeDirectoryForCurrentUser.path + "/Desktop/fanel",
        ]
        for p in knownPaths {
            if FileManager.default.fileExists(atPath: "\(p)/Package.swift") {
                return p
            }
        }
        return nil
    }

    private func attributesOfItem(atPath path: String) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: path)
    }
}
