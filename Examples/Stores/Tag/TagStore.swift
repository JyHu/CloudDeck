//
//  TagStore.swift
//  CloudDeck Example
//
//  Tag 的数据库 Store
//

import CloudDeck
import CloudKit
import GRDB

public class TagStore: SyncableStore, @unchecked Sendable {
    public typealias ModelType = Tag

    public let db: GRDBStore
    public let cloud: CloudKitManager
    public let syncConfiguration: SyncConfiguration

    public required init(db: GRDBStore, cloud: CloudKitManager, syncConfiguration: SyncConfiguration) {
        self.db = db
        self.cloud = cloud
        self.syncConfiguration = syncConfiguration
    }

    nonisolated public func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(Tag.databaseTableName + "_v1") { db in
            try db.create(table: Tag.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("createAt", .date).notNull()
                t.column("updateAt", .date).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("isSynced", .boolean).notNull().defaults(to: false)
                t.column("name", .text).notNull()
                t.column("color", .text)
            }
        }
    }
}

// MARK: - 自定义查询

public extension TagStore {
    /// 查询所有有效标签
    func fetchActiveTags() async throws -> [Tag] {
        try await fetchAll(where: Tag.filter(Column("isDeleted") == false).order(Column("name")))
    }
}
