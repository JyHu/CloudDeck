//
//  SyncCoordinator+CRUD.swift
//  CloudDeck
//

/// SyncCoordinator 的 CRUD 扩展
///
/// 提供面向业务层的增删改查操作，采用 **Cloud-First（云端优先）** 策略：
/// 1. 先尝试将数据写入 CloudKit
/// 2. 根据云端返回结果标记每条记录的同步状态（synced / modified / deleted）
/// 3. 最终将标记后的数据批量写入本地 GRDB 数据库
///
/// 这种策略确保了：
/// - 云端可用时，数据立即同步并标记为 `synced`
/// - 云端不可用时，数据仍存入本地并标记为 `modified`（待后续同步）
/// - 删除操作中遇到 `unknownItem` 错误时，视为云端已删除，直接硬删本地记录

import GRDB
import CloudKit
import OSLog

extension SyncCoordinator {
    /// 保存单条记录的便捷方法，内部委托给批量保存
    public func save(_ model: any SyncableProtocol) async throws {
        try await save([model])
    }

    /// 批量保存记录（Cloud-First 策略）
    ///
    /// 执行流程：
    /// 1. 将所有 model 转换为 CKRecord，调用 CloudKit `modify` 接口上传
    /// 2. 逐条检查云端返回结果：
    ///    - 成功：用云端返回的 record 重建 model（获取服务端时间戳等），标记 `synced`
    ///    - 反序列化失败：保留原 model，标记 `modified`（待下次同步重试）
    ///    - 云端写入失败：保留原 model，标记 `modified`
    ///    - 无结果返回：标记 `modified`（异常兜底）
    /// 3. 如果整个 CloudKit 请求抛出异常（如网络不可用），所有记录标记 `modified`
    /// 4. 最终将所有标记后的 model 批量写入本地 GRDB 数据库
    public func save(_ models: [any SyncableProtocol]) async throws {
        guard !models.isEmpty else {
            Logger.sync.debug("[CRUD] save called with empty models, skipping.")
            return
        }

        let recordType = type(of: models[0]).recordType
        Logger.sync.info("[CRUD] Saving \(models.count) \(recordType) record(s) to cloud...")

        var mutableModels = models

        do {
            // 步骤1：将所有 model 转换为 CKRecord 并批量上传到 CloudKit
            let records = models.map { $0.toCKRecord(in: $0.zoneID) }
            let savedResults = try await cloud.modify(saving: records, deleting: []).saveResults

            var syncedCount = 0
            var failedCount = 0

            // 步骤2：逐条处理云端返回结果，决定同步状态
            for i in 0..<mutableModels.count {
                let recordID = mutableModels[i].recordID()

                if let result = savedResults[recordID] {
                    switch result {
                    case .success(let record):
                        // 云端保存成功：用服务端返回的 record 重建 model
                        // 这样可以获取到服务端生成的 changeTag、modificationDate 等元数据
                        do {
                            var newModel = try type(of: mutableModels[i]).init(record: record)
                            newModel.markSynced()
                            mutableModels[i] = newModel
                            syncedCount += 1
                        } catch {
                            // 反序列化失败是罕见的边界情况，保留原 model 并标记待同步
                            Logger.sync.error("[CRUD] Failed to deserialize saved record \(recordID.recordName): \(error)")
                            mutableModels[i].markModified()
                            failedCount += 1
                        }
                    case .failure(let error):
                        // 单条记录写入云端失败（如冲突、权限等），标记待同步
                        Logger.cloud.error("[CRUD] Cloud save failed for \(recordID.recordName): \(error)")
                        mutableModels[i].markModified()
                        failedCount += 1
                    }
                } else {
                    // 云端未返回该记录的结果（异常兜底）
                    Logger.sync.warning("[CRUD] No save result for \(recordID.recordName), marking as modified")
                    mutableModels[i].markModified()
                    failedCount += 1
                }
            }

            Logger.sync.info("[CRUD] Save cloud results: \(syncedCount) synced, \(failedCount) failed")
        } catch {
            // 步骤3：整个 CloudKit 请求失败（网络不可用等），全部标记 modified
            Logger.cloud.error("[CRUD] Cloud modify failed for \(models.count) \(type(of: models[0]).recordType)(s): \(error)")
            for i in 0..<mutableModels.count {
                mutableModels[i].markModified()
            }
        }

        // 步骤4：无论云端结果如何，最终都写入本地数据库（确保数据不丢失）
        let newModels = mutableModels

        Logger.grdb.debug("[CRUD] Writing \(newModels.count) record(s) to local database...")
        try await db.queue.write { db in
            for model in newModels {
                try model.save(db)
            }
        }
        Logger.grdb.info("[CRUD] Successfully wrote \(newModels.count) record(s) to local database")
    }

