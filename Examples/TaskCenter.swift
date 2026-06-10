//
//  TaskCenter.swift
//  CloudDeck Example
//
//  业务层入口（类似 FamCenter），协调所有 Store 的初始化和访问。
//  参照 Famline 项目中 FamCenter.swift 的设计模式。
//

import Foundation
import CloudDeck
import Combine

/// 任务管理中心 - 业务层单例
///
/// 设计模式说明：
/// - 采用单例模式，作为所有 Store 的统一入口
/// - 持有 SyncCoordinator，管理同步引擎
/// - 对外暴露各个 Store，供 ViewModel 使用
///
/// 架构层次：
/// ```
/// View / ViewModel
///     ↓ 访问
/// TaskCenter（本文件）
///     ├── taskStore      → TaskStore
///     ├── tagStore       → TagStore
///     ├── taskTagStore   → TaskTagStore
///     └── coordinator    → SyncCoordinator
///         ├── db (GRDBStore)
///         └── cloud (CloudKitManager)
/// ```
@MainActor
public class TaskCenter {
    public static let shared = TaskCenter()

    // MARK: - 核心引擎

    public let coordinator: SyncCoordinator

    // MARK: - 各个 Store（对外暴露，供 ViewModel 直接使用）

    public let taskStore: TaskStore
    public let tagStore: TagStore
    public let taskTagStore: TaskTagStore

    // MARK: - 初始化

    private init() {
        // 1. 确定数据库路径
        let dbPath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("taskapp.sqlite").path

        // 2. 初始化协调器（同步创建 CloudKit Manager 和 GRDB Store）
        coordinator = try! SyncCoordinator(
            databasePath: dbPath,
            containerID: "iCloud.com.example.taskapp"
        )

        // 3. 创建各个 Store（共享 db、cloud 和 syncConfiguration 实例）
        taskStore = TaskStore(db: coordinator.db, cloud: coordinator.cloud, syncConfiguration: coordinator.syncConfiguration)
        tagStore = TagStore(db: coordinator.db, cloud: coordinator.cloud, syncConfiguration: coordinator.syncConfiguration)
        taskTagStore = TaskTagStore(db: coordinator.db, cloud: coordinator.cloud, syncConfiguration: coordinator.syncConfiguration)

        // 4. 注册所有 Store 并执行数据库迁移（同步操作）
        //    这一步确保所有表在任何查询之前就已创建
        try! coordinator.registerStoresAndMigrate([
            taskStore,
            tagStore,
            taskTagStore
        ])
    }

    // MARK: - 异步初始化（应用启动后调用）

    /// 完成 CloudKit 初始化（创建 Zone 和 Subscription）
    ///
    /// 调用时机：应用启动后尽快调用
    /// ```swift
    /// // 在 App.init 或 AppDelegate 中
    /// Task {
    ///     await TaskCenter.shared.setup()
    /// }
    /// ```
    public func setup() async {
        do {
            try await coordinator.setup(with: [])
            // 首次拉取云端数据
            try await coordinator.pullAllRecordFromCloud()
        } catch {
            print("[TaskCenter] Setup failed: \(error)")
        }
    }

    // MARK: - 便捷同步方法

    /// 全量推送（用户手动点击同步按钮时调用）
    @discardableResult
    public func syncAll() async throws -> [CKRecordType: SyncResult] {
        try await coordinator.pushAllToCloud()
    }
}
