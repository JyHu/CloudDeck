//
//  DebugDBDataSource.swift
//  CloudDeck
//
//  Centralized data loading logic for all database debug queries.
//

import Foundation
import GRDB

@MainActor
final class DebugDBDataSource: Sendable {
    let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Tables

    func fetchTables() async -> [DebugTableInfo] {
        do {
            return try await dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master
                    WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                    ORDER BY name
                """)
                var infos: [DebugTableInfo] = []
                for row in rows {
                    let name: String = row["name"]
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(name)\"") ?? 0

                    // Check if table has sync columns
                    let colRows = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(name)\")")
                    let colNames = colRows.map { $0["name"] as String }
                    let hasSynced = colNames.contains("isSynced") || colNames.contains("is_synced")
                    let hasDeleted = colNames.contains("isDeleted") || colNames.contains("is_deleted")
                    let hasSyncColumns = hasSynced || hasDeleted

                    var unsynced = 0
                    var deleted = 0
                    if hasSynced {
                        let col = colNames.contains("isSynced") ? "isSynced" : "is_synced"
                        unsynced = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(name)\" WHERE \"\(col)\" = 0") ?? 0
                    }
                    if hasDeleted {
                        let col = colNames.contains("isDeleted") ? "isDeleted" : "is_deleted"
                        deleted = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(name)\" WHERE \"\(col)\" = 1") ?? 0
                    }

                    infos.append(DebugTableInfo(
                        id: name,
                        rowCount: count,
                        unsyncedCount: unsynced,
                        deletedCount: deleted,
                        hasSyncColumns: hasSyncColumns
                    ))
                }
                return infos
            }
        } catch {
            print("DebugDBDataSource fetchTables error: \(error)")
            return []
        }
    }

    // MARK: - Schema

    func fetchColumns(table: String) async -> [DebugColumnInfo] {
        do {
            return try await dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
                return rows.map { row in
                    DebugColumnInfo(
                        id: row["cid"],
                        name: row["name"],
                        type: (row["type"] as String?) ?? "ANY",
                        notNull: (row["notnull"] as Int) != 0,
                        defaultValue: row["dflt_value"],
                        isPrimaryKey: (row["pk"] as Int) != 0
                    )
                }
            }
        } catch {
            print("DebugDBDataSource fetchColumns error: \(error)")
            return []
        }
    }

    // MARK: - Indexes

    func fetchIndexes(table: String) async -> [DebugIndexInfo] {
        do {
            return try await dbQueue.read { db in
                let indexRows = try Row.fetchAll(db, sql: "PRAGMA index_list(\"\(table)\")")
                var indexes: [DebugIndexInfo] = []
                for indexRow in indexRows {
                    let indexName: String = indexRow["name"]
                    let isUnique: Bool = (indexRow["unique"] as Int) != 0
                    let colRows = try Row.fetchAll(db, sql: "PRAGMA index_info(\"\(indexName)\")")
                    let columns = colRows.map { $0["name"] as String }
                    indexes.append(DebugIndexInfo(
                        id: indexName,
                        tableName: table,
                        isUnique: isUnique,
                        columns: columns
                    ))
                }
                return indexes
            }
        } catch {
            print("DebugDBDataSource fetchIndexes error: \(error)")
            return []
        }
    }

    // MARK: - Records (paged + search)

    func fetchRows(table: String, page: Int, pageSize: Int, search: String?) async -> (total: Int, rows: [[String: String]]) {
        do {
            return try await dbQueue.read { db in
                var whereClause = ""
                if let search, !search.isEmpty {
                    let colRows = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
                    let textCols = colRows.compactMap { row -> String? in
                        let type = (row["type"] as String?)?.uppercased() ?? ""
                        if type.contains("TEXT") || type.contains("VARCHAR") || type.isEmpty || type == "ANY" {
                            return row["name"] as String?
                        }
                        return nil
                    }
                    if !textCols.isEmpty {
                        let conditions = textCols.map { "\"\($0)\" LIKE '%\(search.replacingOccurrences(of: "'", with: "''"))%'" }
                        whereClause = "WHERE " + conditions.joined(separator: " OR ")
                    }
                }

                let countSQL = "SELECT COUNT(*) FROM \"\(table)\" \(whereClause)"
                let count = try Int.fetchOne(db, sql: countSQL) ?? 0

                let offset = page * pageSize
                let dataSQL = "SELECT * FROM \"\(table)\" \(whereClause) LIMIT \(pageSize) OFFSET \(offset)"
                let rawRows = try Row.fetchAll(db, sql: dataSQL)
                let mapped = rawRows.map { row in
                    var dict: [String: String] = [:]
                    for (columnName, dbValue) in row {
                        dict[columnName] = dbValue.isNull ? "NULL" : "\(dbValue)"
                    }
                    return dict
                }
                return (count, mapped)
            }
        } catch {
            print("DebugDBDataSource fetchRows error: \(error)")
            return (0, [])
        }
    }

    // MARK: - Execute SQL

    func executeSQL(_ sql: String) async -> DebugSQLResult {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let isRead = trimmed.hasPrefix("SELECT") || trimmed.hasPrefix("PRAGMA") || trimmed.hasPrefix("EXPLAIN")

        if isRead {
            do {
                let result = try await dbQueue.read { db -> (columns: [String], rows: [[String: String]]) in
                    let rows = try Row.fetchAll(db, sql: sql)
                    guard let first = rows.first else { return ([], []) }
                    let columns = Array(first.columnNames)
                    let mapped = rows.map { row in
                        var dict: [String: String] = [:]
                        for (columnName, dbValue) in row {
                            dict[columnName] = dbValue.isNull ? "NULL" : "\(dbValue)"
                        }
                        return dict
                    }
                    return (columns, mapped)
                }
                return .select(columns: result.columns, rows: result.rows)
            } catch {
                return .error(error.localizedDescription)
            }
        } else {
            do {
                let count = try await dbQueue.write { db -> Int in
                    try db.execute(sql: sql)
                    return db.changesCount
                }
                return .write(affectedRows: count)
            } catch {
                return .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Delete Row

    func deleteRow(table: String, primaryKey: String, value: String) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM \"\(table)\" WHERE \"\(primaryKey)\" = ?", arguments: [value])
        }
    }

    // MARK: - DB File Info

    func fetchDBInfo() async -> DebugDBFileInfo {
        do {
            return try await dbQueue.read { [dbQueue] db in
                let version = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "unknown"
                let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
                let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
                let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0

                let path = dbQueue.path
                var fileSize: Int64 = 0
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                    fileSize = attrs[.size] as? Int64 ?? 0
                }

                return DebugDBFileInfo(
                    path: path,
                    fileSize: fileSize,
                    sqliteVersion: version,
                    journalMode: journalMode,
                    pageSize: pageSize,
                    pageCount: pageCount,
                    walMode: journalMode.lowercased() == "wal"
                )
            }
        } catch {
            print("DebugDBDataSource fetchDBInfo error: \(error)")
            return DebugDBFileInfo(path: "", fileSize: 0, sqliteVersion: "unknown", journalMode: "unknown", pageSize: 0, pageCount: 0, walMode: false)
        }
    }

    // MARK: - Migrations

    func fetchMigrations() async -> [DebugMigrationInfo] {
        do {
            return try await dbQueue.read { db in
                // Check if grdb_migrations table exists
                let exists = try Bool.fetchOne(db, sql: """
                    SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='grdb_migrations'
                """) ?? false
                guard exists else { return [] }

                let rows = try Row.fetchAll(db, sql: "SELECT * FROM grdb_migrations ORDER BY identifier")
                return rows.map { row in
                    let identifier: String = row["identifier"]
                    return DebugMigrationInfo(id: identifier, identifier: identifier)
                }
            }
        } catch {
            print("DebugDBDataSource fetchMigrations error: \(error)")
            return []
        }
    }

    // MARK: - Export

    func exportRowAsJSON(row: [String: String], columns: [DebugColumnInfo]) -> String {
        // Maintain column order
        var ordered: [(String, Any)] = []
        for col in columns {
            let value = row[col.name] ?? "NULL"
            if value == "NULL" {
                ordered.append((col.name, NSNull()))
            } else if let intVal = Int(value) {
                ordered.append((col.name, intVal))
            } else if let doubleVal = Double(value), value.contains(".") {
                ordered.append((col.name, doubleVal))
            } else if value == "1" || value == "0", col.type.uppercased().contains("BOOL") {
                ordered.append((col.name, value == "1"))
            } else {
                ordered.append((col.name, value))
            }
        }
        // Build dictionary for JSONSerialization
        var dict: [String: Any] = [:]
        for (key, val) in ordered {
            dict[key] = val
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
