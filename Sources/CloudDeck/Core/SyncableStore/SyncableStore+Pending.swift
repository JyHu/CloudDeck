//
//  SyncableStore+Pending.swift
//  CloudDeck
//
//  Created by hujinyou on 2026/6/10.
//

import GRDB

public extension SyncableStore {
    /// 检查本 Store 是否有未同步到 CloudKit 的数据
    ///
    /// 查询 `isSynced == false` 的记录数量，大于 0 即有待同步数据。
    ///
    /// - Returns: `true` 表示有未同步数据
    func hasPendingChanges() async throws -> Bool {
        try await db.queue.read { db in
            try ModelType
                .filter(Column.Basic.isSynced == false)
                .fetchCount(db) > 0
        }
    }

    /// 获取未同步记录的数量
    ///
    /// - Returns: 未同步记录数
    func pendingChangesCount() async throws -> Int {
        try await db.queue.read { db in
            try ModelType
                .filter(Column.Basic.isSynced == false)
                .fetchCount(db)
        }
    }
}
