//
//  DebugRowDetailView_macOS.swift
//  CloudDeck
//
//  macOS row detail inspector panel.
//

#if os(macOS)
import SwiftUI
import GRDB
import AppKit

struct DebugRowDetailView_macOS: View {
    let table: String
    let row: [String: String]
    let columns: [DebugColumnInfo]
    let dataSource: DebugDBDataSource
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false

    private let metaFields: Set<String> = [
        "id", "syncId", "sync_id",
        "createAt", "created_at", "createdAt",
        "updateAt", "updated_at", "updatedAt",
        "isDeleted", "is_deleted",
        "isSynced", "is_synced",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Record Detail")
                    .font(.headline)
                Spacer()
                Button {
                    copyJSON()
                } label: {
                    Label("复制 JSON", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                let metaCols = columns.filter { metaFields.contains($0.name) }
                let dataCols = columns.filter { !metaFields.contains($0.name) }

                VStack(alignment: .leading, spacing: 0) {
                    if !metaCols.isEmpty {
                        sectionHeader("Sync Meta")
                        ForEach(metaCols) { col in fieldRow(col) }
                    }
                    sectionHeader("Data")
                    ForEach(dataCols) { col in fieldRow(col) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) { deleteRecord() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作将从数据库中永久删除该记录。")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func fieldRow(_ col: DebugColumnInfo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(col.name)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text(row[col.name] ?? "NULL")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func copyJSON() {
        let json = dataSource.exportRowAsJSON(row: row, columns: columns)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }

    private func deleteRecord() {
        guard let pkCol = columns.first(where: { $0.isPrimaryKey }),
              let pkValue = row[pkCol.name] else { return }
        Task {
            try? await dataSource.deleteRow(table: table, primaryKey: pkCol.name, value: pkValue)
            onDelete()
        }
    }
}
#endif
