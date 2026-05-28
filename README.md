# CloudDeck

基于 **Pull-Merge-Push** 策略的 Swift 数据同步框架，结合 CloudKit（iCloud 私有数据库）与 GRDB（本地 SQLite），实现离线优先的数据同步。

## 架构

```
┌─────────────────────────────────────────────────┐
│                   APP                           │
│        (ViewModel, Service, View & Logic)       │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│              SyncCoordinator                    │
│       (Manage Zone, Subscription, Store)        │
├─────────────────────────────────────────────────┤
│       ┌─────────────┐  ┌───────────────┐        │
│       │  GRDBStore  │  │CloudKitManager│        │
│       │  (SQLite)   │  │  (iCloud)     │        │
│       └─────────────┘  └───────────────┘        │
├─────────────────────────────────────────────────┤
│  SyncableStore<Task>                            │
│  SyncableStore<Tag>                             │
│  SyncableStore<...>                             │
└─────────────────────────────────────────────────┘
```

## 特性

- **离线优先**：数据始终先持久化到本地，网络可用时再同步
- **Cloud-First CRUD**：保存/删除先尝试云端写入，失败则回退到本地
- **Pull-Merge-Push 冲突解决**：无数据丢失，确定性的胜者选择
- **Last-Write-Wins + 服务器时间**：基于 CloudKit 的 `modificationDate` 保证时间可信
- **软删除**：本地标记删除，同步到云端后才物理删除
- **增量同步**：Change Token 机制避免每次全量拉取
- **静默推送**：CloudKit Zone Subscription 实现后台自动同步
- **类型安全 Store**：每个模型对应一个强类型 Store
- **依赖注入**：CloudKit 和 GRDB 均有协议抽象，便于单元测试

## 环境要求

- iOS 17+ / macOS 14+ / watchOS 10+
- Swift 6.1+
- Xcode 16+

## 安装

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/JyHu/CloudDeck", from: "1.0.0")
]
```

## 快速上手

### 1. 定义模型

```swift
import CloudDeck

struct Task: SyncableProtocol {
    // 同步必需字段
    var id: String
    var createAt: Date
    var updateAt: Date
    var isDeleted: Bool
    var isSynced: Bool

    // 业务字段
    var title: String
    var isCompleted: Bool

    // CloudKit 配置
    static let zoneName = "TaskZone"
    static let recordType = "Task"

    // GRDB 列映射
    enum Columns: String, CodingKey, ColumnExpression {
        case id, title, isCompleted, createAt, updateAt, isDeleted, isSynced
    }

    // 从 CloudKit Record 创建
    init(record: CKRecord) throws {
        self.id = record.recordID.recordName
        self.title = record["title"] as? String ?? ""
        self.isCompleted = record["isCompleted"] as? Bool ?? false
        self.createAt = record.creationDate ?? Date()
        self.updateAt = record.modificationDate ?? Date()  // 关键：使用服务器时间
        self.isDeleted = false
        self.isSynced = true
    }

    // 转换为 CloudKit Record
    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["title"] = title
        record["isCompleted"] = isCompleted
        record["updateAt"] = updateAt  // 必须：用于冲突检测
        return record
    }

    // GRDB 持久化
    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.title] = title
        container[Columns.isCompleted] = isCompleted
        container[Columns.createAt] = createAt
        container[Columns.updateAt] = updateAt
        container[Columns.isDeleted] = isDeleted
        container[Columns.isSynced] = isSynced
    }
}
```

### 2. 创建 Store

```swift
final class TaskStore: SyncableStore {
    typealias ModelType = Task
    let db: GRDBStore
    let cloud: CloudKitManager

    init(db: GRDBStore, cloud: CloudKitManager) {
        self.db = db
        self.cloud = cloud
    }

    func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("task_v1") { db in
            try db.create(table: "task") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("isCompleted", .boolean).notNull().defaults(to: false)
                t.column("createAt", .datetime).notNull()
                t.column("updateAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("isSynced", .boolean).notNull().defaults(to: false)
            }
        }
    }
}
```

### 3. 初始化协调器

```swift
let dbPath = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("app.sqlite").path

