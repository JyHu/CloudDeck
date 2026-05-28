//
//  DebugDBView.swift
//  CloudDeck
//
//  数据库调试视图公开入口。
//
//  - iOS: 自包含 NavigationStack（适合 present 弹出）
//  - macOS: NavigationSplitView（适合新窗口打开）
//
//  使用方式：
//
//     DebugDBView(dbQueue: myDatabaseQueue)
//
//  dbQueue 为可选类型，传入 nil 时显示「未连接数据库」提示页面。
//

import SwiftUI
import GRDB

/// 数据库调试视图，展示所有表及其记录、结构、同步状态等信息。
///
/// 使用方式：
/// ```swift
/// // iOS: 直接作为 sheet 使用（内含 NavigationStack）
/// .sheet(isPresented: $showDB) {
///     DebugDBView(dbQueue: myDatabaseQueue)
/// }
///
/// // macOS: 作为新窗口内容
/// Window("DB Debug", id: "db-debug") {
///     DebugDBView(dbQueue: myDatabaseQueue)
/// }
/// ```
public struct DebugDBView: View {
    private let dbQueue: DatabaseQueue?

    /// 创建数据库调试视图。
    ///
    /// - Parameter dbQueue: GRDB DatabaseQueue 实例，为 nil 时显示「未连接数据库」提示。
    public init(dbQueue: DatabaseQueue?) {
        self.dbQueue = dbQueue
    }

    public var body: some View {
        if let dbQueue {
            let dataSource = DebugDBDataSource(dbQueue: dbQueue)
            #if os(iOS)
            NavigationStack {
                DebugDBListView_iOS(dataSource: dataSource)
            }
            #else
            DebugDBMainView_macOS(dataSource: dataSource)
            #endif
        } else {
            ContentUnavailableView(
                "未连接数据库",
                systemImage: "externaldrive.badge.xmark",
                description: Text("请传入有效的 DatabaseQueue 实例")
            )
        }
    }
}
