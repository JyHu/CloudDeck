//
//  DebugRowDetailView_iOS.swift
//  CloudDeck
//
//  iOS row detail: field display + copy JSON + delete.
//

#if os(iOS)
import SwiftUI
import GRDB

struct DebugRowDetailView_iOS: View {
    let table: String
    let row: [String: String]
    let columns: [DebugColumnInfo]
    let dataSource: DebugDBDataSource

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    private let metaFields: Set<String> = [
        "id", "syncId", "sync_id",
        "createAt", "created_at", "createdAt",
        "updateAt", "updated_at", "updatedAt",
        "isDeleted", "is_deleted",
        "isSynced", "is_synced",
    ]

    var body: some View {
        let metaCols = columns.filter { metaFields.contains($0.name) }
        let dataCols = columns.filter { !metaFields.contains($0.name) }

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
        .navigationTitle("Record")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        copyJSON()
                    } label: {
                        Label("复制为 JSON", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除记录", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) { deleteRecord() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作将从数据库中永久删除该记录。")
        }
    }

    private func fieldRow(_ col: DebugColumnInfo) -> some View {
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

    private func copyJSON() {
        let json = dataSource.exportRowAsJSON(row: row, columns: columns)
        UIPasteboard.general.string = json
    }

    private func deleteRecord() {
        guard let pkCol = columns.first(where: { $0.isPrimaryKey }),
              let pkValue = row[pkCol.name] else { return }
        Task {
            try? await dataSource.deleteRow(table: table, primaryKey: pkCol.name, value: pkValue)
            dismiss()
        }
    }
}
#endif
