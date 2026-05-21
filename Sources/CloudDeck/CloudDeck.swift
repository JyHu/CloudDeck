/// CloudDeck - A Pull-Merge-Push sync framework for CloudKit + GRDB
///
/// CloudDeck provides a robust, offline-first synchronization engine that keeps
/// local SQLite data (via GRDB) in sync with Apple's CloudKit private database.
///
/// Architecture:
/// ```
/// App Layer (Your Models & Stores)
///     ↓
/// SyncCoordinator (Orchestrator)
///     ├── GRDBStore (Local SQLite via GRDB)
///     ├── CloudKitManager (iCloud Private DB)
///     └── SyncableStore (Per-model CRUD + Sync)
/// ```
///
/// Key Features:
/// - **Offline-first**: Data is always written locally first
/// - **Cloud-first CRUD**: Save/delete attempts cloud first, falls back to local
/// - **Pull-Merge-Push**: Conflict resolution without data loss
/// - **Last-Write-Wins**: Server timestamps for reliable ordering
/// - **Soft delete**: Safe deletion with cloud sync
/// - **Incremental sync**: Change tokens for efficient polling
/// - **Silent push**: Background sync via CloudKit subscriptions

@_exported import GRDB
