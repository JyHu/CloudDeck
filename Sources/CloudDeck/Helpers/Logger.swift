//
//  Logger.swift
//  CloudDeck
//

import OSLog

/// 日志分类，对应 OSLog 的 `category` 字段。
///
/// 每个分类使用独立的 `subsystem:category` 组合写入统一日志系统，
/// 可在 Console.app / Xcode 中按分类过滤 CloudDeck 的日志。
public enum CDLogCategory: String, Identifiable, Sendable {
    /// CloudKit 网络层：Zone、Subscription 及云端记录的读写
    case cloudKit = "CloudKit"
    /// 本地数据库层：GRDB / SQLite 的读写与迁移
    case grdb = "GRDB"
    /// 同步逻辑层：Pull-Merge-Push、冲突解决、后台同步
    case sync = "Sync"

    public var id: String { rawValue }
}

/// 日志级别，与 OSLog 的级别一一对应。
public enum CDLogLevel: String, Identifiable, Sendable {
    /// 调试信息：同步细节等开发期才关心的内容
    case debug
    /// 常规信息：同步流程的关键节点
    case info
    /// 警告：预期内的异常（如服务端记录冲突），不影响主流程
    case warn
    /// 错误：需要关注或人工介入的问题
    case error

    public var id: String { rawValue }
}

/// 日志回调代理。
///
/// 实现该协议并赋值给 `CDLogCenter.shared.delegate` 后，
/// CloudDeck 框架内产生的所有日志都会实时回调给你，
/// 便于接入自己的日志上报体系（Crashlytics、自建后台等）。
///
/// - Note: 协议继承 `NSObjectProtocol` 是为了让 `delegate` 可以被
///   `weak` 持有；回调在产生日志的线程上**同步执行**（可能是后台
///   同步线程），代理内部应避免耗时操作并自行保证线程安全。
public protocol LoggerDelegate: NSObjectProtocol {
    /// 收到一条 CloudDeck 日志。
    ///
    /// - Parameters:
    ///   - category: 日志分类
    ///   - level: 日志级别
    ///   - message: 日志正文
    ///   - file: 产生日志的源文件（`#fileID`）
    ///   - function: 产生日志的函数（`#function`）
    ///   - line: 产生日志的行号（`#line`）
    func cloudDeckLogWith(category: CDLogCategory, level: CDLogLevel, message: String, file: StaticString, function: StaticString, line: UInt)
}

/// 日志输出器（框架内部使用）。
///
/// 封装 OSLog 输出，同时把日志转发给 `CDLogCenter.shared.delegate`。
/// 所有消息均以 `privacy: .public` 写入，可直接在 Console.app /
/// Xcode 中查看完整内容，无需配置隐私豁免。
internal struct CDLogger: Sendable {
    /// OSLog subsystem（框架标识）
    let subsystem: String
    /// 日志分类
    let category: CDLogCategory
    /// 底层 OSLog 实例
    let logger: Logger

    init(subsystem: String, category: CDLogCategory) {
        self.subsystem = subsystem
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// 输出 debug 级别日志
    func debug(
        _ message: String,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        log(message, level: .debug, file: file, function: function, line: line)
    }

    /// 输出 info 级别日志
    func info(
        _ message: String,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        log(message, level: .info, file: file, function: function, line: line)
    }

    /// 输出 warn 级别日志
    func warn(
        _ message: String,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        log(message, level: .warn, file: file, function: function, line: line)
    }

    /// 输出 error 级别日志
    func error(
        _ message: String,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        log(message, level: .error, file: file, function: function, line: line)
    }

    /// 统一输出入口：先写 OSLog，再回调 delegate。
    ///
    /// `file` / `function` / `line` 仅转发给 delegate 使用，
    /// OSLog 本身不记录调用位置。
    private func log(
        _ message: String,
        level: CDLogLevel,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        if CDLogCenter.shared.isLogEnable {
            switch level {
            case .debug:
                logger.debug("\(message, privacy: .public)")
            case .info:
                logger.info("\(message, privacy: .public)")
            case .warn:
                logger.warning("\(message, privacy: .public)")
            case .error:
                logger.error("\(message, privacy: .public)")
            }
        }

        CDLogCenter.shared.delegate?.cloudDeckLogWith(
            category: category,
            level: level,
            message: message,
            file: file,
            function: function,
            line: line
        )
    }
}

/// CloudDeck 日志中心。
///
/// 框架内部通过 `CDLogCenter.cloud` / `CDLogCenter.grdb` /
/// `CDLogCenter.sync` 输出日志（均为内部 API）；使用方通过设置
/// `CDLogCenter.shared.delegate` 接收这些日志，用于接入自己的
/// 日志收集或调试面板。
///
/// 使用示例：
/// ```swift
/// class LogHandler: NSObject, LoggerDelegate {
///     func cloudDeckLogWith(category: CDLogCategory, level: CDLogLevel,
///                           message: String, file: StaticString,
///                           function: StaticString, line: UInt) {
///         print("[\(category.rawValue)][\(level.rawValue)] \(message)")
///     }
/// }
///
/// CDLogCenter.shared.delegate = LogHandler()
/// ```
public class CDLogCenter {
    /// 全局单例。
    ///
    /// 日志可能来自任意线程（含后台同步线程），而 `delegate` 是
    /// `weak` 类约束属性，无法满足 `Sendable` 要求，故此处用
    /// `nonisolated(unsafe)` 规避 Swift 6 的并发检查。
    nonisolated(unsafe) public static let shared = CDLogCenter()

    /// 日志回调代理（weak 持有，避免循环引用）。
    ///
    /// 回调在产生日志的线程上同步执行，可能为后台线程；
    /// 代理需保证线程安全，不要在回调中做耗时操作。
    public weak var delegate: LoggerDelegate?
    
    /// 是否开启日志输出，
    public var isLogEnable: Bool = true

    /// CloudKit 网络层日志（Zone、Subscription、记录读写）
    internal static let cloud = CDLogger(subsystem: "com.auu.cloudDeck", category: .cloudKit)

    /// 本地数据库日志（SQLite 读写、迁移）
    internal static let grdb = CDLogger(subsystem: "com.auu.cloudDeck", category: .grdb)

    /// 同步逻辑日志（Pull-Merge-Push、冲突解决）
    internal static let sync = CDLogger(subsystem: "com.auu.cloudDeck", category: .sync)
}
