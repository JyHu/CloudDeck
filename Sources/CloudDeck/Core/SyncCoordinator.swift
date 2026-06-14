//
//  SyncCoordinator.swift
//  CloudDeck
//

import GRDB
import CloudKit
import OSLog

/// 同步协调器 - 整个数据同步框架的中心控制器
///
/// **职责**：
/// - 管理所有 Store 实例的生命周期和访问
/// - 初始化本地数据库和 CloudKit 连接
/// - 自动创建 CloudKit Zones 和 Subscriptions
/// - 协调多个 Store 之间的同步操作
/// - 处理远程推送通知并触发数据拉取
///
/// **架构设计**：
/// ```
/// SyncCoordinator（中心控制器）
///     ├── GRDBStore（本地数据库）
///     ├── CloudKitManager（云端连接）
///     └── Stores（多个数据表）
///         ├── ContactStore
///         ├── GroupStore
///         └── ...
/// ```
///
/// **初始化流程**：
/// 1. 创建 CloudKitManager 和 GRDBStore
/// 2. 通过闭包创建所有 Store 实例
/// 3. 提取所有 Zone 名称并生成配置
/// 4. 调用 setup() 完成初始化：
///    - 注册数据库表结构（Migrations）
///    - 检查并创建 CloudKit Zones
///    - 检查并创建 Subscriptions
///
/// **使用示例**：
/// ```swift
/// let coordinator = try SyncCoordinator(
///     databasePath: "/path/to/database.sqlite",
///     containerID: "iCloud.com.example.app"
/// )
///
/// // 完成初始化
/// try await coordinator.setup(with: stores)
///
/// // 获取具体的 Store
/// let contactStore = coordinator.store(for: ContactStore.self)
///
/// // 手动触发全量同步
/// try await coordinator.pushAllToCloud()
///
/// // 处理远程通知
/// try await coordinator.handleRemoteNotification(notification)
/// ```
// @unchecked Sendable: Thread safety managed via NSLock for mutable state (deferredPushTask).
// Dictionary properties (stores, configs) are only mutated during single-threaded setup phase.
public class SyncCoordinator: @unchecked Sendable {
    /// Zone 配置信息
    ///
    /// **用途**：
    /// - 统一管理每个 Zone 相关的所有标识符
    /// - 避免在不同地方重复计算 zoneID 和 subscriptionID
    /// - 提供快速查找：zoneName → Config, subscriptionID → Config
    ///
    /// **设计原因**：
    /// - 一个 Zone 对应一个或多个数据表
    /// - 一个 Zone 需要一个 Subscription 来接收变更通知
    /// - 集中管理这些关联关系，方便维护
    private struct Config {
        let zoneName: CKRecordZone.Name
        let zoneID: CKRecordZone.ID
        let subscriptionID: CKRecordZoneSubscription.ID

        /// 初始化 Zone 配置
        /// - Parameter zoneName: Zone 名称
        ///
        /// **Subscription ID 命名规则**：
        /// - 格式：zoneName + "_subscription"
        /// - 确保每个 Zone 有唯一的 Subscription ID
        /// - 用于在收到远程通知时识别是哪个 Zone 的数据变更
        init(zoneName: CKRecordZone.Name) {
            self.zoneName = zoneName
            self.zoneID = CKRecordZone.ID(zoneName: zoneName)
            self.subscriptionID = zoneName + "_subscription"
        }
    }

    /// 同步配置（运行时可修改）
    ///
    /// 控制是否启用 CloudKit 同步、是否后台执行等行为。
    /// 可以在应用运行期间动态修改，立即生效。
    ///
    /// ```swift
    /// coordinator.syncConfiguration.isSyncEnabled = false  // 关闭同步
    /// coordinator.syncConfiguration.performSyncInBackground = true  // 后台同步
    /// ```
    public let syncConfiguration: SyncConfiguration

    /// 后台同步失败时的延迟重试 Task（去抖动：多个失败只触发一次重试）
    private var deferredPushTask: Task<Void, Never>?
    private let deferredPushLock = NSLock()

    /// 本地数据库管理器
    /// 所有 Store 共享同一个数据库连接
    public let db: GRDBStore

    /// CloudKit 管理器
    /// 所有 Store 共享同一个 CloudKit Container
    public let cloud: CloudKitManager

