//
//  SyncCoordinator+CRUD.swift
//  CloudDeck
//

import OSLog
/// SyncCoordinator 的 CRUD 扩展
///
/// 该扩展仅负责路由：按 `recordType` 分组后转发到对应 `SyncableStore`。
/// 实际的 CloudKit/本地数据库写入逻辑由 Store 实现，避免双实现漂移。

extension SyncCoordinator {
    /// 保存单条记录的便捷方法，内部委托给批量保存
    public func save(_ model: any SyncableProtocol) async throws {
        try await save([model])
    }

    public func save(_ models: [any SyncableProtocol]) async throws {
        guard !models.isEmpty else {
            Logger.sync.debug("[CRUD] save called with empty models, skipping.")
            return
        }

        let groups = Dictionary(grouping: models, by: { type(of: $0).recordType })
        for (recordType, groupedModels) in groups {
            guard let store = store(for: recordType) else {
                throw SyncError.configurationError(reason: "No store registered for recordType: \(recordType)")
            }

            try await AnySyncableStore(store).saveAll(groupedModels)
        }
    }

    /// 删除单条记录的便捷方法，内部委托给批量删除
    public func delete(_ model: any SyncableProtocol) async throws {
        try await delete([model])
    }

    public func delete(_ models: [any SyncableProtocol]) async throws {
        guard !models.isEmpty else {
            Logger.sync.debug("[CRUD] delete called with empty models, skipping.")
            return
        }

        let groups = Dictionary(grouping: models, by: { type(of: $0).recordType })
        for (recordType, groupedModels) in groups {
            guard let store = store(for: recordType) else {
                throw SyncError.configurationError(reason: "No store registered for recordType: \(recordType)")
            }

            try await AnySyncableStore(store).deleteAll(groupedModels)
        }
    }
}
