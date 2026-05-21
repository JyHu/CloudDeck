//
//  Tag.swift
//  CloudDeck Example
//
//  示例：标签模型
//

import Foundation
import CloudKit
import CloudDeck

public struct Tag: SyncableProtocol, Hashable {
    public enum Columns: String, CodingKey, ColumnExpression {
        case id, createAt, updateAt, isDeleted, isSynced
        case name, color
    }

    // MARK: - Sync Metadata

    public var createAt: Date = Date()
    public var updateAt: Date = Date()
    public var isDeleted: Bool = false
    public var isSynced: Bool = false

    public static let zoneName: CKRecordZone.Name = "TaskZone"  // 与 Task 同一个 Zone
    public static let recordType: CKRecordType = "Tag"

    // MARK: - Primary Key

    public let id: String

    // MARK: - Business Fields

    public var name: String = ""
    public var color: String?  // Hex color code, e.g. "#FF5733"

    // MARK: - Init

    public init(id: String = UUID().uuidString, name: String = "") {
        self.id = id
        self.name = name
    }

    // MARK: - GRDB Persistence

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.createAt] = createAt
        container[Columns.updateAt] = updateAt
        container[Columns.isDeleted] = isDeleted
        container[Columns.isSynced] = isSynced
        container[Columns.name] = name
        container[Columns.color] = color
    }
}
