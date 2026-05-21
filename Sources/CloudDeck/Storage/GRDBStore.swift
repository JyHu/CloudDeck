//
//  GRDBStore.swift
//  CloudDeck
//

import GRDB
import OSLog
import CloudKit

/// 本地数据库管理对象，封装所有 GRDB（SQLite）数据库操作
///
/// **职责**：
/// - 管理 SQLite 数据库文件的访问（通过 DatabaseQueue）
/// - 持久化存储 CloudKit 的 Change Token（用于增量同步）
/// - 作为所有 Store 访问本地数据库的统一入口
///
/// **为什么使用 Actor**：
/// - DatabaseQueue 内部已经是线程安全的
/// - 使用 Actor 是为了与 CloudKitManager 保持一致的异步接口
/// - 方便未来扩展其他可能需要隔离的状态
///
/// **关于 DatabaseQueue**：
/// - GRDB 提供的线程安全数据库队列
/// - 所有读写操作都在后台串行队列中执行
/// - 确保 SQLite 的线程安全访问
///
/// **使用场景**：
/// ```swift
/// let db = try GRDBStore(path: "/path/to/database.sqlite")
/// await db.cacheCKServerChangeToken(token, for: "subscription_id")
/// let token = await db.queryCKServerChangeToken(for: "subscription_id")
/// ```
public class GRDBStore {
    /// GRDB 数据库队列，管理对 SQLite 文件的串行访问
    /// 所有数据库操作（读、写）都通过这个队列执行
    public let queue: DatabaseQueue
    
    /// 初始化数据库管理器
    /// - Parameter path: SQLite 数据库文件的本地路径
    ///   如果文件不存在，会自动创建
    ///   如果路径不存在，会抛出错误
    /// - Throws: 数据库创建或打开失败时的错误
    init(path: String) throws {
        self.queue = try DatabaseQueue(path: path)
    }
    
    /// 使用内存数据库的方式初始化
    init() throws {
        self.queue = try DatabaseQueue()
    }
}

public extension GRDBStore {
    /// 缓存 CloudKit 的 Change Token 到本地数据库
    ///
    /// **什么是 Change Token**：
    /// - CloudKit 返回的增量同步标记
    /// - 记录了"从哪个时间点开始拉取变动"
    /// - 每次成功拉取后，CloudKit 会返回新的 token
    /// - 下次拉取时传入这个 token，只获取增量数据
    ///
    /// **为什么需要持久化 Change Token**：
    /// - 如果不保存，每次都要全量拉取数据（性能差）
    /// - 保存后，应用重启也能从上次的位置继续同步
    /// - 避免重复拉取已经同步过的数据
    ///
    /// **存储方式**：
    /// - Change Token 是一个不透明对象（CKServerChangeToken）
    /// - 使用 NSKeyedArchiver 序列化为 Data 存储
    /// - 使用 subscriptionID 作为主键，每个订阅独立存储
    ///
    /// **错误处理**：
    /// - 缓存失败不会抛出错误，只记录日志
    /// - 原因：缓存失败不应该中断同步流程
    /// - 最坏情况：下次全量拉取，不影响数据正确性
    ///
    /// - Parameters:
    ///   - token: CloudKit 返回的 Change Token
    ///   - subscriptionID: 订阅 ID，作为存储的唯一标识
    func cacheCKServerChangeToken(_ token: CKServerChangeToken, for subscriptionID: String) async {
        do {
            try await queue.write { db in
                // 将 Change Token 序列化为 Data
                // requiringSecureCoding: true 确保安全的序列化
                let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
                
                // 创建记录并保存
                // save() 方法会自动判断是插入还是更新（基于主键）
                let record = CKServerChangeTokenRecord(subscriptionID: subscriptionID, token: data)
                try record.save(db)
            }
        } catch {
            // 缓存失败只记录错误，不抛出异常
            // 不影响同步流程，最坏情况下次全量拉取
            Logger.grdb.error("Cache CKServerChangeToken failed for subscriptionID: \(subscriptionID), error: \(error)")
        }
    }
    
    /// 查询之前缓存的 Change Token
    ///
    /// **使用场景**：
    /// - 在拉取 CloudKit 数据前，先查询上次的 token
    /// - 如果有 token，传给 CloudKit 进行增量拉取
    /// - 如果没有 token（首次同步），传 nil 进行全量拉取
    ///
    /// **返回值**：
    /// - 返回之前保存的 Change Token（如果存在）
    /// - 返回 nil（如果从未保存过，或反序列化失败）
    ///
    /// **错误处理**：
    /// - 查询失败不会抛出错误，返回 nil
    /// - 原因：查询失败应该降级为全量拉取，而不是中断流程
    ///
    /// - Parameter subscriptionID: 订阅 ID
    /// - Returns: Change Token（如果存在），否则返回 nil
    func queryCKServerChangeToken(for subscriptionID: String) async -> CKServerChangeToken? {
        do {
            return try await queue.read { db in
                // 根据主键查询记录
                if let tokenData = try CKServerChangeTokenRecord.fetchOne(db, key: subscriptionID)?.token {
                    // 将 Data 反序列化为 Change Token
                    return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: tokenData)
                } else {
                    // 没有找到记录，返回 nil（首次同步）
                    return nil
                }
            }
        } catch {
            // 查询失败记录错误，返回 nil（降级为全量拉取）
            Logger.grdb.error("Query CKServerChangeToken failed for subscriptionID: \(subscriptionID), error: \(error)")
        }
        
        return nil
    }
}

/// Change Token 的本地存储模型
///
/// **字段说明**：
/// - subscriptionID: 订阅 ID，作为主键（PrimaryKey）
/// - token: 序列化后的 Change Token 数据
///
/// **为什么是 private**：
/// - 这是内部实现细节，外部不需要直接访问
/// - 所有访问都通过 GRDBStore 的方法进行
///
/// **协议说明**：
/// - Codable: 支持自动编码/解码（用于序列化）
/// - PersistableRecord: 支持保存到数据库
/// - FetchableRecord: 支持从数据库查询
private struct CKServerChangeTokenRecord: Codable, PersistableRecord, FetchableRecord {
    let subscriptionID: String
    let token: Data
}
