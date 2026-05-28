//
//  DebugDBMainView_macOS.swift
//  CloudDeck
//
//  macOS NavigationSplitView entry (sidebar + detail).
//

#if os(macOS)
import SwiftUI
import GRDB

struct DebugDBMainView_macOS: View {
    let dataSource: DebugDBDataSource

    @State private var selectedTable: String?
    @State private var showSQL = false
    @State private var showDBInfo = false

    var body: some View {
        NavigationSplitView {
            DebugDBSidebar_macOS(dataSource: dataSource, selectedTable: $selectedTable)
        } detail: {
            if let table = selectedTable {
                DebugTableDetailView_macOS(table: table, dataSource: dataSource)
            } else {
                ContentUnavailableView("选择一张表", systemImage: "tablecells", description: Text("从左侧列表选择要查看的表"))
            }
        }
        .navigationTitle("数据库")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    showSQL = true
                } label: {
                    Label("SQL", systemImage: "terminal")
                }
                Button {
                    showDBInfo = true
                } label: {
                    Label("DB Info", systemImage: "info.circle")
                }
            }
        }
        .sheet(isPresented: $showSQL) {
            DebugSQLView_macOS(dataSource: dataSource)
                .frame(minWidth: 600, minHeight: 400)
        }
        .sheet(isPresented: $showDBInfo) {
            macDBInfoSheet
                .frame(minWidth: 500, minHeight: 400)
        }
    }

    private var macDBInfoSheet: some View {
        NavigationStack {
            DebugDBInfoView_macOS(dataSource: dataSource)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showDBInfo = false }
                    }
                }
        }
    }
}
#endif
