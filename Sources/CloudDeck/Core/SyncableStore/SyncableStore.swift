//
//  SyncableStore.swift
//  CloudDeck
//

import GRDB
import CloudKit
import OSLog

/// Protocol for per-model stores that handle CRUD and sync operations.
///
/// Each data model type gets its own store conforming to this protocol.
/// The store manages both local persistence and cloud synchronization.
///
/// Usage:
/// ```swift
/// final class ContactStore: SyncableStore {
///     typealias ModelType = Contact
///     let db: GRDBStore
///     let cloud: CloudKitManager
///     let syncConfiguration: SyncConfiguration
///
///     init(db: GRDBStore, cloud: CloudKitManager, syncConfiguration: SyncConfiguration) {
///         self.db = db
///         self.cloud = cloud
///         self.syncConfiguration = syncConfiguration
///     }
///
///     func registerMigrations(_ migrator: inout DatabaseMigrator) {
///         migrator.registerMigration("contacts_v1") { db in
///             try db.create(table: "contact") { t in
///                 t.primaryKey("id", .text)
///                 t.column("name", .text).notNull()
///                 t.column("createAt", .datetime).notNull()
///                 t.column("updateAt", .datetime).notNull()
///                 t.column("isDeleted", .boolean).notNull().defaults(to: false)
///                 t.column("isSynced", .boolean).notNull().defaults(to: false)
///             }
///         }
///     }
/// }
/// ```
public protocol SyncableStore: Sendable {
    associatedtype ModelType: SyncableProtocol

    var db: GRDBStore { get }
    var cloud: CloudKitManager { get }
    var syncConfiguration: SyncConfiguration { get }

    init(db: GRDBStore, cloud: CloudKitManager, syncConfiguration: SyncConfiguration)

    /// Register database table creation/migration logic.
    func registerMigrations(_ migrator: inout DatabaseMigrator)
}

public extension SyncableStore {
    var zoneName: CKRecordZone.Name {
        ModelType.zoneName
    }

    var recordType: CKRecordType {
        ModelType.recordType
    }
}
