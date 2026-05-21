//
//  Task.swift
//  CloudDeck Example
//
//  示例：待办任务模型
//

import Foundation
import CloudKit
import CloudDeck

public struct Task: SyncableProtocol, Hashable {
    public enum Columns: String, CodingKey, ColumnExpression {
        case id, createAt, updateAt, isDeleted, isSynced
        case title, note, isCompleted, priority, dueDate
    }

    // MARK: - Sync Metadata

    public var createAt: Date = Date()
    public var updateAt: Date = Date()
    public var isDeleted: Bool = false
    public var isSynced: Bool = false

    public static let zoneName: CKRecordZone.Name = "TaskZone"
    public static let recordType: CKRecordType = "Task"

    // MARK: - Primary Key

    public let id: String

    // MARK: - Business Fields

    public var title: String = ""
    public var note: String?
    public var isCompleted: Bool = false
    public var priority: Priority = .medium
    public var dueDate: Date?

    // MARK: - Relationships（不存储在本表，通过关联表查询）

    public var tags: [Tag] = []

    // MARK: - Computed Properties

    public var isOverdue: Bool {
        guard let dueDate, !isCompleted else { return false }
        return dueDate < Date()
    }

    // MARK: - Init

    public init(id: String = UUID().uuidString, title: String = "") {
        self.id = id
        self.title = title
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Columns.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.createAt = try container.decodeIfPresent(Date.self, forKey: .createAt) ?? Date()
        self.updateAt = try container.decodeIfPresent(Date.self, forKey: .updateAt) ?? Date()
        self.isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        self.isSynced = try container.decodeIfPresent(Bool.self, forKey: .isSynced) ?? false
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        self.isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        self.priority = try container.decodeIfPresent(Priority.self, forKey: .priority) ?? .medium
        self.dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
    }

    // MARK: - GRDB Persistence

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.createAt] = createAt
        container[Columns.updateAt] = updateAt
        container[Columns.isDeleted] = isDeleted
        container[Columns.isSynced] = isSynced
        container[Columns.title] = title
        container[Columns.note] = note
        container[Columns.isCompleted] = isCompleted
        container[Columns.priority] = priority.rawValue
        container[Columns.dueDate] = dueDate
    }

    // MARK: - Hashable（忽略 tags，因为它不存储在本表）

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: Task, rhs: Task) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 优先级枚举

public enum Priority: String, Codable, Sendable {
    case low
    case medium
    case high
    case urgent
}
