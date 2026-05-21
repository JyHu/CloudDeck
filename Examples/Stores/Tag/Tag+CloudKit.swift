//
//  Tag+CloudKit.swift
//  CloudDeck Example
//
//  CloudKit 序列化：CKRecord ←→ Tag
//

import CloudKit
import CloudDeck

public extension Tag {
    init(record: CKRecord) throws {
        self.isSynced = true
        self.id = record.recordID.recordName
        self.createAt = record.creationDate ?? Date()
        self.updateAt = record.modificationDate ?? Date()
        self.name = record["name"] as? String ?? ""
        self.color = record["color"] as? String
    }

    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: id, zoneID: zoneID)
        )
        record["name"] = name
        record["color"] = color
        record["updateAt"] = updateAt
        return record
    }
}
