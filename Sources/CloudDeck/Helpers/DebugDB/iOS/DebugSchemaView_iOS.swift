//
//  DebugSchemaView_iOS.swift
//  CloudDeck
//
//  iOS schema + index display.
//

#if os(iOS)
import SwiftUI
import GRDB

struct DebugSchemaView_iOS: View {
    let table: String
    let dataSource: DebugDBDataSource

    @State private var columns: [DebugColumnInfo] = []
    @State private var indexes: [DebugIndexInfo] = []

    var body: some View {
        List {
            Section("Columns") {
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

            if !indexes.isEmpty {
                Section("Indexes") {
                    ForEach(indexes) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(index.id)
                                    .font(.system(.caption, design: .monospaced))
                                    .bold()
                                Spacer()
                                if index.isUnique {
                                    badge("UNIQUE", color: .purple)
                                }
                            }
                            Text(index.columns.joined(separator: ", "))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Schema: \(table)")
        .task {
            columns = await dataSource.fetchColumns(table: table)
            indexes = await dataSource.fetchIndexes(table: table)
        }
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
#endif