    /// 所有已注册的 Store 实例
    /// Key: RecordType（如 "Contact"、"ContactGroup"）
    /// Value: Store 实例
    ///
    /// **用途**：
    /// - 通过 recordType 快速查找对应的 Store
    /// - 在收到远程通知时，根据 recordType 分发数据到对应的 Store
    /// - 批量操作时遍历所有 Store（如 pushAllToCloud）
    private var stores: [CKRecordType: any SyncableStore] = [:]

    /// Zone 名称到配置的映射
    /// 用于根据 Zone 名称查找对应的配置信息
    private var zoneNameToConfigs: [CKRecordZone.Name: Config] = [:]

    /// Subscription ID 到配置的映射
    /// **关键用途**：
    /// - 收到远程推送通知时，notification.subscriptionID 可以直接查找到对应的 Zone
    /// - 快速定位需要拉取数据的 Zone
    private var subscriptionToConfigs: [CKRecordZoneSubscription.ID: Config] = [:]

    /// 初始化同步协调器
    ///
    /// - Parameters:
    ///   - databasePath: 本地 SQLite 数据库文件路径
    ///     建议路径：DocumentDirectory 或 ApplicationSupportDirectory
    ///   - containerID: CloudKit Container 标识符
    ///     格式："iCloud.com.yourcompany.yourapp"
    ///     需要在 Xcode Capabilities 中配置
    /// - Throws: 数据库创建失败时的错误
    public init(databasePath: String, containerID: String, configuration: SyncConfiguration = SyncConfiguration()) throws {
        self.cloud = CloudKitManager(containerID: containerID, policy: configuration.policy)
        self.db = try GRDBStore(path: databasePath)
        self.syncConfiguration = configuration
    }

    /// 使用默认 CloudKit Container 初始化
    public init(databasePath: String, configuration: SyncConfiguration = SyncConfiguration()) throws {
        self.cloud = CloudKitManager(policy: configuration.policy)
        self.db = try GRDBStore(path: databasePath)
        self.syncConfiguration = configuration
    }

    /// 完成初始化设置
    ///
    /// **必须在使用前调用**，完成以下操作：
    ///
    /// 1. **注册数据库迁移**（registerMigrations）
    ///    - 遍历所有 Store，收集它们的表结构定义
    ///    - 使用 GRDB 的 Migrator 自动创建或更新表
    ///
    /// 2. **检查并创建 CloudKit Zones**（checkZones）
    ///    - 查询云端已存在的 Zones
    ///    - 对比本地需要的 Zones
    ///    - 创建缺失的 Zones
    ///
    /// 3. **检查并创建 Subscriptions**（checkSubscriptions）
    ///    - 查询云端已存在的 Subscriptions
    ///    - 对比本地需要的 Subscriptions
    ///    - 创建缺失的 Subscriptions
    ///    - 配置静默推送通知
    ///
    /// **错误处理**：
    /// - 数据库迁移失败 → 抛出异常（严重错误，必须处理）
    /// - Zone 创建失败 → 记录日志，不抛出异常（可以后续重试）
    /// - Subscription 创建失败 → 记录日志，不抛出异常
    ///
    /// - Throws: 数据库迁移失败或 CloudKit 网络错误
    /// 完成云端初始化（需要先调用 registerStoresAndMigrate）
    ///
    /// 检查并创建 Zones 和 Subscriptions，完成后标记云端就绪并推送本地待同步数据。
    public func setup() async throws {
        guard !stores.isEmpty else {
            Logger.sync.error("[SyncCoordinator] setup() called but no stores registered. Call registerStoresAndMigrate first.")
            return
        }
        
        try await checkZones()
        try await checkSubscriptions()

        // Mark cloud as ready and push any locally-queued data
        syncConfiguration.isCloudReady = true
        Logger.sync.info("[SyncCoordinator] Cloud ready, pushing pending changes...")
    }

    /// 注册 Stores 并完成云端初始化（一步到位）
    public func setup(with stores: [any SyncableStore]) async throws {
        if self.stores.isEmpty {
            try registerStoresAndMigrate(stores)
        }
        try await setup()
    }

