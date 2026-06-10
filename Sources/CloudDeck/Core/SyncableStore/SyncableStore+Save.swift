//
//  SyncableStore+Save.swift
//  CloudDeck
//
//  Created by hujinyou on 2026/6/10.
//

import GRDB
import OSLog

public extension SyncableStore {
    // Entry contract:
    // - save(_:): thin wrapper for single item convenience.
    // - saveAll(_:): the only implementation path for save behavior.
    // Keep all save policy/state logic in saveAll(_:) to avoid divergence.
    /// Save a single record (Cloud-First strategy).
    ///
    /// Respects `syncConfiguration`:
    /// - `isSyncEnabled == false`: Only writes locally, marks `isSynced = false`
    /// - `isCloudReady == false`: Only writes locally until zones are set up
    /// - `performSyncInBackground == true`: Writes locally first, syncs in background
    func save(_ model: ModelType) async throws {
        try await saveAll([model])
    }

    /// Batch save records (Cloud-First strategy).
    func saveAll(_ models: [ModelType]) async throws {
        var mutableModels = models

        Logger.sync.info("[Store] Batch saving \(models.count) \(ModelType.recordType)(s) ...")

        let syncEnabled = syncConfiguration.isSyncEnabled
        let backgroundSync = syncConfiguration.performSyncInBackground

        // 同步关闭或云端未就绪
        if !syncEnabled || !syncConfiguration.isCloudReady {
            for i in 0..<mutableModels.count {
                mutableModels[i].markModified()
            }
            let newModels = mutableModels
            try await db.queue.write { db in
                for model in newModels {
                    try model.save(db)
                }
            }
            Logger.grdb.info("[Store] Batch saved \(newModels.count) \(ModelType.recordType)(s) locally (sync disabled)")
            return
        }

        // 后台同步
        if backgroundSync {
            for i in 0..<mutableModels.count {
                mutableModels[i].markModified()
            }
            let newModels = mutableModels
            let localSnapshotByID = Dictionary(uniqueKeysWithValues: newModels.map { ($0.id, $0.updateAt) })
            try await db.queue.write { db in
                for model in newModels {
                    try model.save(db)
                }
            }

            Task { [cloud, db] in
                do {
                    let records = newModels.map { $0.toCKRecord(in: ModelType.zoneID) }
                    let (saveResults, _) = try await cloud.modify(saving: records, deleting: [])

                    try await db.queue.write { db in
                        for i in 0..<newModels.count {
                            let id = newModels[i].id
                            guard let localSnapshotUpdateAt = localSnapshotByID[id] else {
                                continue
                            }

                            let recordID = records[i].recordID
                            guard let result = saveResults[recordID] else {
                                continue
                            }

                            guard case .success(let savedRecord) = result else {
                                continue
                            }

                            guard var current = try ModelType
                                .filter(Column.Basic.id == id)
                                .fetchOne(db)
                            else {
                                continue
                            }

                            // Skip stale callback write-back when user edited again after enqueue.
                            guard current.updateAt <= localSnapshotUpdateAt else {
                                Logger.sync.warning("[Store-BG] Skip stale batch sync write-back for \(ModelType.recordType) (id: \(id))")
                                continue
                            }

                            current.markSynced()
                            current.updateAt = savedRecord.modificationDate ?? localSnapshotUpdateAt
                            try current.save(db)
                        }
                    }

                    Logger.sync.info("[Store-BG] Batch synced \(newModels.count) \(ModelType.recordType)(s)")
                } catch {
                    Logger.cloud.error("[Store-BG] Batch background sync failed: \(error)")
                }
            }
            return
        }

        // 默认 Cloud-First
        do {
            let records = mutableModels.map { $0.toCKRecord(in: ModelType.zoneID) }
            let (saveResults, _) = try await cloud.modify(saving: records, deleting: [])

            for i in 0..<mutableModels.count {
                let recordID = records[i].recordID
                if let result = saveResults[recordID] {
                    switch result {
                    case .success(let savedRecord):
                        mutableModels[i].markSynced()
                        if let serverDate = savedRecord.modificationDate {
                            mutableModels[i].updateAt = serverDate
                        }
                        Logger.cloud.info("[Store] \(ModelType.recordType) (id: \(mutableModels[i].id)) synced to cloud")
                    case .failure(_):
                        mutableModels[i].markModified()
                        Logger.cloud.error("[Store] Cloud save per-record failed for \(ModelType.recordType) (id: \(mutableModels[i].id))")
                    }
                } else {
                    mutableModels[i].markSynced()
                    Logger.cloud.warning("[Store] No per-record result for \(ModelType.recordType) (id: \(mutableModels[i].id)), marking as synced")
                }
            }
        } catch {
            for i in 0..<mutableModels.count {
                mutableModels[i].markModified()
            }
            Logger.cloud.error("[Store] Batch cloud sync failed for \(models.count) \(ModelType.recordType)(s): \(error)")
        }

        let newModels = mutableModels
        try await db.queue.write { db in
            for model in newModels {
                try model.save(db)
            }
        }

        Logger.grdb.info("[Store] Batch saved \(newModels.count) \(ModelType.recordType)(s) to local DB")
    }
}
