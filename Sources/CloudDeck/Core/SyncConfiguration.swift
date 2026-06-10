//
//  SyncConfiguration.swift
//  CloudDeck
//

import Foundation
import os
import CloudKit

/// CloudKit 同步配置
///
/// 控制同步行为的运行时配置项，可以在应用运行期间动态修改。
///
/// **使用示例**：
/// ```swift
/// // 关闭同步（离线模式）
/// coordinator.syncConfiguration.isSyncEnabled = false
///
/// // 开启后台同步模式（CRUD 操作不等待云端完成）
/// coordinator.syncConfiguration.performSyncInBackground = true
/// ```
public final class SyncConfiguration: Sendable {
    private let _isSyncEnabled: OSAllocatedUnfairLock<Bool>
    private let _performSyncInBackground: OSAllocatedUnfairLock<Bool>
    private let _isCloudReady: OSAllocatedUnfairLock<Bool>

    /// 是否启用 CloudKit 同步
    ///
    /// - `true`（默认）：CRUD 操作会同步到 CloudKit
    /// - `false`：CRUD 操作只写入本地数据库，数据标记为 `isSynced = false`
    ///
    /// **关闭同步后的行为**：
    /// - `save` / `delete` 只操作本地数据库
    /// - `pushToCloud` / `pullLatestChanges` 会立即返回（不执行）
    /// - 数据会标记为未同步，重新开启后可通过 `pushAllToCloud()` 补同步
    ///
    /// **使用场景**：
    /// - 用户设置中提供「关闭同步」选项
    /// - 离线模式 / 省流量模式
    /// - 调试本地逻辑时临时关闭
    public var isSyncEnabled: Bool {
        get { _isSyncEnabled.withLock { $0 } }
        set { _isSyncEnabled.withLock { $0 = newValue } }
    }

    /// Whether CloudKit zones are ready for operations.
    /// Set to `true` by SyncCoordinator after `setup()` succeeds.
    /// When `false`, all CRUD operations skip cloud writes and save locally only.
    public var isCloudReady: Bool {
        get { _isCloudReady.withLock { $0 } }
        set { _isCloudReady.withLock { $0 = newValue } }
    }

    /// 是否将云端同步操作放到后台执行
    ///
    /// - `true`：CRUD 操作中的 CloudKit 部分使用 `Task { }` 在后台执行，
    ///   本地数据库写入完成后立即返回，不等待云端结果
    /// - `false`（默认）：CRUD 操作等待云端同步完成后再返回（Cloud-First 策略）
    ///
    /// **开启后台同步后的行为**：
    /// ```swift
    /// await store.save(model)        // 立即返回（只等本地写入）
    /// // 云端同步在后台自动执行：
    /// // Task {
    /// //     await uploadToCloudKit()
    /// // }
    /// ```
    ///
    /// **注意事项**：
    /// - 开启后，save/delete 返回时数据可能尚未同步到云端
    /// - 数据先以 `isSynced = false` 写入本地，后台成功后更新为 `true`
    /// - 适合对响应速度敏感的 UI 场景（如列表快速编辑）
    public var performSyncInBackground: Bool {
        get { _performSyncInBackground.withLock { $0 } }
        set { _performSyncInBackground.withLock { $0 = newValue } }
    }

    /// CloudKit 保存策略（仅初始化时生效）
    ///
    /// 该值在 `SyncCoordinator` 初始化时传入 `CloudKitManager`。
    /// 运行期间修改同步开关时不应改变此策略。
    public let policy: CloudSavingPolicy

    public init(
        isSyncEnabled: Bool = true,
        performSyncInBackground: Bool = false,
        policy: CloudSavingPolicy = .changedKeys
    ) {
        self._isSyncEnabled = OSAllocatedUnfairLock(initialState: isSyncEnabled)
        self._performSyncInBackground = OSAllocatedUnfairLock(initialState: performSyncInBackground)
        self._isCloudReady = OSAllocatedUnfairLock(initialState: false)
        self.policy = policy
    }
}
