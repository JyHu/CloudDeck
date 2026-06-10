//
//  CloudKitProtocol.swift
//  CloudDeck
//

import CloudKit

/// CloudKit operations protocol for dependency injection and testing.
public protocol CloudKitProtocol {
    var policy: CloudSavingPolicy { get }
    func modify(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> CKModifyResults
}

extension CloudKitManager: CloudKitProtocol {}