let coordinator = try SyncCoordinator(
    databasePath: dbPath,
    containerID: "iCloud.com.yourcompany.app"
)

// 注册 Store 并执行数据库迁移
let taskStore = TaskStore(db: coordinator.db, cloud: coordinator.cloud)
try coordinator.registerStoresAndMigrate([taskStore])

// 完成异步初始化（创建 Zone 和 Subscription）
try await coordinator.setup(with: [])
```

### 4. 使用

```swift
// 创建
var task = Task(id: UUID().uuidString, title: "买牛奶")
try await taskStore.save(task)

// 查询
let all = try await taskStore.fetchAll()

// 修改
task.isCompleted = true
task.markModified()
try await taskStore.save(task)

// 删除
try await taskStore.delete(task.id)

// 全量同步
let results = try await coordinator.pushAllToCloud()

// 处理远程推送通知
try await coordinator.handleRemoteNotification(notification)
```

## 冲突解决

CloudDeck 使用 **Pull-Merge-Push** 策略，按优先级解决冲突：

| 优先级 | 条件 | 处理 |
|--------|------|------|
| 1（最高） | 记录同时在修改列表和删除列表中 | 跳过（边界情况） |
| 2 | 本地 `isDeleted == true` | 拒绝远端更新（保护删除意图） |
| 3 | 本地 `isSynced == false` | 拒绝远端更新（保护未保存的编辑） |
| 4（最低） | 比较时间戳 | Last-Write-Wins（服务器时间） |

**核心理念**：`isSynced == false` 表示"用户正在操作"，拥有绝对优先级，任何远端变更都不会覆盖它。

## Cloud-First CRUD 策略

`SyncCoordinator+CRUD` 扩展提供另一种操作模式：

1. **先写云端** — 直接尝试写入 CloudKit
2. **逐条检查结果** — 每条记录独立成功/失败
3. **始终持久化到本地** — 无论云端结果如何，数据一定写入 GRDB
4. **标记同步状态** — 云端成功标记 `synced`，失败标记 `modified`（下次重试）

效果：
- 在线时：数据即时同步
- 离线时：数据保存到本地，下次推送时同步

## 单元测试

框架提供协议抽象，支持依赖注入：

```swift
// Mock CloudKit
final class MockCloud: CloudKitProtocol {
    func modify(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> CKModifyResults {
        // 返回测试数据
    }
}

// Mock GRDB（使用内存数据库）
final class MockDB: GRDBStoreProtocol {
    let queue: DatabaseQueue = try! DatabaseQueue()
    // ...
}
```

## 最佳实践

1. **修改模型字段后必须调用 `markModified()`** — 确保变更会被同步
2. **`init(record:)` 中使用 `record.modificationDate`** — 保证时间基准统一
3. **不要将 `isDeleted`/`isSynced` 存入 CloudKit** — 这是本地状态字段
4. **处理 `SyncError`** — 特别是 `.modelNotFound` 和 `.syncFailed`
5. **尽早调用 `setup()`** — 应用启动后立即执行，创建 Zone 和 Subscription
6. **注册远程通知** — 收到推送后转发给 `handleRemoteNotification` 实现自动同步

## 声明式数据库查询（@Query）

CloudDeck 提供数据库实时观察的基础设施（`DBObserver`、`DBRequest`、内置 Requests），使用方只需在自己项目中创建一个约 10 行的 property wrapper 即可获得类似 `@FetchRequest`（Core Data）/ `@Query`（SwiftData）的体验。

### 第一步：在你的项目中创建 property wrapper

```swift
import CloudDeck
import SwiftUI

@MainActor
@propertyWrapper
struct Query<Request: DBRequest>: DynamicProperty {
    @State private var observer: DBObserver<Request.Value>

    var wrappedValue: Request.Value { observer.value }