    /// 删除单条记录的便捷方法，内部委托给批量删除
    public func delete(_ model: any SyncableProtocol) async throws {
        try await delete([model])
    }

    /// 批量删除记录（Cloud-First 策略，硬删 / 软删混合）
    ///
    /// 删除策略说明：
    /// - **硬删除（hard delete）**：云端删除成功后，从本地 GRDB 中彻底移除记录
    /// - **软删除（soft delete）**：云端删除失败时，本地标记 `isDeleted = true`，等待后续同步时重试
    ///
    /// 特殊处理：
    /// - CloudKit 返回 `unknownItem` 错误时，说明记录在云端已不存在（可能被其他设备删除），
    ///   此时视为删除成功，执行本地硬删除
    /// - 整个 CloudKit 请求失败（如离线）时，所有记录执行软删除，保留在本地数据库中
    public func delete(_ models: [any SyncableProtocol]) async throws {
        guard !models.isEmpty else {
            Logger.sync.debug("[CRUD] delete called with empty models, skipping.")
            return
        }

        let recordType = type(of: models[0]).recordType
        Logger.sync.info("[CRUD] Deleting \(models.count) \(recordType) record(s) from cloud...")

        do {
            // 步骤1：批量向 CloudKit 发送删除请求
            let recordIDs = models.map { $0.recordID() }
            let deletedResults = try await cloud.modify(saving: [], deleting: recordIDs).deleteResults

            var mutableModels = models
            /// 收集可以硬删除的记录 ID（云端已确认删除或已不存在）
            var idsToDelete: Set<String> = []

            // 步骤2：逐条检查删除结果，区分硬删和软删
            for i in 0..<mutableModels.count {
                let recordID = mutableModels[i].recordID()

                if let result = deletedResults[recordID] {
                    switch result {
                    case .success:
                        // 云端删除成功 → 加入硬删集合
                        Logger.cloud.debug("[CRUD] Cloud delete succeeded for \(recordID.recordName)")
                        idsToDelete.insert(mutableModels[i].id)
                    case .failure(let error):
                        if let ckError = error as? CKError, ckError.code == .unknownItem {
                            // unknownItem：记录在云端已不存在，同样视为删除成功 → 硬删
                            Logger.cloud.debug("[CRUD] Record \(recordID.recordName) not found on cloud (unknownItem), treating as deleted")
                            idsToDelete.insert(mutableModels[i].id)
                        } else {
                            // 其他错误（权限、限流等）→ 软删除，等待重试
                            Logger.cloud.error("[CRUD] Cloud delete failed for \(recordID.recordName): \(error)")
                            mutableModels[i].markDeleted()
                        }
                    }
                } else {
                    // 云端未返回该记录的结果（异常兜底）→ 软删除
                    Logger.sync.warning("[CRUD] No delete result for \(recordID.recordName), marking as soft deleted")
                    mutableModels[i].markDeleted()
                }
            }

            Logger.sync.info("[CRUD] Delete results: \(idsToDelete.count) permanently deleted, \(mutableModels.count - idsToDelete.count) soft deleted")

            // 步骤3：更新本地数据库 — 硬删的直接 delete，软删的 save（保留 isDeleted 标记）
            let modelsToPersist = mutableModels
            let idsToDeleteCopy = idsToDelete

            try await db.queue.write { db in
                for model in modelsToPersist {
                    if idsToDeleteCopy.contains(model.id) {
                        try model.delete(db)   // 硬删除：从数据库移除
                    } else {
                        try model.save(db)     // 软删除：保留记录，isDeleted = true
                    }
                }
            }
            Logger.grdb.info("[CRUD] Local database updated after delete operation")
        } catch {
            // 整个 CloudKit 请求失败（如离线）→ 所有记录执行软删除
            Logger.cloud.error("[CRUD] Cloud modify (delete) failed for \(models.count) \(recordType)(s): \(error)")
            var models = models

            for i in 0..<models.count {
                models[i].markDeleted()
            }

            let newModels = models

            try await db.queue.write { db in
                for model in newModels {
                    try model.save(db)  // 软删除：保留在本地，等待网络恢复后同步删除
                }
            }
            Logger.grdb.info("[CRUD] Soft deleted \(newModels.count) \(recordType)(s) in local database (cloud unavailable)")
        }
    }
}