    /// 同步方法：注册所有 Store 并执行数据库迁移
    /// 可在初始化时调用，确保数据库表在任何观察之前就已创建
    public func registerStoresAndMigrate(_ stores: [any SyncableStore]) throws {
        Logger.sync.info("[SyncCoordinator] Registering \(stores.count) store(s) and running migrations...")

        // 创建所有 Store 并按 recordType 组织
        self.stores = stores.toMap { $0.recordType }

        // 提取所有唯一的 Zone 名称并创建配置
        let configs = Set(self.stores.values.map { $0.zoneName }).map { Config(zoneName: $0) }

        // 创建快速查找字典
        self.zoneNameToConfigs = configs.toMap { $0.zoneName }
        self.subscriptionToConfigs = configs.toMap { $0.subscriptionID }

        try registerMigrations()
        Logger.sync.info("[SyncCoordinator] Stores registered and migrations completed")
    }
}

// MARK: - 私有方法（初始化相关）

private extension SyncCoordinator {
    /// 注册所有数据表的数据库迁移
    ///
    /// **GRDB 迁移机制**：
    /// - 使用 DatabaseMigrator 管理表结构的版本变化
    /// - 每个 Store 定义自己的表结构（通过 registerMigrations 方法）
    /// - Migrator 自动跟踪哪些迁移已经执行过
    /// - 只执行未执行的迁移，避免重复
    ///
    /// - Throws: 数据库迁移失败（表创建错误、字段类型冲突等）
    func registerMigrations() throws {
        var migrator = DatabaseMigrator()

        // 遍历所有 Store，收集它们的迁移定义
        for (_, store) in stores {
            store.registerMigrations(&migrator)
        }

        // 注册 CKServerChangeTokenRecord 表迁移（用于缓存增量同步 Token）
        migrator.registerMigration("CKServerChangeTokenRecord_v1") { db in
            try db.create(table: "CKServerChangeTokenRecord", ifNotExists: true) { t in
                t.primaryKey("subscriptionID", .text)
                t.column("token", .blob).notNull()
            }
        }

        // 执行所有迁移（只执行未执行的）
        try migrator.migrate(db.queue)
    }

    /// 检查并创建所有需要的 CloudKit Zones
    ///
    /// **CloudKit Zone 的作用**：
    /// - 将数据分组管理（类似数据库中的 Schema）
    /// - 支持原子性操作（同一个 Zone 的数据可以一起提交）
    /// - 支持订阅机制（订阅某个 Zone 的变更通知）
    /// - 默认 Zone（_defaultZone）不支持 Subscription，所以必须创建自定义 Zone
    ///
    /// **执行流程**：
    /// 1. 查询云端已存在的所有 Zones
    /// 2. 提取本地需要的 Zone 名称（从 stores 中）
    /// 3. 对比找出缺失的 Zones
    /// 4. 批量创建缺失的 Zones
    ///
    /// - Throws: CloudKit 网络错误或权限错误
    func checkZones() async throws {
        // 查询云端已存在的 Zones
        let zones = try await cloud.privateDB.allRecordZones()

        // 提取本地需要的 Zone 名称
        let existsNames = Set(stores.values.map { $0.zoneName })

        // 按名称分组已存在的 Zones（方便查找）
        let groupdZones = zones.toMap { $0.zoneID.zoneName }

        // 找出需要创建的 Zones（本地需要但云端没有的）
        let newZones = existsNames
            .filter { groupdZones[$0] == nil }
            .map { CKRecordZone(zoneName: $0) }

        // 批量创建 Zones
        let (savedResults, _) = try await cloud.privateDB.modifyRecordZones(saving: newZones, deleting: [])

        // 记录创建结果
        for (zoneID, result) in savedResults {
            switch result {
            case .success:
                Logger.cloud.info("Create zone successed: \(zoneID.zoneName)")
            case .failure(let error):
                Logger.cloud.error("Create zone failed: \(zoneID.zoneName), error: \(error)")
            }
        }
    }

