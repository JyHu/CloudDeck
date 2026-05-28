//
//  DebugDBView.swift
//  CloudDeck
//
//  Created by hujinyou on 2026/5/28.
//
//  数据库调试视图，展示所有表及其记录数、表结构、行数据。
//  集成到项目后可直接用于开发阶段的数据库检查。
//
//  使用方式（需在 NavigationStack 容器内）：
//
//     NavigationStack {
//         DebugDBView(dbQueue: myDatabaseQueue)
//     }
//
//  dbQueue 为可选类型，传入 nil 时显示「未连接数据库」提示页面。
//

import SwiftUI
import GRDB

// MARK: - Models

/// 表信息
private struct TableInfo: Identifiable, Sendable {
    let id: String // table name
    var rowCount: Int
}

/// 列信息
private struct ColumnInfo: Identifiable, Sendable {
    let id: Int // cid
    let name: String
    let type: String
    let notNull: Bool
    let defaultValue: String?
    let isPrimaryKey: Bool
}

// MARK: - Table List

/// 数据库调试主视图，展示所有表及记录数。
///
/// 默认页面需在 `NavigationStack` 容器内使用：
/// ```swift
/// NavigationStack {
///     DebugDBView(dbQueue: myDatabaseQueue)
/// }
/// ```
///
/// `dbQueue` 为可选类型，传入 nil 时展示提示页面。
public struct DebugDBView: View {
    private let dbQueue: DatabaseQueue?

    @State private var tables: [TableInfo] = []
    @State private var isLoading = true

    /// 创建数据库调试视图。
    ///
    /// - Parameter dbQueue: GRDB DatabaseQueue 实例，为 nil 时显示「未连接数据库」提示。
    public init(dbQueue: DatabaseQueue?) {
        self.dbQueue = dbQueue
    }

    public var body: some View {
        Group {
            if let dbQueue {
                connectedContent(dbQueue: dbQueue)
            } else {
                ContentUnavailableView(
                    "未连接数据库",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text("请传入有效的 DatabaseQueue 实例")
                )
            }
        }
        .navigationTitle("数据库")
    }

