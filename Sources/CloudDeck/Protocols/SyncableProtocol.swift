//
//  SyncableProtocol.swift
//  CloudDeck
//

import Foundation
import GRDB
import CloudKit

public enum SyncableError: Error {
    case propertyLost(_ propertyName: String)
}

/// 可同步数据模型协议，定义所有需要在本地和云端同步的数据模型的基本要求
///
/// **设计理念**：
/// - 所有可同步的数据模型都必须遵守这个协议
/// - 通过协议统一管理同步状态和转换逻辑
/// - 支持本地存储（GRDB）和云端存储（CloudKit）的双向转换
///
/// **必需字段**：
/// - id: 唯一标识符（本地和云端共用，用于关联同一条数据）
/// - createAt: 创建时间（与 CloudKit 的 creationDate 同步）
/// - updateAt: 更新时间（与 CloudKit 的 modificationDate 同步，用于冲突解决）
/// - isDeleted: 删除标记（软删除，等待同步到云端后再物理删除）
/// - isSynced: 同步状态（false 表示有未同步的修改）
///
/// **协议组合**：
/// - FetchableRecord: 支持从 GRDB 数据库查询
/// - PersistableRecord: 支持保存到 GRDB 数据库
/// - Sendable: 支持在并发环境中安全传递（Actor 隔离）
/// - Codable: 支持序列化和反序列化（用于存储和网络传输）
///
/// **使用示例**：
/// ```swift
/// struct Contact: SyncableModel {
///     var id: String
///     var name: String
///     var createAt: Date
///     var updateAt: Date
///     var isDeleted: Bool
///     var isSynced: Bool
///     
///     init(record: CKRecord) throws {
///         self.id = record.recordID.recordName
///         self.name = record["name"] as? String ?? ""
///         self.createAt = record.creationDate ?? Date()
///         self.updateAt = record.modificationDate ?? Date()
///         self.isDeleted = false
///         self.isSynced = true
///     }
///     
///     func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
///         let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
///         let record = CKRecord(recordType: "Contact", recordID: recordID)
///         record["name"] = name
///         record["updateAt"] = updateAt
///         return record
///     }
/// }
/// ```
public protocol SyncableProtocol: GRDBSyncableProtocol, CloudKitSyncable {

    /// 数据的唯一标识符
    ///
    /// **要求**：
    /// - 在本地数据库中必须是主键（Primary Key）
    /// - 与 CloudKit Record 的 recordName 一致
    /// - 通常使用 UUID 字符串，确保全局唯一
    ///
    /// **用途**：
    /// - 关联本地和云端的同一条数据
    /// - 冲突解决时识别是同一条数据的不同版本
    /// - 查询和更新操作的唯一依据
    var id: String { get }
    
    /// 数据创建时间
    ///
    /// **同步规则**：
    /// - 本地创建时：使用本地设备时间
    /// - 首次推送成功后：使用 CloudKit 返回的 creationDate（服务器时间）
    /// - 从云端拉取时：使用 record.creationDate
    ///
    /// **用途**：
    /// - 显示数据的创建时间
    /// - 按创建时间排序
    /// - 不参与冲突解决（只有 updateAt 用于冲突解决）
    var createAt: Date { get set }
    
    /// 数据最后修改时间（冲突解决的关键字段）
    ///
    /// **同步规则**：
    /// - 本地修改时：使用本地设备时间（临时的）
    /// - 推送成功后：使用 CloudKit 返回的 modificationDate（服务器时间）
    /// - 从云端拉取时：使用 record.modificationDate
    ///
    /// **冲突解决中的作用**：
    /// - 比较本地 updateAt 和云端 modificationDate
    /// - 只有当 isSynced=true 时，updateAt 才是可信的服务器时间
    /// - Last-Write-Wins：时间更新的版本胜出
    ///
    /// **为什么需要服务器时间**：
    /// - 不同设备的本地时间可能不准确（用户手动修改、时区差异）
    /// - 使用统一的服务器时间才能正确比较先后顺序
    var updateAt: Date { get set }
    
