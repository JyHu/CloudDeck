//
//  CloudSavingPolicy.swift
//  CloudDeck
//
//  Created by hujinyou on 2026/6/9.
//

import CloudKit
import Foundation

public enum CloudSavingPolicy: String, Identifiable, Sendable {
    case ifServerRecordUnchanged
    case changedKeys
    case allKeys
    
    public var id: String { rawValue }
    
    public var ckpolicy: CKModifyRecordsOperation.RecordSavePolicy {
        switch self {
        case .ifServerRecordUnchanged: .ifServerRecordUnchanged
        case .changedKeys: .changedKeys
        case .allKeys: .allKeys
        }
    }
}
