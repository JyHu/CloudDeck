//
//  CloudKitSyncable.swift
//  CloudDeck
//

import CloudKit

public protocol CloudKitSyncable {
    /// 从 CloudKit Record 创建模型实例
    ///
    /// **调用时机**：
    /// - 从云端拉取数据后，需要转换为本地模型
    /// - 在 updateChanged() 方法中批量创建模型
    ///
    /// **重要**：
    /// - 必须从 record.creationDate 和 record.modificationDate 读取时间
    /// - 这两个时间是服务器时间，是冲突解决的基准
    /// - 不要使用本地设备时间（Date()），会导致时间不一致
    ///
    /// **实现建议**：
    /// ```swift
    /// init(record: CKRecord) throws {
    ///     self.id = record.recordID.recordName
    ///     self.createAt = record.creationDate ?? Date()
    ///     self.updateAt = record.modificationDate ?? Date()  // 关键：使用服务器时间
    ///     self.isDeleted = false
    ///     self.isSynced = true  // 来自云端的数据默认已同步
    ///     // ... 解析其他业务字段
    /// }
    /// ```
    ///
    /// - Parameter record: CloudKit Record 对象
    /// - Throws: 数据解析错误（字段缺失或类型不匹配）
    init(record: CKRecord) throws
    
    /// 转换为 CloudKit Record 对象
    ///
    /// **调用时机**：
    /// - 推送本地数据到云端时（performPush 方法）
    /// - 将本地模型序列化为 CloudKit 可以理解的格式
    ///
    /// **实现要点**：
    /// 1. 使用 model.id 作为 recordName，确保本地和云端 ID 一致
    /// 2. 不要保存 createAt（CloudKit 会自动设置 creationDate）
    /// 3. 必须保存 updateAt（用于冲突检测，字段名建议也叫 "updateAt"）
    /// 4. 不要保存 isDeleted 和 isSynced（这是本地状态，云端不需要）
    ///
    /// **实现示例**：
    /// ```swift
    /// func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    ///     let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
    ///     let record = CKRecord(recordType: "Contact", recordID: recordID)
    ///
    ///     // 保存业务字段
    ///     record["name"] = name
    ///     record["phone"] = phone
    ///
    ///     // 保存 updateAt（关键：用于冲突检测）
    ///     record["updateAt"] = updateAt
    ///
    ///     return record
    /// }
    /// ```
    ///
    /// - Parameter zoneID: 目标 Zone ID（数据将保存到这个 Zone）
    /// - Returns: CloudKit Record 对象
    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord
    
    /// 当前表所在的Zone
    static var zoneName: CKRecordZone.Name { get }
    
    /// 表的名称，对应CloudKit远端的ReordType
    static var recordType: CKRecordType { get }
}

public extension CloudKitSyncable {
    /// 当前表所在的Zone
    static var zoneName: CKRecordZone.Name {
        CKRecordZone.ID.defaultZoneName
    }
}
