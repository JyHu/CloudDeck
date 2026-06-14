//
//  DBQuery.swift
//  CloudDeck
//
//  Created by hujinyou on 2026/5/28.
//
//  提供 GRDB 数据库实时观察的基础设施，供使用方在自己的项目中
//  快速创建声明式的 SwiftUI property wrapper。
//
//  本文件提供：
//  - `DBRequest`   — 协议，定义一次数据库查询的逻辑
//  - `FetchAll`    — 内置请求，获取多条记录（支持 filter/order/limit）
//  - `FetchOne`    — 内置请求，获取单条记录（按主键或自定义条件）
//  - `FetchCount`  — 内置请求，获取记录数量（全表或带条件）
//  - `Exists`      — 内置请求，检查记录是否存在
//  - `DBObserver`  — 基于 GRDB ValueObservation 的响应式观察者
//
//  ─────────────────────────────────────────────────────────────────────
//  使用方需要在自己的项目中创建一个 property wrapper（约 10 行代码）：
//
//  ```swift
//  import CloudDeck
//  import SwiftUI
//
//  @MainActor
//  @propertyWrapper
//  struct Query<Request: DBRequest>: DynamicProperty {
//      @State private var observer: DBObserver<Request.Value>
//
//      var wrappedValue: Request.Value { observer.value }
//
//      init(_ request: Request, default defaultValue: Request.Value) {
//          _observer = State(initialValue: DBObserver(
//              dbQueue: AppCenter.shared.coordinator.db.queue,  // 替换为你的 dbQueue 来源
//              defaultValue: defaultValue
//          ) { db in try request.fetch(db) })
//      }
//  }
//  ```
//
//  然后即可在 SwiftUI 视图中使用：
//
//  ```swift
//  // 自定义查询
//  @Query(ActiveTasksRequest(), default: []) var tasks
//
//  // 内置 FetchAll（支持过滤和排序）
//  @Query(FetchAll<Tag>(), default: []) var allTags
//  @Query(FetchAll<Tag> { $0.filter(Tag.Columns.isDeleted == false) }, default: []) var activeTags
//
//  // 内置 FetchOne
//  @Query(FetchOne<Task>(key: "task-id"), default: nil) var task
//
//  // 内置 FetchCount
//  @Query(FetchCount<Task>(), default: 0) var totalTasks
//  @Query(FetchCount<Task> {
//      $0.filter(Task.Columns.isCompleted == false)
//  }, default: 0) var incompleteCount
//
//  // 内置 Exists
//  @Query(Exists<Task> {
//      $0.filter(Task.Columns.isCompleted == false)
//  }, default: false) var hasIncompleteTasks
//
//  // 在 init 中动态构造
//  struct GameDetailView: View {
//      @Query<GameStatsRequest> var stats: GameStats?
//
//      init(gameId: String) {
//          _stats = Query(GameStatsRequest(gameId: gameId), default: nil)
//      }
//  }
//  ```
//  ─────────────────────────────────────────────────────────────────────

import GRDB
import Foundation
import SwiftUI
import Observation

// MARK: - Protocol

/// 定义一次数据库查询的协议。
///
/// 遵循此协议来创建自定义查询请求，配合你的 property wrapper 使用。
/// `Value` 必须满足 `Sendable`（Swift 6 并发安全要求）。
///
/// 示例：
/// ```swift
/// struct ActiveTasksRequest: DBRequest {
///     func fetch(_ db: Database) throws -> [Task] {
///         try Task
///             .filter(Task.Columns.isDeleted == false)
///             .order(Task.Columns.createAt.desc)
///             .fetchAll(db)
///     }
/// }
/// ```
public protocol DBRequest: Sendable {
    associatedtype Value: Sendable
    func fetch(_ db: Database) throws -> Value
}

// MARK: - Built-in Requests

/// 内置请求：获取某张表的记录，支持可选的过滤和排序。
///
/// 用法：
/// ```swift
/// @Query(FetchAll<Tag>(), default: []) var allTags
/// @Query(FetchAll<Tag> { $0.filter(Tag.Columns.isDeleted == false) }, default: []) var activeTags
/// @Query(FetchAll<Task> {
///     $0.filter(Task.Columns.isDeleted == false).order(Task.Columns.createAt.desc)
/// }, default: []) var tasks
/// ```
public struct FetchAll<T: FetchableRecord & PersistableRecord>: DBRequest {
    private let query: @Sendable (Database) throws -> [T]

    /// 获取全部记录（无过滤）。
    public init() {
        self.query = { db in try T.fetchAll(db) }
    }

    /// 获取经过自定义查询条件处理的记录。
    ///
    /// - Parameter build: 接收 `QueryInterfaceRequest<T>`，返回经过 filter/order/limit 等处理后的请求。
    public init(_ build: @Sendable @escaping (QueryInterfaceRequest<T>) -> QueryInterfaceRequest<T>) {
        self.query = { db in try build(T.all()).fetchAll(db) }
    }

    public func fetch(_ db: Database) throws -> [T] {
        try query(db)
    }
}

