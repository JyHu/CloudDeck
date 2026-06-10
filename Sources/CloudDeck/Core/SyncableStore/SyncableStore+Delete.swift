//
//  SyncableStore+Delete.swift
//  CloudDeck
//
//  Created by hujinyou on 2026/6/10.
//

import GRDB
import OSLog
import CloudKit

public extension SyncableStore {
    // Entry contract:
    // - delete(_ ids:): id-based gateway. If sync is disabled, hard delete by ids.
    //   Otherwise load existing models and delegate to deleteAll(_ models:).
    // - deleteAll(_ models:): the only implementation path for sync-aware delete behavior.
    // Keep cloud-ready/background/soft-delete policy in deleteAll(_ models:) to avoid divergence.
    /// Delete a record by ID (Cloud-First, falls back to soft delete).
    func delete(_ id: String) async throws {
        try await deleteAll([id])
    }

    /// Batch delete by IDs.
    func deleteAll(_ ids: [String]) async throws {
        if ids.isEmpty {
            return
        }

        Logger.sync.info("[Store] Batch deleting \(ids.count) \(ModelType.recordType)(s) by id ...")

        let syncEnabled = syncConfiguration.isSyncEnabled
        if !syncEnabled {
            try await permanentlyDelete(ids: ids)
            Logger.sync.info("[Store] Batch permanently deleted \(ids.count) \(ModelType.recordType)(s) locally (sync disabled)")
            return
        }

        // 统一语义：查到就删，查不到就跳过。
        let models = try await db.queue.read { db in
            try ModelType
                .filter(ids.contains(Column.Basic.id))
                .filter(Column.Basic.isDeleted == false)
                .fetchAll(db)
        }
        
        if models.isEmpty {
            Logger.sync.info("[Store] No local \(ModelType.recordType) records found for requested ids; skip delete")
            return
        }

        try await deleteAll(models)
    }

    /// Delete a model instance (Cloud-First, falls back to soft delete).
    func delete(_ model: ModelType) async throws {
        try await deleteAll([model])
    }

    /// Batch delete model instances.
    func deleteAll(_ models: [ModelType]) async throws {
        if models.isEmpty {
            return
        }

        let ids = models.map(\.id)
        Logger.sync.info("[Store] Batch deleting \(ids.count) \(ModelType.recordType)(s) by model ...")

        let syncEnabled = syncConfiguration.isSyncEnabled
        let backgroundSync = syncConfiguration.performSyncInBackground

        if !syncEnabled {
            try await permanentlyDelete(ids: ids)
            Logger.sync.info("[Store] Batch permanently deleted \(ids.count) \(ModelType.recordType)(s) locally (sync disabled)")
            return
        }

        // 云端未就绪时必须软删，等待后续同步，避免云端脏数据。
        if !syncConfiguration.isCloudReady {
            try await softDelete(models)
            Logger.grdb.info("[Store] Soft deleted \(models.count) \(ModelType.recordType)(s) locally (cloud not ready)")
            return
        }

        if backgroundSync {
            let newPendingModels = try await softDeleteAndReturn(models)
            let localSnapshotByID = Dictionary(uniqueKeysWithValues: newPendingModels.map { ($0.id, $0.updateAt) })

            Task { [cloud, db] in
                do {
                    let recordIDs = ids.map { ModelType.recordID(with: $0) }
                    let (_, deleteResults) = try await cloud.modify(saving: [], deleting: recordIDs)

                    try await db.queue.write { db in
                        for id in ids {
                            let recordID = ModelType.recordID(with: id)
                            guard let result = deleteResults[recordID] else {
                                Logger.sync.warning("[Store-BG] No cloud delete result for \(ModelType.recordType) (id: \(id)), keeping soft-deleted record")
                                continue
                            }

                            switch result {
                            case .success:
                                break
                            case .failure(let error):
                                if let ckError = error as? CKError, ckError.code == .unknownItem {
                                    break
                                }
                                continue
                            }

                            guard let localSnapshotUpdateAt = localSnapshotByID[id] else {
                                continue
                            }

                            guard let current = try ModelType
                                .filter(Column.Basic.id == id)
                                .fetchOne(db)
                            else {
                                continue
                            }

                            guard current.isDeleted, current.updateAt <= localSnapshotUpdateAt else {
                                continue
                            }

                            try current.delete(db)
                        }
                    }

                    Logger.sync.info("[Store-BG] Batch deleted \(ids.count) \(ModelType.recordType)(s) from cloud and hard-deleted locally")
                } catch {
                    Logger.cloud.error("[Store-BG] Batch cloud delete failed: \(error)")
                }
            }
        } else {
            do {
                let recordIDs = ids.map { ModelType.recordID(with: $0) }
                let (_, deleteResults) = try await cloud.modify(saving: [], deleting: recordIDs)

                var confirmedIDs: [String] = []
                var unconfirmedModels: [ModelType] = []
                confirmedIDs.reserveCapacity(models.count)
                unconfirmedModels.reserveCapacity(models.count)

                for model in models {
                    let recordID = ModelType.recordID(with: model.id)
                    if cloudDeleteConfirmed(deleteResults[recordID]) {
                        confirmedIDs.append(model.id)
                    } else {
                        unconfirmedModels.append(model)
                    }
                }

                if !confirmedIDs.isEmpty {
                    try await permanentlyDelete(ids: confirmedIDs)
                }
                if !unconfirmedModels.isEmpty {
                    try await softDelete(unconfirmedModels)
                }

                Logger.sync.info("[Store] Cloud-confirmed delete: \(confirmedIDs.count), soft-deleted pending: \(unconfirmedModels.count) for \(ModelType.recordType)")
            } catch {
                Logger.cloud.error("[Store] Batch cloud delete failed for \(ids.count) \(ModelType.recordType)(s): \(error), falling back to soft delete")
                try await softDelete(models)
                Logger.grdb.info("[Store] Soft deleted \(models.count) \(ModelType.recordType)(s) in local DB")
            }
        }
    }
    
    /// Batch delete records matching a query condition.
    func deleteAll(where build: (QueryInterfaceRequest<ModelType>) throws -> QueryInterfaceRequest<ModelType>) async throws {
        try await deleteAll(try fetchAll(where: build(ModelType.all())))
    }

    /// Permanently remove a record from local database.
    @discardableResult
    func permanentlyDelete(id: String) async throws -> Bool {
        try await db.queue.write { db in
            try ModelType.deleteOne(db, key: id)
        }
    }

    @discardableResult
    func permanentlyDelete(ids: [String]) async throws -> Int {
        try await db.queue.write { db in
            try ModelType.deleteAll(db, keys: ids)
        }
    }

    private func softDelete(_ models: [ModelType]) async throws {
        _ = try await softDeleteAndReturn(models)
    }

    private func softDeleteAndReturn(_ models: [ModelType]) async throws -> [ModelType] {
        if models.isEmpty {
            return []
        }

        var mutableModels = models
        for i in 0..<mutableModels.count {
            mutableModels[i].markDeleted()
        }

        let newModels = mutableModels
        try await db.queue.write {
            for model in newModels {
                try model.save($0)
            }
        }

        return newModels
    }

    private func cloudDeleteConfirmed(_ result: Result<Void, Error>?) -> Bool {
        guard let result else {
            return false
        }

        switch result {
        case .success:
            return true
        case .failure(let error):
            if let ckError = error as? CKError {
                return ckError.code == .unknownItem
            }
            return false
        }
    }
}
