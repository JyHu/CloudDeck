//
//  DebugDBInfoView_iOS.swift
//  CloudDeck
//
//  iOS database file info + migration history.
//

#if os(iOS)
import SwiftUI
import GRDB

struct DebugDBInfoView_iOS: View {
    let dataSource: DebugDBDataSource

    @State private var dbInfo: DebugDBFileInfo?
    @State private var migrations: [DebugMigrationInfo] = []

    var body: some View {
        List {
            if let info = dbInfo {
                Section("数据库文件") {
                    infoRow("路径", value: info.path)
                    infoRow("文件大小", value: formatFileSize(info.fileSize))
                    infoRow("SQLite 版本", value: info.sqliteVersion)
                    infoRow("Journal 模式", value: info.journalMode)
                    infoRow("Page Size", value: "\(info.pageSize) bytes")
                    infoRow("Page Count", value: "\(info.pageCount)")
                    infoRow("WAL 模式", value: info.walMode ? "是" : "否")
                }
            }

            if !migrations.isEmpty {
                Section("Migration 历史") {
                    ForEach(migrations) { migration in
                        Text(migration.identifier)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        .navigationTitle("数据库信息")
        .task {
            dbInfo = await dataSource.fetchDBInfo()
            migrations = await dataSource.fetchMigrations()
        }
    }

    private func infoRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
#endif
