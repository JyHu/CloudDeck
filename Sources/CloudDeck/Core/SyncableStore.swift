//
//  SyncableStore.swift
//  CloudDeck
//

import GRDB
import CloudKit
import OSLog

/// Protocol for per-model stores that handle CRUD and sync operations.
///
/// Each data model type gets its own store conforming to this protocol.
/// The store manages both local persistence and cloud synchronization.
///
/// Usage:
/// ```swift
/// final class ContactStore: SyncableStore {
///     typealias ModelType = Contact
///     let db: GRDBStore
///     let cloud: CloudKitManager
///
///     init(db: GRDBStore, cloud: CloudKitManager) {
///         self.db = db
///         self.cloud = cloud
///     }
///
///     func registerMigrations(_ migrator: inout DatabaseMigrator) {
///         migrator.registerMigration("contacts_v1") { db in
///             try db.create(table: "contact") { t in
///                 t.primaryKey("id", .text)
///                 t.column("name", .text).notNull()
///                 t.column("createAt", .datetime).notNull()
///                 t.column("updateAt", .datetime).notNull()
///                 t.column("isDeleted", .boolean).notNull().defaults(to: false)
///                 t.column("isSynced", .boolean).notNull().defaults(to: false)
///             }
///         }
///     }
/// }
/// ```
public protocol SyncableStore: Sendable {
    associatedtype ModelType: SyncableProtocol

    var db: GRDBStore { get }
    var cloud: CloudKitManager { get }

    init(db: GRDBStore, cloud: CloudKitManager)

    /// Register database table creation/migration logic.
    func registerMigrations(_ migrator: inout DatabaseMigrator)
}

public extension SyncableStore {
    var zoneName: CKRecordZone.Name {
        ModelType.zoneName
    }

    var recordType: CKRecordType {
        ModelType.recordType
    }
}

// MARK: - CRUD Operations

public extension SyncableStore {
    /// Fetch a single record by ID.
    func fetch(id: String) async throws -> ModelType? {
        try await db.queue.read { db in
            try ModelType.fetchOne(db)
        }
    }

    /// Fetch all records.
    func fetchAll() async throws -> [ModelType] {
        try await db.queue.read { db in
            try ModelType.fetchAll(db)
        }
    }

    /// Fetch records matching a query condition.
    func fetchAll(where condition: QueryInterfaceRequest<ModelType>) async throws -> [ModelType] {
        try await db.queue.read { db in
            try condition.fetchAll(db)
        }
    }

    /// Save a single record (Cloud-First strategy).
    func save(_ model: ModelType) async throws {
        var mutableModel = model

        do {
            let record = model.toCKRecord(in: ModelType.zoneID)
            let (saveResults, _) = try await cloud.modify(saving: [record], deleting: [])

            /// 检查单条记录的实际结果（atomically: false 时，单条失败不会抛异常）
            let recordID = record.recordID
            if let result = saveResults[recordID] {
                switch result {
                case .success(let savedRecord):
                    mutableModel.markSynced()
                    // 使用服务器返回的时间更新 updateAt
                    if let serverDate = savedRecord.modificationDate {
                        mutableModel.updateAt = serverDate
                    }
                    Logger.cloud.info("[Store] \(ModelType.recordType) (id: \(model.id)) synced to cloud")
                case .failure(let recordError):
                    mutableModel.markModified()
                    Logger.cloud.error("[Store] Cloud save per-record failed for \(ModelType.recordType) (id: \(model.id)): \(recordError)")
                }
            } else {
                // 没有对应结果，标记为已同步（不应该发生）
                mutableModel.markSynced()
                Logger.cloud.warning("[Store] No per-record result for \(ModelType.recordType) (id: \(model.id)), marking as synced")
            }
        } catch {
            /// 如果同步失败（系统级错误：网络、无账号等），则标记为已经修改，即未同步
            mutableModel.markModified()
            Logger.cloud.error("[Store] Cloud sync failed for \(ModelType.recordType) (id: \(model.id)): \(error)")
        }

        let newModel = mutableModel

        try await db.queue.write { db in
            try newModel.save(db)
        }

        Logger.grdb.debug("[Store] \(ModelType.recordType) (id: \(model.id)) saved to local DB (synced: \(newModel.isSynced))")
    }

