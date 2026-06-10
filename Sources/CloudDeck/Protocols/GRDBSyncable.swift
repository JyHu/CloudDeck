//
//  GRDBSyncable.swift
//  CloudDeck
//

import GRDB

/// GRDB 可同步模型协议
///
/// 聚焦于单模型持久化能力：查询、保存、删除和表信息。
public protocol GRDBSyncableProtocol:
    Identifiable,
    PersistableRecord,
    FetchableRecord,
    TableRecord,
    Codable,
    Sendable {}
