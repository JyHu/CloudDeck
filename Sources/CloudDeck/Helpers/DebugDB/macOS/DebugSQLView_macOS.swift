//
//  DebugSQLView_macOS.swift
//  CloudDeck
//
//  macOS SQL editor + results table.
//

#if os(macOS)
import SwiftUI
import GRDB
import AppKit

struct DebugSQLView_macOS: View {
    let dataSource: DebugDBDataSource

    @Environment(\.dismiss) private var dismiss
    @State private var sqlText = ""
    @State private var result: DebugSQLResult?
    @State private var isExecuting = false

    var body: some View {
        NavigationStack {
            VSplitView {
                // SQL editor
                VStack(spacing: 8) {
                    HStack {
                        Text("SQL")
                            .font(.headline)
                        Spacer()
                        Button {
                            Task { await executeSQL() }
                        } label: {
                            Label("执行", systemImage: "play.fill")
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isExecuting)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    TextEditor(text: $sqlText)
                        .font(.system(.body, design: .monospaced))
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3))
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                .frame(minHeight: 120, idealHeight: 150)

                // Results
                resultView
                    .frame(minHeight: 200)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .navigationTitle("执行 SQL")
        }
    }

    @ViewBuilder
    private var resultView: some View {
        if isExecuting {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result {
            switch result {
            case .select(let columns, let rows):
                if rows.isEmpty {
                    ContentUnavailableView("无结果", systemImage: "tray")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("\(rows.count) 条结果, \(columns.count) 列")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            Spacer()
                        }
                        Divider()
                        List {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: 12) {
                                    ForEach(columns, id: \.self) { col in
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(col)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.tertiary)
                                            Text(row[col] ?? "NULL")
                                                .font(.system(.caption, design: .monospaced))
                                                .lineLimit(2)
                                                .textSelection(.enabled)
                                        }
                                        .frame(minWidth: 60, alignment: .leading)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            case .write(let affected):
                ContentUnavailableView(
                    "执行成功",
                    systemImage: "checkmark.circle",
                    description: Text("影响 \(affected) 行")
                )
            case .error(let msg):
                ContentUnavailableView(
                    "错误",
                    systemImage: "xmark.circle",
                    description: Text(msg)
                )
            }
        } else {
            ContentUnavailableView("输入 SQL 并按 ⌘↩ 执行", systemImage: "terminal")
        }
    }

    private func executeSQL() async {
        isExecuting = true
        result = await dataSource.executeSQL(sqlText)
        isExecuting = false
    }
}
#endif