    /// 检查并创建所有需要的 CloudKit Subscriptions
    ///
    /// **Subscription 的作用**：
    /// - 订阅 Zone 的数据变更通知
    /// - 当 Zone 中有数据变化时，CloudKit 自动发送静默推送
    /// - 应用收到推送后，拉取最新数据
    /// - 实现自动同步，无需定时轮询
    ///
    /// **通知配置**：
    /// - shouldSendContentAvailable = true：发送静默推送
    /// - 静默推送不会显示通知横幅，不打扰用户
    /// - 应用在后台也能收到推送并处理
    ///
    /// - Throws: CloudKit 网络错误或权限错误
    func checkSubscriptions() async throws {
        // 查询云端已存在的 Subscriptions
        let subscriptions = try await cloud.privateDB.allSubscriptions()

        // 提取本地需要的 Subscription 配置
        let existsNames = Set(stores.values.map { $0.zoneName }).map { Config(zoneName: $0) }

        // 按 subscriptionID 分组已存在的 Subscriptions
        let groupdSubscriptions = subscriptions.toMap { $0.subscriptionID }

        // 找出需要创建的 Subscriptions
        let newSubscriptions = existsNames
            .filter { groupdSubscriptions[$0.subscriptionID] == nil }
            .map { config in
                // 创建 Zone Subscription
                let subscription = CKRecordZoneSubscription(zoneID: config.zoneID, subscriptionID: config.subscriptionID)

                // 配置通知信息（静默推送）
                let notificationInfo = CKSubscription.NotificationInfo()
                notificationInfo.shouldSendContentAvailable = true
                subscription.notificationInfo = notificationInfo

                return subscription
            }

        // 批量创建 Subscriptions
        let (savedResults, _) = try await cloud.privateDB.modifySubscriptions(saving: newSubscriptions, deleting: [])

        // 记录创建结果
        for (subscriptionID, result) in savedResults {
            switch result {
            case .success:
                Logger.cloud.info("Create subscription successed: \(subscriptionID)")
            case .failure(let error):
                Logger.cloud.error("Create subscription failed: \(subscriptionID), error: \(error)")
            }
        }
    }
}

// MARK: - 公开方法（Store 访问和同步操作）

public extension SyncCoordinator {
    /// 根据类型获取对应的 Store 实例（类型安全）
    ///
    /// **使用示例**：
    /// ```swift
    /// if let contactStore = coordinator.store(for: ContactStore.self) {
    ///     let contact = try await contactStore.fetch(id: "123")
    /// }
    /// ```
    func store<T: SyncableStore>(for type: T.Type) -> T? {
        store(for: T.ModelType.recordType) as? T
    }

    /// 根据 recordType 获取对应的 Store 实例
    ///
    /// **使用场景**：
    /// - 收到远程推送通知时，根据 recordType 分发数据
    /// - 字典查找：O(1)，非常快
    func store(for recordType: CKRecordType) -> (any SyncableStore)? {
        stores[recordType]
    }

    /// 手动触发全量同步（推送所有未同步的数据到云端）
    ///
    /// **执行流程**：
    /// 1. 遍历所有 Store
    /// 2. 对每个 Store 调用 pushToCloud()
    /// 3. 收集每个 Store 的同步结果
    /// 4. 返回汇总的同步结果字典
    ///
    /// **使用场景**：
    /// - 用户手动点击"同步"按钮
    /// - 应用从后台恢复时主动同步
    /// - 网络恢复后重新同步
    ///
    /// - Returns: 每个 Store 的同步结果字典
    /// - Throws: 任何一个 Store 同步失败时抛出 SyncError
    @discardableResult
    func pushAllToCloud() async throws -> [CKRecordType: SyncResult] {
        guard syncConfiguration.isSyncEnabled else {
            Logger.sync.info("[SyncCoordinator] pushAllToCloud skipped (sync disabled)")
            return [:]
        }

        var results: [CKRecordType: SyncResult] = [:]

        // 遍历所有 Store，逐个同步
        for (recordType, store) in stores {
            do {
                let result = try await store.pushToCloud()
                results[recordType] = result

                Logger.cloud.info("Push \(recordType) to cloud: \(result.saved) saved, \(result.deleted) deleted, \(result.failed) failed")
            } catch {
                Logger.cloud.error("Push \(recordType) to cloud failed: \(error)")
                throw SyncError.syncFailed(reason: "Failed to sync \(recordType): \(error.localizedDescription)")
            }
        }

        return results
    }

