# CloudDeck Agent Skill

当其他项目需要使用 CloudDeck 框架实现 CloudKit + GRDB 数据同步时，参照本文件指导。

## 框架简介

CloudDeck 是一个基于 Pull-Merge-Push 策略的 Swift 数据同步框架，结合 CloudKit（iCloud 私有数据库）与 GRDB（本地 SQLite），实现离线优先的数据同步。

## 集成方式

在项目的 `Package.swift` 中添加依赖：

```swift
dependencies: [
    .package(url: "https://github.com/JyHu/CloudDeck", branch: "main")
    // 或本地路径：
    // .package(path: "../CloudDeck")
]
```

Target 中引用：

```swift
.target(name: "YourTarget", dependencies: ["CloudDeck"])
```

## 核心概念

- **SyncableProtocol**：所有需要同步的模型必须遵守的协议，要求 5 个字段：`id`、`createAt`、`updateAt`、`isDeleted`、`isSynced`
- **SyncableStore**：每个模型对应一个 Store，负责 CRUD 和同步操作
- **SyncCoordinator**：中心协调器，管理所有 Store、Zone、Subscription
- **CloudKitManager**：CloudKit 私有数据库的封装
- **GRDBStore**：本地 SQLite 数据库的封装

## 推荐的代码组织方式

### 目录结构

每个使用 CloudDeck 的项目，建议按以下方式组织业务层代码：

```
YourApp/
├── AppCenter.swift              # 业务层单例入口，持有 coordinator 和所有 store
└── Stores/
    ├── ModelA/                   # 每个数据模型一个文件夹
    │   ├── ModelA.swift          #   模型定义
    │   ├── ModelA+CloudKit.swift #   CloudKit 序列化
    │   └── ModelAStore.swift     #   Store（迁移 + 自定义查询）
    ├── ModelB/
    │   ├── ModelB.swift
    │   ├── ModelB+CloudKit.swift
    │   └── ModelBStore.swift
    └── RelationAB/              # 关联表（如果有多对多关系）
        ├── RelationAB.swift
        ├── RelationAB+CloudKit.swift
        └── RelationABStore.swift
```

### 三文件模式

每个数据模型拆分为三个文件：

1. **Model.swift** — 结构体定义
   - 遵守 `SyncableProtocol`
   - 定义 `Columns` 枚举（`CodingKey` + `ColumnExpression`）
   - 实现 `encode(to: PersistenceContainer)`
   - 声明 `static let zoneName` 和 `static let recordType`
   - 业务字段、计算属性

2. **Model+CloudKit.swift** — CloudKit 序列化
   - `init(record: CKRecord) throws`：从云端记录创建模型，`updateAt` 必须用 `record.modificationDate`
   - `func toCKRecord(in zoneID:) -> CKRecord`：转换为云端记录，必须写入 `updateAt`，不要写入 `isDeleted`/`isSynced`

3. **ModelStore.swift** — 数据库 Store
   - 遵守 `SyncableStore`
   - 实现 `registerMigrations(_:)` 建表
   - 提供自定义查询方法（如 `fetchIncomplete()`）
   - 可提供 Combine 观察方法

## 初始化模板

### 业务层入口（单例）

```swift
import CloudDeck

@MainActor
public class AppCenter {
    public static let shared = AppCenter()

    public let coordinator: SyncCoordinator
    public let taskStore: TaskStore
    public let tagStore: TagStore

    private init() {
        let dbPath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.sqlite").path

        coordinator = try! SyncCoordinator(
            databasePath: dbPath,
            containerID: "iCloud.com.yourcompany.app"
        )

        taskStore = TaskStore(db: coordinator.db, cloud: coordinator.cloud)
        tagStore = TagStore(db: coordinator.db, cloud: coordinator.cloud)

        try! coordinator.registerStoresAndMigrate([taskStore, tagStore])
    }

    /// 应用启动后调用
    public func setup() async {
        try? await coordinator.setup(with: [])
        try? await coordinator.pullAllRecordFromCloud()
    }
}
```

### 在 App 入口调用

```swift
@main
struct MyApp: App {
    init() {
        Task { await AppCenter.shared.setup() }
    }
}
```

### 处理远程通知

```swift
func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
) {
    let notification = CKNotification(fromRemoteNotificationDictionary: userInfo)
    Task {
        try? await AppCenter.shared.coordinator.handleRemoteNotification(notification)
        completionHandler(.newData)
    }
}
```

## 模型定义规范

### 必需字段

每个 `SyncableProtocol` 模型必须包含：

```swift
var id: String          // UUID 字符串，主键
var createAt: Date      // 创建时间
var updateAt: Date      // 最后修改时间（冲突解决关键字段）
var isDeleted: Bool     // 软删除标记
var isSynced: Bool      // 同步状态
```

### 静态属性

```swift
static let zoneName: CKRecordZone.Name = "YourZone"
static let recordType: CKRecordType = "YourModel"
```

### CloudKit 序列化要点

- `init(record:)` 中：`updateAt` 必须使用 `record.modificationDate`，`isSynced` 设为 `true`
- `toCKRecord(in:)` 中：必须写入 `updateAt`，不要写入 `createAt`、`isDeleted`、`isSynced`

## CRUD 操作

### 通过 Store 操作（推荐）

```swift
// 保存（Cloud-First：先尝试云端，失败则标记待同步）
try await store.save(model)

// 批量保存
try await store.saveAll(models)

// 查询
let item = try await store.fetch(id: "xxx")
let all = try await store.fetchAll()

// 删除（Cloud-First：云端成功则硬删，失败则软删）
try await store.delete(model)
try await store.delete("id")

// 推送未同步数据（Pull-Merge-Push）
let result = try await store.pushToCloud()
```

### 通过 Coordinator 批量操作

```swift
// 全量推送
let results = try await coordinator.pushAllToCloud()

// 全量拉取
try await coordinator.pullAllRecordFromCloud()

// Cloud-First 保存（支持异构模型）
try await coordinator.save(model)
try await coordinator.delete(model)
```

## 修改数据的正确姿势

```swift
var task = try await taskStore.fetch(id: "xxx")!
task.title = "新标题"
task.markModified()   // 必须调用！标记为需要同步
try await taskStore.save(task)
```

## 关联表（多对多）

关联模型只需存储两个外键：

```swift
struct TaskTag: SyncableProtocol {
    let id: String
    let taskID: String   // 外键
    let tagID: String    // 外键
    // + 同步字段 ...
}
```

Store 迁移时为外键建索引：

```swift
try db.create(index: "idx_taskTag_taskID", on: "taskTag", columns: ["taskID"])
try db.create(index: "idx_taskTag_tagID", on: "taskTag", columns: ["tagID"])
```

## 冲突解决规则

按优先级排序：

1. 本地 `isDeleted == true` → 拒绝远端更新（保护用户删除意图）
2. 本地 `isSynced == false` → 拒绝远端更新（保护正在编辑的数据）
3. 比较 `updateAt` 与 `modificationDate` → 时间新的胜出

## 注意事项

- 所有 Store 共享同一个 `GRDBStore` 和 `CloudKitManager` 实例
- 同一个 Zone 可以包含多个 recordType
- `registerStoresAndMigrate` 是同步方法，可在 `init` 中调用
- `setup()` 是异步方法，需要在 Task 中调用
- 框架使用 OSLog 记录日志，可通过 `Logger.cloud`/`Logger.grdb`/`Logger.sync` 查看
