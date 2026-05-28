//
//  DebugDBModels.swift
//  CloudDeck
//
//  Shared data models for the database debug views.
//

import Foundation

// MARK: - Table Info

struct DebugTableInfo: Identifiable, Sendable {
    let id: String // table name
    var rowCount: Int
    var unsyncedCount: Int
    var deletedCount: Int
    var hasSyncColumns: Bool
}

// MARK: - Column Info

struct DebugColumnInfo: Identifiable, Sendable {
    let id: Int // cid
    let name: String
    let type: String
    let notNull: Bool
    let defaultValue: String?
    let isPrimaryKey: Bool
}

// MARK: - Index Info

struct DebugIndexInfo: Identifiable, Sendable {
    let id: String // index name
    let tableName: String
    let isUnique: Bool
    let columns: [String]
}

// MARK: - DB File Info

struct DebugDBFileInfo: Sendable {
    let path: String
    let fileSize: Int64
    let sqliteVersion: String
    let journalMode: String
    let pageSize: Int
    let pageCount: Int
    let walMode: Bool
}

// MARK: - Migration Info

struct DebugMigrationInfo: Identifiable, Sendable {
    let id: String // identifier
    let identifier: String
}

// MARK: - SQL Result

enum DebugSQLResult: Sendable {
    case select(columns: [String], rows: [[String: String]])
    case write(affectedRows: Int)
    case error(String)
}