    init(_ request: Request, default defaultValue: Request.Value) {
        _observer = State(initialValue: DBObserver(
            dbQueue: AppCenter.shared.coordinator.db.queue,  // 替换为你的 dbQueue 来源
            defaultValue: defaultValue
        ) { db in try request.fetch(db) })
    }
}
```

### 第二步：在视图中使用

```swift
// 使用内置 FetchAll
@Query(FetchAll<Tag>(), default: []) var allTags

// 带条件过滤 + 排序
@Query(FetchAll<Task> {
    $0.filter(Task.Columns.isDeleted == false).order(Task.Columns.createAt.desc)
}, default: []) var activeTasks

// 使用内置 FetchOne
@Query(FetchOne<Task>(key: "task-id"), default: nil) var task

// 使用内置 FetchCount
@Query(FetchCount<Task>(), default: 0) var totalTasks
@Query(FetchCount<Task> {
    $0.filter(Task.Columns.isCompleted == false)
}, default: 0) var incompleteCount

// 使用内置 Exists
@Query(Exists<Task> {
    $0.filter(Task.Columns.isCompleted == false)
}, default: false) var hasIncompleteTasks

// 自定义查询请求
@Query(GameStatsRequest(gameId: "minesweeper"), default: nil) var stats

// 在 init 中动态构造
struct GameDetailView: View {
    @Query<GameStatsRequest> var stats: GameStats?

    init(gameId: String) {
        _stats = Query(GameStatsRequest(gameId: gameId), default: nil)
    }
}
```

### 自定义查询请求

实现 `DBRequest` 协议：

```swift
struct ActiveTasksRequest: DBRequest {
    func fetch(_ db: Database) throws -> [Task] {
        try Task
            .filter(Task.Columns.isDeleted == false)
            .order(Task.Columns.createAt.desc)
            .fetchAll(db)
    }
}
```

### 内置请求

| 请求 | 返回类型 | 说明 |
|------|----------|------|
| `FetchAll<T>()` | `[T]` | 获取全部记录 |
| `FetchAll<T> { ... }` | `[T]` | 带条件获取记录（filter/order/limit） |
| `FetchOne<T>(key:)` | `T?` | 按主键查询单条记录 |
| `FetchOne<T> { ... }` | `T?` | 自定义条件查询单条记录 |
| `FetchCount<T>()` | `Int` | 全表记录数 |
| `FetchCount<T> { ... }` | `Int` | 满足条件的记录数 |
| `Exists<T>(key:)` | `Bool` | 按主键检查记录是否存在 |
| `Exists<T> { ... }` | `Bool` | 自定义条件检查记录是否存在 |

### 工作原理

1. 你的 `@Query` wrapper 在视图初始化时创建 `DBObserver`
2. `DBObserver` 通过 GRDB `ValueObservation` 订阅数据库变化
3. 当相关表发生写入/更新/删除时，查询自动重新执行
4. 新值通过 `withAnimation` 更新，触发 SwiftUI 视图刷新

### 设计理念

CloudDeck 不提供现成的 `@DBQuery` wrapper，因为：
- 避免全局可变状态（无需 App 启动时注入配置）
- 编译时安全（直接引用你的 db 来源，不会 runtime crash）
- 你可以自由命名（`@Query`、`@DB`、`@Live` ...）
- 每个项目按自己的 DI 方式提供 `DatabaseQueue`

## 目录结构

```
Sources/CloudDeck/
├── CloudDeck.swift                    # 模块入口，re-export GRDB
├── Protocols/                         # 协议定义
│   ├── SyncableProtocol.swift         #   核心可同步模型协议
│   ├── CloudKitSyncable.swift         #   CloudKit 双向转换协议
│   ├── GRDBSyncable.swift             #   GRDB 级联持久化协议
│   └── CascadePersistable.swift       #   级联操作接口
├── Core/                              # 核心同步引擎
│   ├── SyncCoordinator.swift          #   中心协调器（Zone/Subscription 管理）
│   ├── SyncCoordinator+CRUD.swift     #   Cloud-First 增删改查扩展
│   ├── SyncableStore.swift            #   通用 Store（CRUD + Pull-Merge-Push）
│   └── AnySyncableStore.swift         #   类型擦除包装器
├── Storage/                           # 存储层（本地 + 云端）
│   ├── CloudKitManager.swift          #   CloudKit 私有数据库封装
│   ├── CloudKitProtocol.swift         #   CloudKit 依赖注入协议
│   ├── GRDBStore.swift                #   GRDB 数据库 + Change Token 缓存
│   └── GRDBStoreProtocol.swift        #   GRDB 依赖注入协议
├── Definitions/                       # 常量与类型定义
│   ├── Definitions.swift              #   类型别名（CKRecordType 等）
│   └── SyncError.swift                #   统一错误类型
└── Helpers/                           # 工具与辅助
    ├── DBQuery.swift                  #   数据库查询基础设施（DBRequest/DBObserver/内置Requests）
    ├── DebugDBView.swift              #   数据库调试视图（表列表/结构/记录浏览）
    ├── Extensions.swift               #   内部工具方法（toMap 等）
    └── Logger.swift                   #   OSLog 日志分类（cloud/grdb/sync）
```

## 示例代码

`Examples/` 目录提供了一个完整的「待办任务」应用示例：

```
Examples/
├── TaskCenter.swift                    # 业务层单例入口
└── Stores/
    ├── Task/                           # 主实体
    │   ├── Task.swift                  #   数据模型 + Columns + encode
    │   ├── Task+CloudKit.swift         #   init(record:) + toCKRecord(in:)
    │   └── TaskStore.swift             #   迁移 + 高级查询 + Combine 观察
    ├── Tag/                            # 辅助实体
    │   ├── Tag.swift
    │   ├── Tag+CloudKit.swift
    │   └── TagStore.swift
    └── TaskTag/                        # 多对多关联表
        ├── TaskTag.swift               #   关联模型（taskID + tagID）
        ├── TaskTag+CloudKit.swift
        └── TaskTagStore.swift          #   外键索引 + 关联查询方法
```

### 推荐的文件组织模式

每个数据模型遵循 **三文件模式**：

| 文件 | 职责 |
|------|------|
| `Model.swift` | 结构体定义、Columns 枚举、`encode(to:)` 持久化、计算属性 |
| `Model+CloudKit.swift` | `init(record:)` 和 `toCKRecord(in:)` 分离到独立文件 |
| `ModelStore.swift` | `registerMigrations` + 自定义查询方法 + Combine 观察 |

### 业务层入口模式

```swift
@MainActor
public class TaskCenter {
    public static let shared = TaskCenter()