/// 内置请求：获取满足条件的单条记录。
///
/// 用法：
/// ```swift
/// @Query(FetchOne<Task>(key: "task-id"), default: nil) var task
/// @Query(FetchOne<Task> { $0.filter(Task.Columns.title == "买牛奶") }, default: nil) var task
/// ```
public struct FetchOne<T: FetchableRecord & PersistableRecord>: DBRequest {
    private let query: @Sendable (Database) throws -> T?

    /// 按主键查询单条记录。
    public init(key: some DatabaseValueConvertible & Sendable) {
        self.query = { db in try T.fetchOne(db, key: key) }
    }

    /// 自定义条件查询单条记录。
    public init(_ build: @Sendable @escaping (QueryInterfaceRequest<T>) -> QueryInterfaceRequest<T>) {
        self.query = { db in try build(T.all()).fetchOne(db) }
    }

    public func fetch(_ db: Database) throws -> T? {
        try query(db)
    }
}

/// 内置请求：检查是否存在满足条件的记录。
///
/// 用法：
/// ```swift
/// @Query(Exists<Task>(key: "task-id"), default: false) var taskExists
/// @Query(Exists<Task> {
///     $0.filter(Task.Columns.isCompleted == false && Task.Columns.isDeleted == false)
/// }, default: false) var hasIncompleteTasks
/// ```
public struct Exists<T: FetchableRecord & PersistableRecord>: DBRequest {
    private let query: @Sendable (Database) throws -> Bool

    /// 按主键检查记录是否存在。
    public init(key: some DatabaseValueConvertible & Sendable) {
        self.query = { db in try T.exists(db, key: key) }
    }

    /// 自定义条件检查记录是否存在。
    public init(_ build: @Sendable @escaping (QueryInterfaceRequest<T>) -> QueryInterfaceRequest<T>) {
        self.query = { db in try build(T.all()).isEmpty(db) == false }
    }

    public func fetch(_ db: Database) throws -> Bool {
        try query(db)
    }
}

/// 内置请求：获取满足条件的记录数量。
///
/// 用法：
/// ```swift
/// // 全表计数
/// @Query(FetchCount<Task>(), default: 0) var totalTasks
///
/// // 带条件计数
/// @Query(FetchCount<Task> {
///     $0.filter(Task.Columns.isCompleted == false && Task.Columns.isDeleted == false)
/// }, default: 0) var incompleteCount
/// ```
public struct FetchCount<T: FetchableRecord & PersistableRecord>: DBRequest {
    private let query: @Sendable (Database) throws -> Int

    /// 全表记录数。
    public init() {
        self.query = { db in try T.fetchCount(db) }
    }

    /// 满足条件的记录数。
    public init(_ build: @Sendable @escaping (QueryInterfaceRequest<T>) -> QueryInterfaceRequest<T>) {
        self.query = { db in try build(T.all()).fetchCount(db) }
    }

    public func fetch(_ db: Database) throws -> Int {
        try query(db)
    }
}

// MARK: - Observer

/// 基于 GRDB `ValueObservation` 的响应式数据库观察者。
///
/// 当数据库中被观察的数据发生变化时，`value` 会自动更新并触发 SwiftUI 视图刷新。
/// 在你的 property wrapper 中通过 `@State` 持有此对象即可。
///
/// 示例（在自定义 property wrapper 中使用）：
/// ```swift
/// @MainActor
/// @propertyWrapper
/// struct Query<Request: DBRequest>: DynamicProperty {
///     @State private var observer: DBObserver<Request.Value>
///
///     var wrappedValue: Request.Value { observer.value }
///     var projectedValue: DBObserver<Request.Value> { observer }
///
///     init(_ request: Request, default defaultValue: Request.Value) {
///         _observer = State(initialValue: DBObserver(
///             dbQueue: MyDB.shared.queue,
///             defaultValue: defaultValue
///         ) { db in try request.fetch(db) })
///     }
/// }
/// ```
@Observable
@MainActor
public final class DBObserver<Value: Sendable> {
    /// 当前观察到的最新值，数据库变化时自动更新。
    public var value: Value
    
    /// 当前数据有没有更新过，第一次更新以后就会被设置为true，比如使用的时候：
    /// @DBQuery(xxxx) var results
    /// 那么在业务中可以直接监听这个属性的变化：
    /// if $results.hasReceivedInitialValue {}
    /// 来处理数据初次加载的状态变动
    public var hasReceivedInitialValue: Bool = false

    private var cancellable: AnyDatabaseCancellable?

    /// 创建一个数据库观察者。
    ///
    /// - Parameters:
    ///   - dbQueue: GRDB 数据库队列
    ///   - defaultValue: 初始默认值（在首次数据库回调之前使用）
    ///   - observation: 数据库查询闭包，每当相关表发生变化时被重新执行
    public init(
        dbQueue: DatabaseQueue,
        defaultValue: Value,
        observation: @Sendable @escaping (Database) throws -> Value
    ) {
        self.value = defaultValue

        let obs = ValueObservation.tracking(observation)
        self.cancellable = obs.start(
            in: dbQueue,
            onError: { error in
                print("DBObserver error:", error)
                self.hasReceivedInitialValue = true
            },
            onChange: { [weak self] newValue in
                guard let self else { return }

                if self.hasReceivedInitialValue {
                    withAnimation {
                        self.value = newValue
                    }
                } else {
                    self.value = newValue
                    self.hasReceivedInitialValue = true
                }
            }
        )
    }
}
