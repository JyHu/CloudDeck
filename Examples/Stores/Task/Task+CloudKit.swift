//
//  Task+CloudKit.swift
//  CloudDeck Example
//
//  CloudKit 序列化：CKRecord ←→ Task
//

import CloudKit
import CloudDeck

public extension Task {
    init(record: CKRecord) throws {
        self.isSynced = true

        self.id = record.recordID.recordName
        self.createAt = record.creationDate ?? Date()
        self.updateAt = record.modificationDate ?? Date()   // 关键：使用服务器时间

        self.title = record["title"] as? String ?? ""
        self.note = record["note"] as? String
        self.isCompleted = record["isCompleted"] as? Bool ?? false
        self.dueDate = record["dueDate"] as? Date

        if let raw = record["priority"] as? String {
            self.priority = Priority(rawValue: raw) ?? .medium
        }

        // 注意：tags 不从 Task Record 读取，而是通过 TaskTag 关联表同步
    }

    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: self.id, zoneID: zoneID)
        )

        record["title"] = title
        record["note"] = note
        record["isCompleted"] = isCompleted
        record["priority"] = priority.rawValue
        record["dueDate"] = dueDate
        record["updateAt"] = updateAt   // 必须：用于冲突检测

        // 不要保存 createAt（CloudKit 自动管理 creationDate）
        // 不要保存 isDeleted / isSynced（本地状态字段）
        // 不要保存 tags（通过关联表管理）

        return record
    }
}