    public let coordinator: SyncCoordinator
    public let taskStore: TaskStore
    public let tagStore: TagStore
    public let taskTagStore: TaskTagStore

    private init() {
        coordinator = try! SyncCoordinator(
            databasePath: dbPath,
            containerID: "iCloud.com.example.app"
        )
        taskStore = TaskStore(db: coordinator.db, cloud: coordinator.cloud)
        tagStore = TagStore(db: coordinator.db, cloud: coordinator.cloud)
        taskTagStore = TaskTagStore(db: coordinator.db, cloud: coordinator.cloud)

        try! coordinator.registerStoresAndMigrate([taskStore, tagStore, taskTagStore])
    }

    public func setup() async {
        try? await coordinator.setup(with: [])
        try? await coordinator.pullAllRecordFromCloud()
    }
}
```

### 关联表模式（多对多）

关联表只存两个外键 + 同步元数据，并为外键建索引加速查询：

```swift
// 迁移时建索引
try db.create(index: "idx_taskTag_taskID", on: "taskTag", columns: ["taskID"])
try db.create(index: "idx_taskTag_tagID", on: "taskTag", columns: ["tagID"])

// Store 中提供关联查询方法
func addTag(_ tagID: String, toTask taskID: String) async throws { ... }
func removeTag(_ tagID: String, fromTask taskID: String) async throws { ... }
func fetchTagIDs(forTaskID taskID: String) async throws -> [String] { ... }
```

### 高级查询 & 关系填充

Store 可提供 `fetchFull*` 方法，通过关联表查询后填充模型的非持久化字段：

```swift
func fetchFullTask(id: String) async throws -> Task? {
    try await db.queue.read { db in
        guard var task = try Task.fetchOne(db, key: id) else { return nil }
        let tagRelations = try TaskTag
            .filter(Column("taskID") == id && Column("isDeleted") == false)
            .fetchAll(db)
        task.tags = try Tag
            .filter(tagRelations.map { $0.tagID }.contains(Column("id")))
            .fetchAll(db)
        return task
    }
}
```

## 许可证

MIT
