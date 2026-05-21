//
//  TaskTag+CloudKit.swift
//  CloudDeck Example
//
//  CloudKit 序列化：CKRecord ←→ TaskTag
//

import CloudKit
import CloudDeck

public extension TaskTag {
    init(record: CKRecord) throws {
        self.isSynced = true
        self.id = record.recordID.recordName
        self.createAt = record.creationDate ?? Date()
        self.updateAt = record.modificationDate ?? Date()
        self.taskID = record["taskID"] as? String ?? ""
        self.tagID = record["tagID"] as? String ?? ""
    }

    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: id, zoneID: zoneID)
        )
        record["taskID"] = taskID
        record["tagID"] = tagID
        record["updateAt"] = updateAt
        return record
    }
}
