//
//  CloudKitManager.swift
//  CloudDeck
//

import CloudKit
import OSLog


/// CloudKit 管理类，封装所有与 iCloud 云端数据交互的功能
///
/// **职责**：
/// - 管理 CloudKit Container 和 Private Database 的访问
/// - 提供原子性 CloudKit 操作（保存、删除、查询）
/// - 作为所有 Store 访问 CloudKit 的统一入口
///
/// **为什么使用 Actor**：
/// - CloudKit API 是异步的，需要确保线程安全
/// - Actor 自动隔离状态，避免数据竞争
/// - 所有方法自动变为 async，符合 CloudKit 的异步特性
///
/// **使用场景**：
/// ```swift
/// let cloud = CloudKitManager(containerID: "iCloud.com.example.app")
/// let (saved, deleted) = try await cloud.modify(
///     saving: [record1, record2],
///     deleting: [recordID1]
/// )
/// ```
// @unchecked Sendable: All stored properties are immutable (`let`), no mutable state exists.
public class CloudKitManager: @unchecked Sendable {
    /// CloudKit Container，代表应用的 iCloud 容器
    /// 包含所有 Zone、Subscription、Record 等资源
    public let container: CKContainer
    
    /// Private Database，用户私有数据库
    /// 每个用户有独立的私有数据库，数据不会在用户之间共享
    /// 相对于 Shared Database（共享）和 Public Database（公开）
    public let privateDB: CKDatabase
    
    /// 数据保存策略
    public let policy: CloudSavingPolicy
    
    /// 初始化 CloudKit 管理器
    /// - Parameter containerID: iCloud Container 标识符
    ///   格式："iCloud.com.yourcompany.yourapp"
    ///   需要在 Xcode Capabilities 中配置 iCloud 并创建对应的 Container
    public init(containerID: String, policy: CloudSavingPolicy = .changedKeys) {
        self.container = CKContainer(identifier: containerID)
        self.privateDB = container.privateCloudDatabase
        self.policy = policy
    }
    
    /// 使用默认 Container 初始化（使用 entitlements 中声明的第一个 container）
    public init(policy: CloudSavingPolicy = .changedKeys) {
        self.container = CKContainer.default()
        self.privateDB = container.privateCloudDatabase
        self.policy = policy
    }
}

public extension CloudKitManager {
    /// 批量修改 CloudKit 记录（保存和删除）
    ///
    /// 这是 CloudKit 的核心操作，支持在一个请求中同时保存和删除多条记录。
    ///
    /// **关键参数**：
    /// - `savePolicy: .changedKeys`
    ///   只上传本地修改过的字段，服务器端未修改的字段保持不变。
    ///   如果记录不存在则创建，已存在则更新（upsert 语义）。
    ///   适合个人数据同步场景，模型不存储 CKRecord 系统字段（recordChangeTag）。
    ///
    /// - `atomically: false`
    ///   非原子性操作：部分记录成功，部分记录失败是允许的
    ///   每条记录的结果独立返回，失败的记录不影响成功的记录
    ///   如果设为 true，则要么全部成功，要么全部失败
    ///
    /// **返回值**：
    /// - `saveResults`: 每条保存记录的结果（成功或失败）
    /// - `deleteResults`: 每条删除记录的结果（成功或失败）
    ///
    /// **错误处理**：
    /// ```swift
    /// for (recordID, result) in saveResults {
    ///     switch result {
    ///     case .success(let record):
    ///         // 保存成功，record 包含服务器返回的最新数据
    ///     case .failure(let error):
    ///         // 保存失败，根据 error 类型决定如何处理
    ///         // CKError.networkUnavailable: 网络问题，可以重试
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - saving: 要保存的记录列表（新增或更新）
    ///   - deleting: 要删除的记录 ID 列表
    /// - Returns: 保存和删除操作的结果字典
    /// - Throws: CloudKit 网络错误或权限错误
    func modify(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> CKModifyResults {
        try await privateDB.modifyRecords(
            saving: saving,
            deleting: deleting,
            savePolicy: policy.ckpolicy,
            atomically: false
        )
    }
}