    /// 后台同步失败后，延迟 30 秒尝试一次 `pushAllToCloud` 补偿。
    ///
    /// 多次调用会去抖动：取消前一次未执行的延迟任务，只保留最后一次。
    /// 如果补偿仍然失败，数据保留在本地（`isSynced = false`），
    /// 等待下次应用回前台或用户手动触发同步。
    nonisolated func scheduleDeferredPush() {
        deferredPushLock.withLock {
            deferredPushTask?.cancel()
            deferredPushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                guard let self, !Task.isCancelled else { return }
                guard self.syncConfiguration.isSyncEnabled else { return }
                Logger.sync.info("[SyncCoordinator] Executing deferred push after background sync failure...")
                _ = try? await self.pushAllToCloud()
            }
        }
    }

    /// 拉取所有订阅 Zone 的云端数据到本地
    func pullAllRecordFromCloud() async throws {
        guard syncConfiguration.isSyncEnabled else {
            Logger.sync.info("[SyncCoordinator] pullAllRecordFromCloud skipped (sync disabled)")
            return
        }
        
        Logger.sync.info("[SyncCoordinator] pullAllRecordFromCloud: \(self.subscriptionToConfigs.count) subscription(s) to process")
        
        for (subscriptionID, config) in subscriptionToConfigs {
            Logger.sync.info("[SyncCoordinator] Pulling records for subscription: \(subscriptionID), zone: \(config.zoneName)")
            try await pullRecords(of: subscriptionID)
        }
        
        Logger.sync.info("[SyncCoordinator] pullAllRecordFromCloud completed")
    }

    /// 拉取云端的变动数据到本地（响应 CloudKit 通知）
    ///
    /// **调用时机**：
    /// - 应用收到 CloudKit 的静默推送通知时
    /// - 通知包含 subscriptionID，指示哪个 Zone 有变更
    ///
    /// **执行流程**：
    /// 1. 从通知中提取 subscriptionID
    /// 2. 根据 subscriptionID 查找对应的 Zone 配置
    /// 3. 查询本地缓存的 Change Token（上次同步的位置）
    /// 4. 循环拉取 Zone 的增量变更（可能分多次）
    /// 5. 收集所有变更的记录和删除操作
    /// 6. 保存新的 Change Token
    /// 7. 根据 recordType 将数据分发到对应的 Store
    /// 8. 调用 Store 的 updateChanged 处理数据
    ///
    /// - Parameter notification: CloudKit 推送通知对象
    /// - Throws: CloudKit 网络错误或数据处理错误
    func pullRecords(with notification: CKNotification) async throws {
        guard let subscriptionID = notification.subscriptionID else {
            return
        }
        try await pullRecords(of: subscriptionID)
    }

    /// 处理远程推送通知（便捷方法）
    ///
    /// **使用示例**：
    /// ```swift
    /// func application(
    ///     _ application: UIApplication,
    ///     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    ///     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    /// ) {
    ///     Task {
    ///         try await coordinator.handleRemoteNotification(notification)
    ///         completionHandler(.newData)
    ///     }
    /// }
    /// ```
    func handleRemoteNotification(_ notification: CKNotification) async throws {
        try await pullRecords(with: notification)
    }

    /// 检查指定 Store 是否有未同步到 CloudKit 的数据
    ///
    /// 查询条件：`isSynced == false`，表示有本地修改尚未推送到云端。
    ///
    /// **使用示例**：
    /// ```swift
    /// let hasPending = try await coordinator.hasPendingChanges(for: ContactStore.self)
    /// if hasPending {
    ///     // 提示用户有未同步的数据
    /// }
    /// ```
    ///
    /// - Parameter storeType: 要检查的 Store 类型
    /// - Returns: `true` 表示有未同步数据，`false` 表示全部已同步
    func hasPendingChanges<T: SyncableStore>(for storeType: T.Type) async throws -> Bool {
        guard let store = store(for: storeType) else {
            return false
        }
        
        return try await store.hasPendingChanges()
    }

    /// 检查所有 Store 是否有未同步到 CloudKit 的数据
    ///
    /// - Returns: `true` 表示任意一个 Store 有未同步数据
    func hasAnyPendingChanges() async throws -> Bool {
        for (_, store) in stores {
            if try await store.hasPendingChanges() {
                return true
            }
        }
        
        return false
    }

    private func pullRecords(of subscriptionID: CKSubscription.ID) async throws {
        guard let config = subscriptionToConfigs[subscriptionID] else {
            Logger.sync.warning("[SyncCoordinator] No config found for subscription: \(subscriptionID)")
            return
        }

        // ========================================
        // 步骤1: 初始化拉取状态
        // ========================================
        var awaitingChanges: Bool = true
        var lastChangeToken = await db.queryCKServerChangeToken(for: subscriptionID)
        var newRecords: [CKRecord] = []
        var receivedDeletions: [CKDatabase.RecordZoneChange.Deletion] = []

        Logger.sync.info("[SyncCoordinator] pullRecords zone=\(config.zoneName), hasToken=\(lastChangeToken != nil)")

        // ========================================
        // 步骤2: 循环拉取所有变更数据
        // ========================================
        while awaitingChanges {
            /// 从 CloudKit 拉取 Zone 的变更数据
            /// - since: 从哪个 Token 开始拉取（nil 表示全量拉取）
            let changes = try await cloud.privateDB.recordZoneChanges(inZoneWith: config.zoneID, since: lastChangeToken)

            // 提取成功的记录（过滤失败的）
            let changedRecords = changes.modificationResultsByID.compactMapValues {
                try? $0.get().record
            }

            // 收集本次拉取的数据
            newRecords.append(contentsOf: changedRecords.values)
            receivedDeletions.append(contentsOf: changes.deletions)

            // 更新状态
            lastChangeToken = changes.changeToken
            awaitingChanges = changes.moreComing

            Logger.sync.info("[SyncCoordinator] Batch fetched \(changedRecords.count) records, \(changes.deletions.count) deletions, moreComing=\(changes.moreComing)")
        }

        Logger.sync.info("[SyncCoordinator] Pull complete for zone=\(config.zoneName): total \(newRecords.count) records, \(receivedDeletions.count) deletions")

        // ========================================
        // 步骤3: 保存新的 Change Token
        // ========================================
        if let lastChangeToken {
            await db.cacheCKServerChangeToken(lastChangeToken, for: subscriptionID)
        }

        // ========================================
        // 步骤4: 按 recordType 分组数据
        // ========================================
        let newRecordsMap = Dictionary(grouping: newRecords, by: { $0.recordType })
        let deletionsMap = Dictionary(grouping: receivedDeletions, by: { $0.recordType })

        // 合并所有涉及的 recordType（去重）
        let recordTypes = Set(Array(newRecordsMap.keys) + Array(deletionsMap.keys))

        Logger.sync.info("[SyncCoordinator] Distributing to \(recordTypes.count) record type(s): \(recordTypes.joined(separator: ", "))")

        // ========================================
        // 步骤5: 分发数据到对应的 Store
        // ========================================
        for recordType in recordTypes {
            if let store = stores[recordType] {
                let records = newRecordsMap[recordType] ?? []
                let deletions = deletionsMap[recordType] ?? []

                Logger.sync.info("[SyncCoordinator] Distributing to \(recordType): \(records.count) records, \(deletions.count) deletions")

                // 调用 Store 的更新方法，处理数据
                try await store.updateChanged(records: records, deletions: deletions)
            } else {
                Logger.sync.warning("[SyncCoordinator] No store found for recordType: \(recordType)")
            }
        }
    }
}

public extension SyncCoordinator {
    enum Res {
        case completed
        case pullFailed(_ error: Error)
        case pushFailed(_ error: Error)
        case bothFailed(_ pullError: Error, _ pushError: Error)
    }
    
    /// 同步数据，将本数据同步到云端，将云端数据同步到本地
    @discardableResult
    func sync() async throws -> Res {
        var pullError: Error?
        var pushError: Error?
        
        do {
            /// 先拉取云端的数据变动
            try await pullAllRecordFromCloud()
        } catch {
            pullError = error
        }
        
        do {
            /// 然后推送本地数据到云端
            _ = try await pushAllToCloud()
        } catch {
            pushError = error
        }
        
        if let pullError {
            if let pushError {
                return .bothFailed(pullError, pushError)
            }
            
            return .pullFailed(pullError)
        }
        
        if let pushError {
            return .pushFailed(pushError)
        }
        
        return .completed
    }
}
