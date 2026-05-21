//
//  GRDBStoreProtocol.swift
//  CloudDeck
//

import GRDB
import CloudKit

/// GRDB database protocol for dependency injection and testing.
public protocol GRDBStoreProtocol {
    var queue: DatabaseQueue { get }
    func cacheCKServerChangeToken(_ token: CKServerChangeToken, for subscriptionID: String) async
    func queryCKServerChangeToken(for subscriptionID: String) async -> CKServerChangeToken?
}

extension GRDBStore: GRDBStoreProtocol {}
