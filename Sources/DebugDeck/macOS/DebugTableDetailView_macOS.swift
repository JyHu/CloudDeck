//
//  DebugTableDetailView_macOS.swift
//  CloudDeck
//
//  macOS table detail: record list with toolbar search + schema link.
//

#if os(macOS)
import SwiftUI
import GRDB

struct DebugTableDetailView_macOS: View {
    let table: String
    let dataSource: DebugDBDataSource

    @State private var columns: [DebugColumnInfo] = []
    @State private var indexes: [DebugIndexInfo] = []
    @State private var rows: [[String: String]] = []
    @State private var totalCount = 0
    @State private var currentPage = 0
    @State private var searchText = ""
    @State private var selectedRowIndex: Int?
    @State private var showSchema = false
    private let pageSize = 100

    var body: some View {
        VSplitView {
            // Top: record table
            VStack(spacing: 0) {
                toolbar
                Divider()
                recordTable
            }
            .frame(minHeight: 200)

            // Bottom: inspector for selected row
            if let idx = selectedRowIndex, idx < rows.count {
                DebugRowDetailView_macOS(
                    table: table,
                    row: rows[idx],
                    columns: columns,
                    dataSource: dataSource,
                    onDelete: {
                        selectedRowIndex = nil
                        Task { await loadRows(append: false) }
                    }
                )
                .frame(minHeight: 150, idealHeight: 200)
            }
        }
        .task {
            await loadSchema()
            await loadRows(append: false)
        }
        .onChange(of: table) { _, _ in
            currentPage = 0
            selectedRowIndex = nil
            rows = []
            Task {
                await loadSchema()
                await loadRows(append: false)
            }
        }
        .sheet(isPresented: $showSchema) {
            NavigationStack {
                schemaSheet
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { showSchema = false }
                        }
                    }
            }
            .frame(minWidth: 500, minHeight: 400)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(table)
                .font(.system(.headline, design: .monospaced))

            Text("共 \(totalCount) 条")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            TextField("搜索...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .onSubmit {
                    currentPage = 0
                    Task { await loadRows(append: false) }
                }

            Button {
                showSchema = true
            } label: {
                Label("Schema", systemImage: "tablecells")
            }

            if hasMore {
                Button("加载更多") {
                    currentPage += 1
                    Task { await loadRows(append: true) }
                }
            }

            Button {
                currentPage = 0
                Task { await loadRows(append: false) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Record Table

    @ViewBuilder
    private var recordTable: some View {
        if columns.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedRowIndex) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 12) {
                        Text("#\(index)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 35, alignment: .trailing)
                        ForEach(columns.prefix(6)) { col in
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
                    .tag(index)
                }
            }
        }
    }

    // MARK: - Schema Sheet

    private var schemaSheet: some View {
        List {
            Section("Columns (\(columns.count))") {
                ForEach(columns) { col in
                    HStack {
                        Text(col.name)
                            .font(.system(.body, design: .monospaced))
                            .bold(col.isPrimaryKey)
                        Spacer()
                        Text(col.type)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.blue)
                        if col.isPrimaryKey { badge("PK", color: .orange) }
                        if col.notNull { badge("NN", color: .red) }
                    }
                }
            }

            if !indexes.isEmpty {
                Section("Indexes (\(indexes.count))") {
                    ForEach(indexes) { index in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(index.id)
                                    .font(.system(.caption, design: .monospaced))
                                    .bold()
                                if index.isUnique { badge("UNIQUE", color: .purple) }
                            }
                            Text(index.columns.joined(separator: ", "))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Schema: \(table)")
    }

    // MARK: - Helpers

    private var hasMore: Bool {
        (currentPage + 1) * pageSize < totalCount
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func loadSchema() async {
        columns = await dataSource.fetchColumns(table: table)
        indexes = await dataSource.fetchIndexes(table: table)
    }

    private func loadRows(append: Bool) async {
        let search = searchText.isEmpty ? nil : searchText
        let result = await dataSource.fetchRows(table: table, page: currentPage, pageSize: pageSize, search: search)
        totalCount = result.total
        if append {
            rows.append(contentsOf: result.rows)
        } else {
            rows = result.rows
        }
    }
}
#endif
