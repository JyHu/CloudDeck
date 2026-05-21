//
//  Definitions.swift
//  CloudDeck
//

import CloudKit

/// Type alias for CloudKit record type strings (e.g., "Contact", "Event")
public typealias CKRecordType = String

/// CloudKit modify results tuple
public typealias CKModifyResults = (saveResults: [CKRecord.ID: Result<CKRecord, any Error>], deleteResults: [CKRecord.ID: Result<Void, any Error>])

/// CloudKit Zone name type alias
public extension CKRecordZone {
    typealias Name = String
}
