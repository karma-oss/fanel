import Foundation
import os

enum ProjectStatus: String, Codable, Sendable {
    case active
    case idle
    case archived
}

struct ProjectProfile: Codable, Sendable {
    let id: UUID
    let name: String
    let path: String
    let status: ProjectStatus
    let lastOpenedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, path, status
        case lastOpenedAt = "last_opened_at"
    }
}

/// プロジェクトを動的に管理するActor
actor ProjectStore {

    static let shared = ProjectStore()

    private let logger = Logger(subsystem: "com.fanel", category: "ProjectStore")
    private var projects: [UUID: ProjectProfile] = [:]
    private var order: [UUID] = []
    private let filePath: String

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.filePath = "\(home)/.fanel/projects.json"
    }

    // MARK: - 初期化

    func load() {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            // 初回: FANELプロジェクト自身を登録
            let fanel = ProjectProfile(
                id: UUID(),
                name: "FANEL",
                path: FileManager.default.currentDirectoryPath,
                status: .active,
                lastOpenedAt: Date()
            )
            projects[fanel.id] = fanel
            order.append(fanel.id)
            persist()
            logger.info("初期プロジェクト登録: FANEL")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([ProjectProfile].self, from: data) {
            for p in loaded {
                projects[p.id] = p
                order.append(p.id)
            }
            logger.info("プロジェクト読み込み: \(loaded.count)件")
        }
    }

    // MARK: - 追加

    func add(name: String, path: String) -> ProjectProfile {
        let project = ProjectProfile(
            id: UUID(),
            name: name,
            path: path,
            status: .idle,
            lastOpenedAt: Date()
        )
        projects[project.id] = project
        order.append(project.id)
        persist()
        logger.info("プロジェクト追加: \(name) → \(path)")
        return project
    }

    // MARK: - 削除

    func remove(id: UUID) {
        projects.removeValue(forKey: id)
        order.removeAll { $0 == id }
        persist()
    }

    // MARK: - アクティブ切替

    func activate(id: UUID) {
        // 全プロジェクトをidleに
        for pid in projects.keys {
            guard let p = projects[pid] else { continue }
            projects[pid] = ProjectProfile(
                id: p.id, name: p.name, path: p.path,
                status: .idle, lastOpenedAt: p.lastOpenedAt
            )
        }
        // 指定プロジェクトをactiveに
        guard let p = projects[id] else { return }
        projects[id] = ProjectProfile(
            id: p.id, name: p.name, path: p.path,
            status: .active, lastOpenedAt: Date()
        )
        persist()
        logger.info("プロジェクト切替: \(p.name)")
    }

    // MARK: - 更新

    func update(id: UUID, name: String?, path: String?) {
        guard let p = projects[id] else { return }
        projects[id] = ProjectProfile(
            id: p.id,
            name: name ?? p.name,
            path: path ?? p.path,
            status: p.status,
            lastOpenedAt: p.lastOpenedAt
        )
        persist()
        logger.info("プロジェクト更新: \(self.projects[id]!.name)")
    }

    // MARK: - 取得

    func list() -> [ProjectProfile] {
        order.compactMap { projects[$0] }
    }

    func activeProject() -> ProjectProfile? {
        projects.values.first { $0.status == .active }
    }

    func get(id: UUID) -> ProjectProfile? {
        projects[id]
    }

    // MARK: - 永続化

    private func persist() {
        let all = order.compactMap { projects[$0] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        let dir = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: filePath))
    }
}
