//
//  DebugDBListView_iOS.swift
//  CloudDeck
//
//  iOS table list with sync status overview.
//

#if os(iOS)
import SwiftUI
import GRDB

struct DebugDBListView_iOS: View {
    let dataSource: DebugDBDataSource

    @State private var tables: [DebugTableInfo] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tables.isEmpty {
                ContentUnavailableView("无数据表", systemImage: "tablecells")
            } else {
                tableList
            }
        }
        .navigationTitle("数据库")
        .refreshable { await loadTables() }
        .task { await loadTables() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    NavigationLink {
                        DebugSQLView_iOS(dataSource: dataSource)
                    } label: {
                        Label("执行 SQL", systemImage: "terminal")
                    }
                    NavigationLink {
                        DebugDBInfoView_iOS(dataSource: dataSource)
                    } label: {
                        Label("数据库信息", systemImage: "info.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var tableList: some View {
        List {
            ForEach(tables) { table in
                NavigationLink {
                    DebugTableDetailView_iOS(table: table.id, dataSource: dataSource)
                } label: {
                    HStack {
                        Text(table.id)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        if table.hasSyncColumns {
                            syncBadges(table: table)
                        }
                        Text("\(table.rowCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func syncBadges(table: DebugTableInfo) -> some View {
        if table.unsyncedCount > 0 {
            Text("\(table.unsyncedCount)")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        }
        if table.deletedCount > 0 {
            Text("\(table.deletedCount)")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.red.opacity(0.2), in: Capsule())
                .foregroundStyle(.red)
        }
    }

    private func loadTables() async {
        tables = await dataSource.fetchTables()
        isLoading = false
    }
}
#endif
