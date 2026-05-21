//
//  GRDBSyncable.swift
//  CloudDeck
//

import GRDB

/// GRDB 可同步模型协议
///
/// 为 GRDB 数据库模型提供级联持久化能力（Cascade Persistence），
/// 支持父子关系的逍归插入、更新和删除。
///
/// 核心概念：
/// - `cascadeInsert`：插入记录及其所有子表记录
/// - `cascadeDelete`：删除记录及其所有子表记录
/// - `cascadeUpsert`：智能更新记录（存在则更新，不存在则插入）
///
/// 这些方法的默认实现为简单的单表操作，
/// 具体模型（如 Person）可以重写以实现关联表的级联操作。
public protocol GRDBSyncableProtocol: Identifiable, PersistableRecord, FetchableRecord, TableRecord, CascadePersistable, Codable, Sendable {
    func cascadeInsert(_ db: Database) throws
    func cascadeDelete(_ db: Database) throws
    func cascadeUpsert(_ db: Database) throws
}

extension GRDBSyncableProtocol {
    public func cascadeInsert(_ db: Database) throws {
        try insert(db)
    }

    public func cascadeUpsert(_ db: Database) throws {
        try upsert(db)
    }

    public func cascadeDelete(_ db: Database) throws {
        try delete(db)
    }
}

extension GRDBSyncableProtocol {
    /// 单子记录的级联操作：更新或删除
    ///
    /// - 如果新值存在：执行 upsert
    /// - 如果新值为 nil 但旧值存在：执行删除（用户清除了该子记录）
    /// - 如果两者都为 nil：不做任何操作
    func cascadeUpsert<T: GRDBSyncableProtocol>(newChild: T?, storedChild: T?, in db: Database) throws {
        if let newChild {
            try newChild.cascadeUpsert(db)
        } else if let storedChild {
            try storedChild.cascadeDelete(db)
        }
    }
    
    /// 多子记录的级联操作：差异比对 + 增删改
    ///
    /// 采用“差异比对”算法而非“全量删后重建”，以减少不必要的数据库 I/O：
    ///
    /// 算法流程：
    /// 1. 快速路径：如果新列表为空但旧列表有数据 → 全量删除旧数据
    /// 2. 快速路径：如果新列表有数据但旧列表为空 → 全量插入新数据
    /// 3. 正常路径：
    ///    a. 将旧数据构建为 `storedMap`（key = id, value = 旧记录）
    ///    b. 遍历新数据：
    ///       - 如果在 storedMap 中存在（同 ID）→ upsert 更新，并从 storedMap 移除
    ///       - 如果不存在 → insert 插入（新增子记录）
    ///    c. storedMap 中剩余的记录 → delete 删除（孤儿记录，已不在新数据中）
    func cascadeUpsert<T: GRDBSyncableProtocol>(newChildren: [T]?, storedChildren: [T]?, in db: Database) throws {
        // 快速路径：新数据为空而旧数据存在 → 全量清除
        if (newChildren == nil || newChildren?.isEmpty == true) && storedChildren != nil {
            try storedChildren?.forEach {
                try $0.cascadeDelete(db)
            }
            
            return
        // 快速路径：新数据存在而旧数据为空 → 全量插入
        } else if newChildren != nil && (storedChildren == nil || storedChildren?.isEmpty == true) {
            try newChildren?.forEach {
                try $0.cascadeInsert(db)
            }
            
            return
        }
        
        guard let newChildren, let storedChildren else {
            return
        }
        
        // 正常路径：构建旧数据的索引映射，用于快速查找
        var storedMap: [T.ID: T] = [:]
        
        for storedChild in storedChildren {
            storedMap[storedChild.id] = storedChild
        }
        
        // 遍历新数据：有匹配的则更新，无匹配的则插入
        for newChild in newChildren {
            if storedMap.removeValue(forKey: newChild.id) != nil {
                // 旧数据中存在同 ID 记录 → 更新（同时从 storedMap 移除，避免被后续删除）
                try newChild.cascadeUpsert(db)
            } else {
                // 旧数据中不存在 → 新增记录
                try newChild.cascadeInsert(db)
            }
        }
        
        // storedMap 中剩余的记录是孤儿（新数据中不再包含），执行级联删除
        for (_, child) in storedMap {
            try child.cascadeDelete(db)
        }
    }
}
