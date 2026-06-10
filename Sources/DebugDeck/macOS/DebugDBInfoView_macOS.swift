//
//  DebugDBInfoView_macOS.swift
//  CloudDeck
//
//  macOS database file info + migration history.
//

#if os(macOS)
import SwiftUI
import GRDB

struct DebugDBInfoView_macOS: View {
    let dataSource: DebugDBDataSource

    @State private var dbInfo: DebugDBFileInfo?
    @State private var migrations: [DebugMigrationInfo] = []

    var body: some View {
        Form {
            if let info = dbInfo {
                Section("数据库文件") {
                    LabeledContent("路径") {
                        Text(info.path)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent("文件大小") { Text(formatFileSize(info.fileSize)) }
                    LabeledContent("SQLite 版本") { Text(info.sqliteVersion) }
                    LabeledContent("Journal 模式") { Text(info.journalMode) }
                    LabeledContent("Page Size") { Text("\(info.pageSize) bytes") }
                    LabeledContent("Page Count") { Text("\(info.pageCount)") }
                    LabeledContent("WAL 模式") { Text(info.walMode ? "是" : "否") }
                }
            }

            if !migrations.isEmpty {
                Section("Migration 历史 (\(migrations.count))") {
                    ForEach(migrations) { migration in
                        Text(migration.identifier)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("数据库信息")
        .task {
            dbInfo = await dataSource.fetchDBInfo()
            migrations = await dataSource.fetchMigrations()
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
#endif
