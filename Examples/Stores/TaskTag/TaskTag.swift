//
//  TaskTag.swift
//  CloudDeck Example
//
//  示例：Task ↔ Tag 多对多关联模型
//  类似 FamCenter 中的 ParentChildRelation / SpouseRelation
//

import Foundation
import CloudKit
import CloudDeck

public struct TaskTag: SyncableProtocol, Hashable {
    public enum Columns: String, CodingKey, ColumnExpression {
        case id, createAt, updateAt, isDeleted, isSynced
        case taskID, tagID
    }

    // MARK: - Sync Metadata

    public var createAt: Date = Date()
    public var updateAt: Date = Date()
    public var isDeleted: Bool = false
    public var isSynced: Bool = false

    public static let zoneName: CKRecordZone.Name = "TaskZone"  // 与 Task/Tag 同 Zone
    public static let recordType: CKRecordType = "TaskTag"

    // MARK: - Primary Key

    public let id: String

    // MARK: - Foreign Keys

    public let taskID: String
    public let tagID: String

    // MARK: - Init

    public init(taskID: String, tagID: String) {
        self.id = "\(taskID)_\(tagID)"  // 组合键确保唯一性
        self.taskID = taskID
        self.tagID = tagID
    }

    // MARK: - GRDB Persistence

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.createAt] = createAt
        container[Columns.updateAt] = updateAt
        container[Columns.isDeleted] = isDeleted
        container[Columns.isSynced] = isSynced
        container[Columns.taskID] = taskID
        container[Columns.tagID] = tagID
    }
}
