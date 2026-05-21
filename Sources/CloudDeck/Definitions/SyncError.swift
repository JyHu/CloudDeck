//
//  SyncError.swift
//  CloudDeck
//

import Foundation
import CloudKit

/// Unified error type for the CloudDeck framework.
public enum SyncError: Error, LocalizedError {
    case modelNotFound(id: String)
    case syncFailed(reason: String)
    case cloudKitError(CKError)
    case databaseError(Error)
    case invalidData(reason: String)
    case configurationError(reason: String)
    case conflictError(reason: String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let id):
            return "Model with id '\(id)' not found"
        case .syncFailed(let reason):
            return "Sync failed: \(reason)"
        case .cloudKitError(let error):
            return "CloudKit error: \(error.localizedDescription)"
        case .databaseError(let error):
            return "Database error: \(error.localizedDescription)"
        case .invalidData(let reason):
            return "Invalid data: \(reason)"
        case .configurationError(let reason):
            return "Configuration error: \(reason)"
        case .conflictError(let reason):
            return "Data conflict: \(reason)"
        }
    }
}