    /// Batch save records (Cloud-First strategy).
    func saveAll(_ models: [ModelType]) async throws {
        var mutableModels = models
        
        Logger.sync.info("[Store] Batch saving \(models.count) \(ModelType.recordType)(s) ...") 

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

    /// Delete a record by ID (Cloud-First, falls back to soft delete).
    func delete(_ id: String) async throws {
        Logger.sync.info("[Store] Deleting \(ModelType.recordType) (id: \(id)) ...")
        do {
            let recordID = ModelType.recordID(with: id)
            _ = try await cloud.modify(saving: [], deleting: [recordID])
            
            try await permanentlyDelete(id: id)
            Logger.sync.info("[Store] \(ModelType.recordType) (id: \(id)) permanently deleted (cloud + local)")
        } catch {
            Logger.cloud.error("[Store] Cloud delete failed for \(ModelType.recordType) (id: \(id)): \(error), falling back to soft delete")
            guard var model = try await fetch(id: id) else {
                throw SyncError.modelNotFound(id: id)
            }
            
            model.markDeleted()
            
            let newModel = model
            
            try await db.queue.write {
                try newModel.save($0)
            }
            Logger.grdb.debug("[Store] \(ModelType.recordType) (id: \(id)) soft deleted in local DB")
        }
    }

    /// Batch delete by IDs.
    func deleteAll(_ ids: [String]) async throws {
        Logger.sync.info("[Store] Batch deleting \(ids.count) \(ModelType.recordType)(s) ...")
        do {
            let recordIDs = ids.map { ModelType.recordID(with: $0) }
            _ = try await cloud.modify(saving: [], deleting: recordIDs)
            
            try await permanentlyDelete(ids: ids)
            Logger.sync.info("[Store] Batch permanently deleted \(ids.count) \(ModelType.recordType)(s)")
        } catch {
            Logger.cloud.error("[Store] Batch cloud delete failed for \(ids.count) \(ModelType.recordType)(s): \(error), falling back to soft delete")
            var models = try await fetchAll(where: ModelType.filter(ids.contains(Column("id"))))
            
            for i in 0..<models.count {
                models[i].markDeleted()
            }
            
            let newModels = models
            
            try await db.queue.write {
                for model in newModels {
                    try model.save($0)
                }
            }
            Logger.grdb.info("[Store] Soft deleted \(models.count) \(ModelType.recordType)(s) in local DB")
        }
    }

    /// Delete a model instance (Cloud-First, falls back to soft delete).
    func delete(_ model: ModelType) async throws {
        Logger.sync.info("[Store] Deleting \(ModelType.recordType) model (id: \(model.id)) ...")
        do {
            _ = try await cloud.modify(saving: [], deleting: [ModelType.recordID(with: model.id)])
            
            try await permanentlyDelete(id: model.id)
            Logger.sync.info("[Store] \(ModelType.recordType) (id: \(model.id)) permanently deleted")
        } catch {
            Logger.cloud.error("[Store] Cloud delete failed for \(ModelType.recordType) (id: \(model.id)): \(error)")
            var model = model
            model.markDeleted()
            
            let newModel = model
            
            try await db.queue.write {
                try newModel.save($0)
            }
            Logger.grdb.debug("[Store] \(ModelType.recordType) (id: \(model.id)) soft deleted in local DB")
        }
    }

    /// Batch delete model instances.
    func deleteAll(_ models: [ModelType]) async throws {
        Logger.sync.info("[Store] Batch deleting \(models.count) \(ModelType.recordType) model(s) ...")
        do {
            let recordIDs = models.map({ ModelType.recordID(with: $0.id) })
            _ = try await cloud.modify(saving: [], deleting: recordIDs)
            try await permanentlyDelete(ids: models.map({ $0.id }))
            Logger.sync.info("[Store] Batch permanently deleted \(models.count) \(ModelType.recordType)(s)")
        } catch {
            Logger.cloud.error("[Store] Batch cloud delete failed: \(error)")
            var models = models
            
            for i in 0..<models.count {
                models[i].markDeleted()
            }
            
            let newModels = models
            
            try await db.queue.write {
                for model in newModels {
                    try model.save($0)
                }
            }
            Logger.grdb.info("[Store] Soft deleted \(models.count) \(ModelType.recordType)(s) in local DB")
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
}

// MARK: - 同步操作
extension SyncableStore {
    /// 将云端的变动数据同步到本地数据库
    ///
    /// 这是 Pull-Merge-Push 策略中的 "Merge" 步骤。
    /// 从云端拉取数据后，通过本地冲突解决规则决定接受或拒绝远端更新。
    ///
    /// **冲突解决规则（按优先级排序）**：
    ///
    /// 1. **删除列表检查**（最高优先级）
    ///    - 如果记录同时出现在 records 和 deletions 中
    ///    - 说明这是一个"删除后又创建"的特殊情况
    ///    - 拒绝这条记录，等待下次同步时明确处理
    ///
    /// 2. **本地删除保护**
    ///    - 如果本地数据 isDeleted=true
    ///    - 拒绝远端更新，保护用户的删除意图
    ///    - 下次推送时会删除云端数据
    ///
    /// 3. **未同步修改保护**
    ///    - 如果本地数据 isSynced=false
    ///    - 说明用户正在编辑或刚修改过
    ///    - 拒绝远端更新，保护用户当前的工作
    ///    - 这是 Last-Write-Wins 的关键：保护本地"未确认"的修改
    ///
    /// 4. **时间戳比较**（最后判断）
    ///    - 比较本地 updateAt 和云端 modificationDate
    ///    - 如果本地更新（updateAt > modificationDate）→ 拒绝远端
    ///    - 如果云端更新（updateAt <= modificationDate）→ 接受远端
    ///    - 注意：只有 isSynced=true 时，updateAt 才是可信的服务器时间
    ///
    /// **处理流程**：
    /// 1. 查询本地已存在的对应数据
    /// 2. 根据冲突规则过滤要接受的远端记录
    /// 3. 将接受的记录保存到本地（覆盖或插入）
    /// 4. 物理删除本地的已删除记录
    ///
    /// **为什么需要这个方法**：
    /// - 拉取云端数据后，不能直接覆盖本地
    /// - 需要根据规则判断：本地改动 vs 远端改动，哪个应该保留
    /// - 确保用户正在编辑的数据不会被远端数据覆盖
    ///
    /// - Parameters:
    ///   - records: 从云端拉取的变动数据列表（新增或修改的记录）
    ///   - deletions: 从云端拉取的删除记录列表
    ///
    /// - Throws: 
    ///   - 数据库错误（查询或写入失败）
    ///   - 数据转换错误（CKRecord 转 Model 失败）
    func updateChanged(records: [CKRecord], deletions: [CKDatabase.RecordZoneChange.Deletion]) async throws {
        Logger.sync.info("[Store] updateChanged for \(ModelType.recordType): \(records.count) records, \(deletions.count) deletions")
        
        // ========================================
        // 步骤1: 查询本地已存在的对应数据
        // ========================================
        let locals = try await db.queue.read { db in
            let ids = records.map { $0.recordID.recordName }
            return try ModelType
                .filter(ids.contains(Column("id")))
                .fetchAll(db)
        }
        
        let localsMap = locals.toMap { $0.id }
        let deletionIDs = deletions.map { $0.recordID.recordName }
        
        Logger.sync.info("[Store] \(ModelType.recordType): \(locals.count) existing local record(s), \(deletionIDs.count) deletion ID(s)")
        
        // ========================================
        // 步骤2: 根据冲突规则过滤要接受的远端记录
        // ========================================
        let newRecords = records.filter { record in
            // ====================================
            // 规则1: 删除列表检查
            // ====================================
            // 如果这条记录的 ID 同时出现在 deletions 列表中
            // 这是一个异常情况，可能的原因：
            // - 云端先删除后立即创建了同 ID 的新数据
            // - CloudKit 返回数据不一致
            // 处理方式：拒绝这条记录，避免混淆
            if deletionIDs.contains(record.recordID.recordName) {
                return false
            }
            
            // ====================================
            // 检查本地是否存在这条数据
            // ====================================
            if let local = localsMap[record.recordID.recordName] {
                // 本地存在 → 需要判断冲突
                
                // ====================================
                // 规则2: 本地删除保护
                // ====================================
                // 如果本地数据已标记删除（isDeleted=true）
                // 说明用户想删除这条数据
                // 拒绝远端更新，保护用户的删除意图
                // 下次 pushToCloud() 时会将删除操作同步到云端
                if local.isDeleted {
                    Logger.cloud.info("Skipping remote update for \(record.recordID.recordName) - local is deleted")
                    return false
                }
                
                // ====================================
                // 规则3: 未同步修改保护（最重要！）
                // ====================================
                // 如果本地数据未同步（isSynced=false）
                // 说明用户刚修改过，或正在编辑这条数据
                // 拒绝远端更新，保护用户当前的工作
                //
                // 这是 Pull-Merge-Push 策略的核心：
                // - 用户正在编辑的数据，优先级最高
                // - 即使远端数据更新，也不能覆盖用户的修改
                // - 等用户完成编辑并推送后，再同步
                if !local.isSynced {
                    Logger.cloud.info("Skipping remote update for \(record.recordID.recordName) - local has unsynced changes")
                    return false
                }
                
                // ====================================
                // 规则4: 时间戳比较
                // ====================================
                // 如果本地数据已同步（isSynced=true）
                // 此时 local.updateAt 是上次同步时的服务器时间
                // record.modificationDate 是云端当前的时间
                // 比较这两个时间，选择更新的版本
                //
                // 注意：只有在 isSynced=true 时，这个比较才有意义
                // 因为此时两边的时间基准都是服务器时间
                if let modificationDate = record.modificationDate {
                    if local.updateAt > modificationDate {
                        // 本地时间更新，说明本地版本是基于更新的服务器版本
                        // 拒绝这条远端记录（它是旧版本）
                        Logger.cloud.debug("Skipping remote update for \(record.recordID.recordName) - local is newer")
                        return false
                    }
                }
                
                // 通过了所有检查，接受这条远端记录
                // 原因：云端有更新的版本，且本地没有未同步的修改
                return true
            } else {
                // ====================================
                // 本地不存在 → 直接接受
                // ====================================
                return true
            }
        }
        
        Logger.sync.info("[Store] \(ModelType.recordType) conflict resolution: \(newRecords.count) accepted, \(records.count - newRecords.count) rejected")
        
        // ========================================
        // 步骤3: 保存接受的远端记录到本地
        // ========================================
        try await db.queue.write { db in
            // 遍历所有接受的远端记录
            for record in newRecords {
                var model = try ModelType(record: record)
                
                // 标记为已同步
                model.isSynced = true
                
                // 保存到本地数据库
                // 如果 ID 已存在，这是一个更新操作（REPLACE）
                // 如果 ID 不存在，这是一个插入操作（INSERT）
                try model.save(db)
            }
            
            // ========================================
            // 步骤4: 处理删除操作
            // ========================================
            let deletedCount = try ModelType
                .filter(deletionIDs.contains(Column("id")))
                .deleteAll(db)
            
            if deletedCount > 0 {
                Logger.sync.info("[Store] \(ModelType.recordType): physically deleted \(deletedCount) record(s) from local DB")
            }
        }
        
        Logger.sync.info("[Store] updateChanged completed for \(ModelType.recordType): \(newRecords.count) saved, \(deletionIDs.count) deletions processed")
    }
    
    /// 将本地未同步的数据推送到云端
    ///
    /// 采用 Pull-Merge-Push 策略，确保推送时无冲突：
    /// 1. 推送前先拉取最新云端数据（可选，默认开启）
    /// 2. 在本地通过 updateAt 比较解决冲突
    /// 3. 推送已解决冲突的数据到云端
    /// 4. 如果推送仍有冲突（说明拉取后又有新修改），自动重试
    ///
    /// **工作原理**：
    /// - 通过 pullFirst 参数，在推送前拉取最新数据，提前发现和解决冲突
    /// - 冲突解决规则由 updateChanged() 实现：
    ///   1. 本地未同步（isSynced=false）→ 优先级最高，保护用户正在编辑的数据
    ///   2. 本地已删除（isDeleted=true）→ 拒绝远端更新，保护删除意图
    ///   3. 比较 updateAt 时间戳 → 选择时间更新的版本
    ///
    /// **为什么推送前要拉取**：
    /// - 避免推送时的 serverRecordChanged 错误
    /// - 在本地比较 updateAt，决定使用哪个版本的数据
    /// - 推送时已经是"无冲突"的最新数据，成功率更高
    ///
    /// **自动重试机制**：
    /// - 如果推送返回 serverRecordChanged 错误（说明拉取和推送之间又有新修改）
    /// - 自动重新拉取最新数据并解决冲突
    /// - 重新推送，最多重试一次（避免无限循环）
    ///
    /// - Parameters:
    ///   - pullFirst: 是否在推送前先拉取最新数据
    ///                默认 true（推荐）：提前解决冲突，成功率高
    ///                设为 false：直接推送，可能遇到 serverRecordChanged 错误
    ///   - retryOnConflict: 推送冲突时是否自动重试
    ///                      默认 true（推荐）：自动处理并发修改场景
    ///                      设为 false：失败就失败，需要手动重试
    ///
    /// - Returns: SyncResult 同步结果统计
    ///            - saved: 成功推送并保存的数量
    ///            - deleted: 成功删除的数量
    ///            - failed: 失败的数量（可能是网络错误、权限问题等）
    ///
    /// - Throws: SyncError 或其他错误
    ///           - 网络错误：无法连接到 iCloud
    ///           - 权限错误：iCloud 未登录或无权限
    ///           - 数据错误：模型转换失败
    ///
    /// **使用示例**：
    /// ```swift
    /// // 默认方式（最安全，推荐）
    /// let result = try await contactStore.pushToCloud()
    /// if result.isSuccess {
    ///     print("同步成功")
    /// }
    ///
    /// // 快速推送（不拉取，适合确定本地是最新的场景）
    /// let result = try await contactStore.pushToCloud(pullFirst: false)
    ///
    /// // 不自动重试（需要手动处理冲突）
    /// let result = try await contactStore.pushToCloud(retryOnConflict: false)
    /// if result.failed > 0 {
    ///     // 手动处理冲突
    /// }
    /// ```
    @discardableResult
    func pushToCloud(pullFirst: Bool = true, retryOnConflict: Bool = true) async throws -> SyncResult {
        // ========================================
        // 步骤1: 推送前先拉取最新数据，在本地解决冲突
        // ========================================
        // 这是 Pull-Merge-Push 策略的核心：
        // - 拉取云端最新数据
        // - 通过 updateChanged() 在本地比较 updateAt
        // - 决定使用云端版本还是本地版本
        // - 这样推送时就不会遇到冲突（数据已经是最新的）
        if pullFirst {
            try await pullLatestChanges()
        }
        
        // ========================================
        // 步骤2: 查询所有未同步的数据
        // ========================================
        // isSynced=false 表示：
        // 1. 新创建的数据（从未同步到云端）
        // 2. 修改过的数据（修改后自动标记为未同步）
        // 3. 标记删除的数据（需要同步删除操作到云端）
        // 4. 上次推送失败的数据（会在这里重新尝试）
        //
        // 如果启用了 pullFirst，这里查询到的数据已经是：
        // - 与云端比较后决定保留的本地版本（本地更新或相同）
        // - 拒绝了云端更新的数据（因为本地有未同步的修改）
        let unsyncedModels = try await db.queue.read { db in
            try ModelType
                .filter(Column("isSynced") == false)
                .fetchAll(db)
        }
        
        // 如果没有未同步的数据，直接返回
        // 这使得多次调用 pushToCloud() 是安全的（幂等性）
        guard !unsyncedModels.isEmpty else {
            return SyncResult(saved: 0, deleted: 0, failed: 0)
        }
        
        // ========================================
        // 步骤3: 执行推送操作
        // ========================================
        // 调用 performPush() 将数据推送到 CloudKit
        // 使用 savePolicy: .ifServerRecordUnchanged 确保：
        // - 只有服务器记录未被修改时才能保存
        // - 如果服务器有新版本，返回 serverRecordChanged 错误
        let result = try await performPush(models: unsyncedModels)
        
        // ========================================
        // 步骤4: 冲突检测和自动重试
        // ========================================
        // 如果推送有失败（result.failed > 0），说明可能遇到了冲突
        // 冲突原因：在步骤1拉取后、步骤3推送前，又有其他设备推送了新数据
        //
        // 时间线示例：
        // T1: 本地执行 pullLatestChanges() - 拉取到版本 A
        // T2: 其他设备推送版本 B 到云端
        // T3: 本地执行 performPush() - 尝试推送基于版本 A 的修改
        // T4: CloudKit 检测到冲突（当前是版本 B，不是版本 A）
        // T5: 返回 serverRecordChanged 错误
        //
        // 处理方式：
        // - 重新拉取最新数据（版本 B）
        // - 在本地再次比较并解决冲突
        // - 重新推送（基于版本 B 的修改）
        // - 最多重试一次，避免无限循环
        if result.failed > 0 && retryOnConflict {
            Logger.cloud.info("Detected conflicts, retrying push for \(recordType)")
            
            // 重新拉取，解决冲突
            try await pullLatestChanges()
            
            // 重新查询未同步数据
            // 注意：这里查询到的数据可能比之前少
            // 原因：某些本地数据在拉取时被远端更新的数据覆盖了
            //      （远端数据的 updateAt 更新，且本地 isSynced=true）
            let retryModels = try await db.queue.read { db in
                try ModelType
                    .filter(Column("isSynced") == false)
                    .fetchAll(db)
            }
            
            // 如果还有未同步的数据，重新推送
            // 如果没有了，说明冲突已通过"使用远端数据"的方式解决
            if !retryModels.isEmpty {
                return try await performPush(models: retryModels)
            }
        }
        
        return result
    }
    
    /// 拉取最新的云端变更到本地
    ///
    /// 这是 Pull-Merge-Push 策略中的 "Pull" 步骤。
    /// 从 CloudKit 拉取指定 Zone 的所有变更，然后通过 updateChanged() 方法在本地解决冲突。
    ///
    /// **工作流程**：
    /// 1. 调用 CloudKit API 获取指定 Zone 的所有记录变更
    /// 2. 过滤出当前 Store 管理的 recordType 的数据
    /// 3. 调用 updateChanged() 方法，在本地比较 updateAt 并解决冲突
    ///
    /// **冲突解决规则**（由 updateChanged() 实现）：
    /// - 如果本地数据 isSynced=false（用户正在编辑）→ 拒绝远端更新，保护用户修改
    /// - 如果本地数据 isDeleted=true（已删除）→ 拒绝远端更新，保护删除意图
    /// - 比较 updateAt 和 modificationDate → 选择时间更新的版本
    ///
    /// **Change Token 说明**：
    /// 当前使用 `since: nil`，表示获取所有数据（不使用增量同步）
    /// 优点：逻辑简单，适合数据量不大的场景
    /// 缺点：每次都拉取全量数据，网络开销较大
    /// 未来可优化：使用 change token 实现增量同步，只拉取自上次以来的变更
    ///
    /// - Throws: 
    ///   - CloudKit 错误（网络、权限等）
    ///   - 数据转换错误（record 转 model 失败）
    ///   - 数据库错误（保存到本地失败）
    private func pullLatestChanges() async throws {
        let zoneID = CKRecordZone.ID(zoneName: zoneName)
        
        // ========================================
        // 从 CloudKit 获取当前 Zone 的所有变更
        // ========================================
        // since: nil 表示不使用 change token，获取所有记录
        // 返回值包含：
        // - modificationResultsByID: 新增或修改的记录（字典，key 是 recordID）
        // - deletions: 删除的记录 ID 列表
        // - changeToken: 本次查询的 token（可用于下次增量查询）
        // - moreComing: 是否还有更多数据（分页）
        let changes = try await cloud.privateDB.recordZoneChanges(
            inZoneWith: zoneID,
            since: nil  // 未来优化：使用缓存的 token 实现增量同步
        )
        
        // ========================================
        // 过滤当前 Store 管理的数据类型
        // ========================================
        // 一个 Zone 可能包含多种 recordType 的数据
        // 例如：Contacts Zone 包含 Contact 和 ContactGroup 两种类型
        // 这里只处理当前 Store 负责的 recordType
        //
        // modificationResultsByID 的结构：
        // [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>]
        // 
        // 处理步骤：
        // 1. compactMapValues: 提取成功的记录（忽略失败的）
        // 2. .values: 获取所有记录
        // 3. filter: 只保留当前 recordType 的记录
        let relevantRecords = changes.modificationResultsByID
            .compactMapValues { try? $0.get().record }  // 提取 CKRecord
            .values
            .filter { $0.recordType == recordType }  // 只要当前类型
        
        // 过滤删除的记录
        // deletions 的结构：[CKDatabase.RecordZoneChange.Deletion]
        // Deletion 包含：recordID, recordType, reason 等信息
        let relevantDeletions = changes.deletions
            .filter { $0.recordType == recordType }
        
        // ========================================
        // 调用 updateChanged() 在本地解决冲突
        // ========================================
        // updateChanged() 会：
        // 1. 查询本地对应的数据
        // 2. 比较 updateAt 和 modificationDate
        // 3. 根据冲突解决规则决定使用哪个版本
        // 4. 更新本地数据库或拒绝远端更新
        //
        // 转换为数组是因为 updateChanged 的参数类型是 [CKRecord]
        try await updateChanged(records: Array(relevantRecords), deletions: relevantDeletions)
    }
    
    /// 执行实际的推送操作到 CloudKit
    ///
    /// 这是 Pull-Merge-Push 策略中的 "Push" 步骤。
    /// 将本地未同步的数据推送到 CloudKit，并根据服务器返回的结果更新本地状态。
    ///
    /// **推送策略**：
    /// 使用 CloudKit 的 `savePolicy: .ifServerRecordUnchanged` 策略：
    /// - 只有服务器记录未被修改时才能保存成功
    /// - 如果服务器已有新版本，返回 `CKError.serverRecordChanged` 错误
    /// - 这是最安全的策略，避免覆盖其他设备的修改
    ///
    /// **原子性**：
    /// 使用 `atomically: false`，表示非原子操作：
    /// - 部分成功、部分失败是允许的
    /// - 成功的会立即生效，失败的可以重试
    /// - 适合批量操作，避免一个失败导致全部回滚
    ///
    /// **时间同步**：
    /// 推送成功后，从服务器返回的 CKRecord 中获取 `modificationDate`
    /// 通过 `ModelType(record:)` 初始化模型，自动将 `updateAt` 设为服务器时间
    /// 这确保了本地和服务器的时间基准统一，为下次比较做准备
    ///
    /// - Parameter models: 要推送的模型列表（所有 isSynced=false 的数据）
    /// - Returns: SyncResult 同步结果统计
    /// - Throws: CloudKit 错误、数据库错误等
    private func performPush(models: [ModelType]) async throws -> SyncResult {
        let zoneID = CKRecordZone.ID(zoneName: zoneName)
        
        // ========================================
        // 分离删除和保存的数据
        // ========================================
        // isDeleted=true 的数据需要调用 CloudKit 的删除 API
        // isDeleted=false 的数据需要调用 CloudKit 的保存 API
        //
        // 为什么需要分离：
        // - CloudKit 的 modifyRecords API 同时支持保存和删除
        // - 但参数是分开的：saving 和 deleting
        // - 保存需要完整的 CKRecord，删除只需要 CKRecord.ID
        let deletedModels = models.filter { $0.isDeleted }
        let savedModels = models.filter { !$0.isDeleted }
        
        // ========================================
        // 将模型转换为 CloudKit 记录
        // ========================================
        // 保存操作：调用 toCKRecord() 将模型转换为 CKRecord
        // 包含所有字段：id, name, email, updateAt 等业务数据
        let recordsToSave = savedModels.map { $0.toCKRecord(in: zoneID) }
        
        // 删除操作：只需要 recordID，不需要完整数据
        // CKRecord.ID 包含：recordName（数据 ID）和 zoneID（所在 Zone）
        let recordIDsToDelete = deletedModels.map { CKRecord.ID(recordName: $0.id, zoneID: zoneID) }
        
        // ========================================
        // 推送到 CloudKit
        // ========================================
        // CloudKitManager.modify() 内部调用：
        // privateDB.modifyRecords(
        //     saving: recordsToSave,
        //     deleting: recordIDsToDelete,
        //     savePolicy: .ifServerRecordUnchanged,  // 冲突检测策略
        //     atomically: false                       // 非原子操作
        // )
        //
        // 返回值：
        // - saveResults: [CKRecord.ID: Result<CKRecord, Error>]
        //   成功返回服务器的 CKRecord（包含服务器时间）
        //   失败返回错误（可能是 serverRecordChanged）
        // - deleteResults: [CKRecord.ID: Result<Void, Error>]
        //   成功返回空
        //   失败返回错误
        let (saveResults, deleteResults) = try await cloud.modify(
            saving: recordsToSave,
            deleting: recordIDsToDelete
        )
        
        // ========================================
        // 处理推送结果，更新本地状态
        // ========================================
        // 需要在事务中执行，确保数据一致性：
        // - 要么全部更新成功
        // - 要么全部不更新（发生错误时回滚）
        return try await db.queue.write { db in
            var savedCount = 0    // 成功保存的数量
            var deletedCount = 0  // 成功删除的数量
            var failedCount = 0   // 失败的数量
    
            // ========================================
            // 处理保存结果
            // ========================================
            for (recordID, result) in saveResults {
                switch result {
                case .success(let savedRecord):
                    // ====================================
                    // 保存成功，更新本地模型
                    // ====================================
                    // 关键：使用服务器返回的 CKRecord 重新创建模型
                    // 为什么不直接标记 isSynced=true：
                    // 1. 服务器可能修改了某些字段（如 modificationDate）
                    // 2. 通过 init(record:) 确保 updateAt 是服务器时间
                    // 3. 统一时间基准，为下次冲突比较做准备
                    //
                    // savedRecord.modificationDate 是服务器时间
                    // 通过 init(record:) 会自动赋值给 model.updateAt
                    // 这样本地的 updateAt 就和服务器保持一致了
                    var model = try ModelType(record: savedRecord)
                    
                    // 标记为已同步
                    // markSynced() 会设置 isSynced=true
                    model.markSynced()
                    
                    // 保存到本地数据库
                    // 由于 id 相同，这是一个更新操作（REPLACE）
                    try model.save(db)
                    
                    savedCount += 1
                    
                case .failure(let error):
                    // ====================================
                    // 保存失败，记录错误
                    // ====================================
                    // 检查是否是 serverRecordChanged 错误
                    // 这是一个"可重试"的错误，说明服务器有新版本
                    if let ckError = error as? CKError, 
                       ckError.code == .serverRecordChanged {
                        // 警告级别：这是预期内的冲突，不是严重错误
                        // 调用者会根据 retryOnConflict 参数决定是否重试
                        Logger.cloud.warning("Server record changed for \(recordID.recordName), will retry")
                    } else {
                        // 其他错误（网络、权限、数据格式等）
                        // 错误级别：需要人工介入或用户重试
                        Logger.cloud.error("Save record failed: \(recordID.recordName), error: \(error)")
                    }
                    
                    // 无论哪种错误，都计入失败数
                    // 本地数据保持 isSynced=false，下次可以重试
                    failedCount += 1
                }
            }
            
            // ========================================
            // 处理删除结果
            // ========================================
            for (recordID, result) in deleteResults {
                switch result {
                case .success(_):
                    // ====================================
                    // 删除成功，物理删除本地数据
                    // ====================================
                    // 为什么是物理删除：
                    // 1. 云端已经删除成功，同步目标已达成
                    // 2. 本地保留软删除数据（isDeleted=true）没有意义
                    // 3. 物理删除可以释放存储空间
                    //
                    // 如果删除失败（下面的 case .failure）
                    // 本地会保留 isDeleted=true 的数据，下次继续尝试删除
                    try ModelType.deleteOne(db, key: recordID.recordName)
                    deletedCount += 1
                    
                case .failure(let error):
                    // ====================================
                    // 删除失败，记录错误
                    // ====================================
                    // serverRecordChanged：服务器记录已被修改或已删除
                    // 可能原因：其他设备也尝试删除，或者恢复了数据
                    if let ckError = error as? CKError, 
                       ckError.code == .serverRecordChanged {
                        Logger.cloud.warning("Server record changed for \(recordID.recordName), will retry")
                    } else {
                        // 其他错误（网络、权限等）
                        Logger.cloud.error("Delete record failed: \(recordID.recordName), error: \(error)")
                    }
                    
                    // 计入失败数
                    // 本地数据保持 isDeleted=true, isSynced=false
                    // 下次推送时会重新尝试删除
                    failedCount += 1
                }
            }
            
            // ========================================
            // 返回同步结果统计
            // ========================================
            // 调用者可以通过这个结果：
            // - 判断是否全部成功（result.isSuccess）
            // - 显示成功/失败数量给用户
            // - 决定是否需要重试（result.failed > 0）
            return SyncResult(saved: savedCount, deleted: deletedCount, failed: failedCount)
        }
    }
}

/// 同步结果统计
public struct SyncResult: Sendable {
    /// 成功保存的数量
    public let saved: Int
    
    /// 成功删除的数量
    public let deleted: Int
    
    /// 失败的数量
    public let failed: Int

    public init(saved: Int, deleted: Int, failed: Int) {
        self.saved = saved
        self.deleted = deleted
        self.failed = failed
    }
    
    /// 是否全部成功
    public var isSuccess: Bool {
        failed == 0
    }
    
    /// 总操作数
    public var total: Int {
        saved + deleted + failed
    }
}
