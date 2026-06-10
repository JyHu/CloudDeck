//
//  TaskTagStore.swift
//  CloudDeck Example
//
//  TaskTag 关联表的 Store
//

import CloudDeck
import CloudKit
import GRDB

public class TaskTagStore: SyncableStore, @unchecked Sendable {
    public typealias ModelType = TaskTag

    public let db: GRDBStore
    public let cloud: CloudKitManager
    public let syncConfiguration: SyncConfiguration

    public required init(db: GRDBStore, cloud: CloudKitManager, syncConfiguration: SyncConfiguration) {
        self.db = db
        self.cloud = cloud
        self.syncConfiguration = syncConfiguration
    }

    nonisolated public func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(TaskTag.databaseTableName + "_v1") { db in
            try db.create(table: TaskTag.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("createAt", .date).notNull()
                t.column("updateAt", .date).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("isSynced", .boolean).notNull().defaults(to: false)
                t.column("taskID", .text).notNull()
                t.column("tagID", .text).notNull()
            }

            // 为外键建立索引，加速关联查询
            try db.create(index: "idx_taskTag_taskID", on: TaskTag.databaseTableName, columns: ["taskID"])
            try db.create(index: "idx_taskTag_tagID", on: TaskTag.databaseTableName, columns: ["tagID"])
        }
    }
}

// MARK: - 关联查询方法

public extension TaskTagStore {
    /// 查询某个 Task 的所有 Tag ID
    func fetchTagIDs(forTaskID taskID: String) async throws -> [String] {
        try await db.queue.read { db in
            try TaskTag
                .filter(Column("taskID") == taskID && Column("isDeleted") == false)
                .fetchAll(db)
                .map { $0.tagID }
        }
    }

    /// 查询某个 Tag 下的所有 Task ID
    func fetchTaskIDs(forTagID tagID: String) async throws -> [String] {
        try await db.queue.read { db in
            try TaskTag
                .filter(Column("tagID") == tagID && Column("isDeleted") == false)
                .fetchAll(db)
                .map { $0.taskID }
        }
    }

    /// 为 Task 添加 Tag
    func addTag(_ tagID: String, toTask taskID: String) async throws {
        var relation = TaskTag(taskID: taskID, tagID: tagID)
        relation.isSynced = false
        try await save(relation)
    }

    /// 从 Task 移除 Tag
    func removeTag(_ tagID: String, fromTask taskID: String) async throws {
        let id = "\(taskID)_\(tagID)"
        try await delete(id)
    }
}
