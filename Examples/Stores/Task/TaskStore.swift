//
//  TaskStore.swift
//  CloudDeck Example
//
//  Task 的数据库 Store
//

import CloudDeck
import CloudKit
import GRDB
import Combine

public class TaskStore: SyncableStore, @unchecked Sendable {
    public typealias ModelType = Task

    public let db: GRDBStore
    public let cloud: CloudKitManager
    public let syncConfiguration: SyncConfiguration

    public required init(db: GRDBStore, cloud: CloudKitManager, syncConfiguration: SyncConfiguration) {
        self.db = db
        self.cloud = cloud
        self.syncConfiguration = syncConfiguration
    }

    // MARK: - 注册数据库迁移

    nonisolated public func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(Task.databaseTableName + "_v1") { db in
            try db.create(table: Task.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("createAt", .date).notNull()
                t.column("updateAt", .date).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("isSynced", .boolean).notNull().defaults(to: false)

                t.column("title", .text).notNull()
                t.column("note", .text)
                t.column("isCompleted", .boolean).notNull().defaults(to: false)
                t.column("priority", .text).notNull().defaults(to: "medium")
                t.column("dueDate", .date)
            }
        }
    }
}

// MARK: - 高级查询方法

public extension TaskStore {
    /// 获取完整 Task（填充 tags 关联数据）
    func fetchFullTask(id: String) async throws -> Task? {
        try await db.queue.read { db in
            guard var task = try Task.fetchOne(db, key: id) else { return nil }

            // 通过关联表查询 Tags
            let tagRelations = try TaskTag
                .filter(Column("taskID") == id && Column("isDeleted") == false)
                .fetchAll(db)
            let tagIDs = tagRelations.map { $0.tagID }

            if !tagIDs.isEmpty {
                task.tags = try Tag
                    .filter(tagIDs.contains(Column("id")) && Column("isDeleted") == false)
                    .fetchAll(db)
            }

            return task
        }
    }

    /// 查询未完成的任务
    func fetchIncomplete() async throws -> [Task] {
        try await fetchAll(where: Task.filter(
            Column("isCompleted") == false && Column("isDeleted") == false
        ))
    }

    /// 查询已过期任务
    func fetchOverdue() async throws -> [Task] {
        try await fetchAll(where: Task.filter(
            Column("dueDate") < Date() &&
            Column("isCompleted") == false &&
            Column("isDeleted") == false
        ))
    }

    /// 按优先级查询任务
    func fetchByPriority(_ priority: Priority) async throws -> [Task] {
        try await fetchAll(where: Task.filter(
            Column("priority") == priority.rawValue && Column("isDeleted") == false
        ))
    }

    // MARK: - Combine 数据观察

    /// 监听未完成任务列表的变化
    func incompleteTasksObservation() -> AnyPublisher<[Task], Error> {
        ValueObservation.tracking { db in
            try Task
                .filter(Column("isCompleted") == false && Column("isDeleted") == false)
                .order(Column("priority").desc, Column("dueDate").asc)
                .fetchAll(db)
        }
        .publisher(in: db.queue)
        .eraseToAnyPublisher()
    }
}