    @ViewBuilder
    private func connectedContent(dbQueue: DatabaseQueue) -> some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tables.isEmpty {
                ContentUnavailableView("无数据表", systemImage: "tablecells")
            } else {
                tableListContent(dbQueue: dbQueue)
            }
        }
        #if os(iOS)
        .refreshable { await loadTables(dbQueue: dbQueue) }
        #endif
        .task { await loadTables(dbQueue: dbQueue) }
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await loadTables(dbQueue: dbQueue) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private func tableListContent(dbQueue: DatabaseQueue) -> some View {
        #if os(macOS)
        Table(tables) {
            TableColumn("表名") { table in
                NavigationLink {
                    DebugTableDetailView(table: table.id, dbQueue: dbQueue)
                } label: {
                    Text(table.id)
                        .font(.system(.body, design: .monospaced))
                }
            }
            TableColumn("记录数") { table in
                Text("\(table.rowCount)")
                    .foregroundStyle(.secondary)
            }
            .width(ideal: 80)
        }
        #else
        List {
            ForEach(tables) { table in
                NavigationLink {
                    DebugTableDetailView(table: table.id, dbQueue: dbQueue)
                } label: {
                    HStack {
                        Text(table.id)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Text("\(table.rowCount) rows")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        #endif
    }

    private func loadTables(dbQueue: DatabaseQueue) async {
        do {
            let result = try await dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master
                    WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                    ORDER BY name
                """)
                var infos: [TableInfo] = []
                for row in rows {
                    let name: String = row["name"]
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(name)\"") ?? 0
                    infos.append(TableInfo(id: name, rowCount: count))
                }
                return infos
            }
            tables = result
        } catch {
            print("DebugDBView loadTables error: \(error)")
        }
        isLoading = false
    }
}

// MARK: - Table Detail

/// 单表详情视图，展示表结构和分页记录。
private struct DebugTableDetailView: View {
    let table: String
    let dbQueue: DatabaseQueue

    @State private var columns: [ColumnInfo] = []
    @State private var rows: [[String: String]] = []
    @State private var totalCount = 0
    @State private var currentPage = 0
    private let pageSize = 50

    var body: some View {
        Group {
            #if os(macOS)
            macContent
            #else
            iosContent
            #endif
        }
        .navigationTitle(table)
        .task {
            await loadSchema()
            await loadRows(append: false)
        }
    }

    // MARK: iOS

    #if os(iOS)
    private var iosContent: some View {
        List {
            Section {
                NavigationLink {
                    DebugSchemaView(table: table, columns: columns)
                } label: {
                    Label("Schema (\(columns.count) columns)", systemImage: "tablecells")
                }
                Text("共 \(totalCount) 条记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Records") {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    NavigationLink {
                        DebugRowDetailView(table: table, row: row, columns: columns)
                    } label: {
                        rowLabel(index: currentPage * pageSize + index, row: row)
                    }
                }

                if hasMore {
                    Button("加载更多...") {
                        currentPage += 1
                        Task { await loadRows(append: true) }
                    }
                }
            }
        }
    }
    #endif

    // MARK: macOS

    #if os(macOS)
    private var macContent: some View {
        VStack(spacing: 0) {
            // Schema summary bar
            HStack {
                NavigationLink {
                    DebugSchemaView(table: table, columns: columns)
                } label: {
                    Label("Schema (\(columns.count) columns)", systemImage: "tablecells")
                }
                Spacer()
                Text("共 \(totalCount) 条记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if hasMore {
                    Button("加载更多") {
                        currentPage += 1
                        Task { await loadRows(append: true) }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Data list (macOS style)
            if columns.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        NavigationLink {
                            DebugRowDetailView(table: table, row: row, columns: columns)
                        } label: {
                            HStack(spacing: 12) {
                                Text("#\(index)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 30, alignment: .trailing)
                                ForEach(columns.prefix(5)) { col in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(col.name)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                        Text(row[col.name] ?? "NULL")
                                            .font(.system(.caption, design: .monospaced))
                                            .lineLimit(1)
                                    }
                                    .frame(minWidth: 60, alignment: .leading)
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
    }
    #endif

    // MARK: Shared

    private var hasMore: Bool {
        (currentPage + 1) * pageSize < totalCount
    }

    @ViewBuilder
    private func rowLabel(index: Int, row: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("#\(index)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            let preview = columns.prefix(3).compactMap { col in
                row[col.name].map { "\(col.name): \($0)" }
            }.joined(separator: " | ")
            Text(preview)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }

    private func loadSchema() async {
        do {
            columns = try await dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
                return rows.map { row in
                    ColumnInfo(
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
            print("DebugDBView loadSchema error: \(error)")
        }
    }

    private func loadRows(append: Bool) async {
        let page = currentPage
        let limit = pageSize
        do {
            let (count, fetched) = try await dbQueue.read { db -> (Int, [[String: String]]) in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
                let offset = page * limit
                let rawRows = try Row.fetchAll(db, sql: """
                    SELECT * FROM \"\(table)\" LIMIT \(limit) OFFSET \(offset)
                """)
                let mapped = rawRows.map { row in
                    var dict: [String: String] = [:]
                    for (columnName, dbValue) in row {
                        dict[columnName] = dbValue.isNull ? "NULL" : "\(dbValue)"
                    }
                    return dict
                }
                return (count, mapped)
            }
            totalCount = count
            if append {
                rows.append(contentsOf: fetched)
            } else {
                rows = fetched
            }
        } catch {
            print("DebugDBView loadRows error: \(error)")
        }
    }
}

// MARK: - Schema View

/// 表结构视图，展示列名、类型、约束信息。
private struct DebugSchemaView: View {
    let table: String
    let columns: [ColumnInfo]

    var body: some View {
        Group {
            #if os(macOS)
            Table(columns) {
                TableColumn("列名") { col in
                    Text(col.name)
                        .font(.system(.body, design: .monospaced))
                        .bold(col.isPrimaryKey)
                }
                TableColumn("类型") { col in
                    Text(col.type)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.blue)
                }
                .width(ideal: 80)
                TableColumn("约束") { col in
                    HStack(spacing: 4) {
                        if col.isPrimaryKey { badge("PK", color: .orange) }
                        if col.notNull { badge("NOT NULL", color: .red) }
                        if let def = col.defaultValue { badge("DEFAULT: \(def)", color: .green) }
                    }
                }
                .width(ideal: 200)
            }
            #else
            List {
                ForEach(columns) { col in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(col.name)
                                .font(.system(.body, design: .monospaced))
                                .bold()
                            Spacer()
                            Text(col.type)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.blue)
                        }
                        HStack(spacing: 8) {
                            if col.isPrimaryKey { badge("PK", color: .orange) }
                            if col.notNull { badge("NOT NULL", color: .red) }
                            if let def = col.defaultValue { badge("DEFAULT: \(def)", color: .green) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            #endif
        }
        .navigationTitle("Schema: \(table)")
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Row Detail

/// 单行记录详情视图。
private struct DebugRowDetailView: View {
    let table: String
    let row: [String: String]
    let columns: [ColumnInfo]

    private let metaFields: Set<String> = [
        "id",
        "syncId", "sync_id",
        "createAt", "created_at", "createdAt",
        "updateAt", "updated_at", "updatedAt",
        "isDeleted", "is_deleted",
        "isSynced", "is_synced",
    ]

    var body: some View {
        let metaCols = columns.filter { metaFields.contains($0.name) }
        let dataCols = columns.filter { !metaFields.contains($0.name) }

        Group {
            #if os(macOS)
            Form {
                if !metaCols.isEmpty {
                    Section("Sync Meta") {
                        ForEach(metaCols) { col in fieldRow(col) }
                    }
                }
                Section("Data") {
                    ForEach(dataCols) { col in fieldRow(col) }
                }
            }
            .formStyle(.grouped)
            #else
            List {
                if !metaCols.isEmpty {
                    Section("Sync Meta") {
                        ForEach(metaCols) { col in fieldRow(col) }
                    }
                }
                Section("Data") {
                    ForEach(dataCols) { col in fieldRow(col) }
                }
            }
            #endif
        }
        .navigationTitle("Record")
    }

    private func fieldRow(_ col: ColumnInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(col.name)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(row[col.name] ?? "NULL")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
