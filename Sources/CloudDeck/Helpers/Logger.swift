//
//  Logger.swift
//  CloudDeck
//

import OSLog

/// Logger categories for CloudDeck framework.
///
/// Usage:
/// ```swift
/// Logger.cloud.info("Fetching changes from CloudKit")
/// Logger.grdb.debug("Saving records to database")
/// Logger.sync.error("Sync failed: \(error)")
/// ```
public extension Logger {
    /// CloudKit operations (network, zones, subscriptions)
    static let cloud = Logger(subsystem: "com.auu.cloudDeck", category: "CloudKit")

    /// Local database operations (SQLite read/write, migrations)
    static let grdb = Logger(subsystem: "com.auu.cloudDeck", category: "GRDB")

    /// Sync logic (Pull-Merge-Push, conflict resolution)
    static let sync = Logger(subsystem: "com.auu.cloudDeck", category: "Sync")
}