    /// 是否被标记为删除（软删除标记）
    ///
    /// **删除流程**：
    /// 1. 用户删除数据 → 设置 isDeleted=true, isSynced=false
    /// 2. 下次同步时推送到云端 → 云端删除
    /// 3. 云端删除成功后 → 本地物理删除
    ///
    /// **为什么需要软删除**：
    /// - 删除操作需要同步到云端，不能立即物理删除
    /// - 如果推送失败，下次仍然可以重试
    /// - 在冲突解决中，本地删除的优先级最高（保护用户意图）
    ///
    /// **冲突规则**：
    /// - 如果本地 isDeleted=true，拒绝所有远端更新
    /// - 即使远端数据更新，也保护用户的删除意图
    var isDeleted: Bool { get set }
    
    /// 是否已同步到云端（同步状态标记）
    ///
    /// **状态含义**：
    /// - true: 本地数据与云端一致，没有未同步的修改
    /// - false: 本地有修改（创建、更新、删除），需要推送到云端
    ///
    /// **状态变化**：
    /// - 用户创建/修改/删除数据 → 设为 false
    /// - 推送到云端成功 → 设为 true
    /// - 从云端拉取数据 → 设为 true
    ///
    /// **在冲突解决中的作用**：
    /// - isSynced=false: 优先级最高，拒绝所有远端更新
    /// - isSynced=true: 可以根据 updateAt 比较，接受更新的版本
    ///
    /// **为什么 isSynced=false 优先级最高**：
    /// - 代表用户正在编辑或刚修改过
    /// - 保护用户当前的工作，不能被远端数据覆盖
    /// - 用户完成编辑并推送后，再同步远端数据
    var isSynced: Bool { get set }
}

// MARK: - 默认实现（便捷方法）
public extension SyncableProtocol {
    /// 标记数据为已删除（软删除）
    ///
    /// **操作**：
    /// - 设置 isDeleted = true（标记为删除）
    /// - 设置 isSynced = false（需要同步到云端）
    /// - 更新 updateAt（记录删除时间）
    ///
    /// **使用场景**：
    /// ```swift
    /// var contact = try await store.fetch(id: "123")
    /// contact.markDeleted()
    /// try await store.save(contact)
    /// // 下次同步时会推送删除操作到云端
    /// ```
    ///
    /// **注意**：
    /// - 这只是标记，数据仍然在本地数据库中
    /// - 推送到云端成功后，才会物理删除
    mutating func markDeleted() {
        self.isDeleted = true
        self.isSynced = false
        self.updateAt = Date()
    }
    
    /// 标记数据为已同步
    ///
    /// **操作**：
    /// - 设置 isSynced = true（与云端一致）
    ///
    /// **调用时机**：
    /// - 推送到云端成功后自动调用
    /// - 从云端拉取数据时自动调用
    ///
    /// **注意**：
    /// - 通常不需要手动调用，框架会自动管理
    mutating func markSynced() {
        self.isSynced = true
    }
    
    /// 标记数据为已修改（未同步）
    ///
    /// **操作**：
    /// - 设置 isSynced = false（需要同步）
    /// - 更新 updateAt（记录修改时间）
    ///
    /// **使用场景**：
    /// ```swift
    /// var contact = try await store.fetch(id: "123")
    /// contact.name = "New Name"
    /// contact.markModified()
    /// try await store.save(contact)
    /// // 下次同步时会推送修改到云端
    /// ```
    ///
    /// **注意**：
    /// - 每次修改数据后都应该调用
    /// - 确保修改会被同步到云端
    mutating func markModified() {
        self.isSynced = false
        self.updateAt = Date()
    }
}

extension SyncableProtocol {
    static var zoneID: CKRecordZone.ID {
        return CKRecordZone.ID(zoneName: self.zoneName)
    }
    
    static func recordID(with recordName: String) -> CKRecord.ID {
        return CKRecord.ID(recordName: recordName, zoneID: self.zoneID)
    }
    
    var zoneID: CKRecordZone.ID {
        return Self.zoneID
    }
    
    func recordID() -> CKRecord.ID {
        return CKRecord.ID(recordName: self.id, zoneID: self.zoneID)
    }
}
