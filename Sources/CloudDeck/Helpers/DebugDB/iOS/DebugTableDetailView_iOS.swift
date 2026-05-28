//
//  DebugTableDetailView_iOS.swift
//  CloudDeck
//
//  iOS single table detail: schema link + search + paginated records.
//

#if os(iOS)
import SwiftUI
import GRDB

struct DebugTableDetailView_iOS: View {
    let table: String
    let dataSource: DebugDBDataSource

    @State private var columns: [DebugColumnInfo] = []
    @State private var rows: [[String: String]] = []
    @State private var totalCount = 0
    @State private var currentPage = 0
    @State private var searchText = ""
    private let pageSize = 50

    var body: some View {
        List {
            Section {
                NavigationLink {
                    DebugSchemaView_iOS(table: table, dataSource: dataSource)
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
                        DebugRowDetailView_iOS(table: table, row: row, columns: columns, dataSource: dataSource)
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
        .navigationTitle(table)
        .searchable(text: $searchText, prompt: "搜索记录")
        .onChange(of: searchText) { _, _ in
            currentPage = 0
            Task { await loadRows(append: false) }
        }
        .refreshable {
            currentPage = 0
            await loadRows(append: false)
        }
        .task {
            await loadSchema()
            await loadRows(append: false)
        }
    }

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
        columns = await dataSource.fetchColumns(table: table)
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
