//
//  DebugDBSidebar_macOS.swift
//  CloudDeck
//
//  macOS sidebar: table list + sync overview.
//

#if os(macOS)
import SwiftUI
import GRDB

struct DebugDBSidebar_macOS: View {
    let dataSource: DebugDBDataSource
    @Binding var selectedTable: String?

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
        .task { await loadTables() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await loadTables() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    private var tableList: some View {
        List(selection: $selectedTable) {
            Section("Tables") {
                ForEach(tables) { table in
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
                    .tag(table.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func syncBadges(table: DebugTableInfo) -> some View {
        if table.unsyncedCount > 0 {
            Text("\(table.unsyncedCount)")
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        }
        if table.deletedCount > 0 {
            Text("\(table.deletedCount)")
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 4)
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
