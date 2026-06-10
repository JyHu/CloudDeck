//
//  DebugSQLView_iOS.swift
//  CloudDeck
//
//  iOS custom SQL execution view.
//

#if os(iOS)
import SwiftUI
import GRDB

struct DebugSQLView_iOS: View {
    let dataSource: DebugDBDataSource

    @State private var sqlText = ""
    @State private var result: DebugSQLResult?
    @State private var isExecuting = false

    var body: some View {
        VStack(spacing: 0) {
            // SQL input
            TextEditor(text: $sqlText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 150)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3))
                )
                .padding()

            // Execute button
            HStack {
                Spacer()
                Button {
                    Task { await executeSQL() }
                } label: {
                    Label("执行", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isExecuting)
                .padding(.trailing)
            }

            Divider()
                .padding(.top, 8)

            // Results
            resultView
        }
        .navigationTitle("执行 SQL")
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
                    List {
                        Text("\(rows.count) 条结果, \(columns.count) 列")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(columns, id: \.self) { col in
                                    HStack(alignment: .top) {
                                        Text(col)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 80, alignment: .trailing)
                                        Text(row[col] ?? "NULL")
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
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
            ContentUnavailableView("输入 SQL 语句并执行", systemImage: "terminal")
        }
    }

    private func executeSQL() async {
        isExecuting = true
        result = await dataSource.executeSQL(sqlText)
        isExecuting = false
    }
}
#endif
