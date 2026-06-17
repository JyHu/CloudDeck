//
//  SyncableStore+Query.swift
//  CloudDeck
//
//  Created by hujinyou on 2026/6/10.
//

import GRDB

public extension SyncableStore {
    /// Check if a record exists by ID.
    func isExists(id: String, isDeleted: Bool = false) async throws -> Bool {
        try await db.queue.read { db in
            try !ModelType
                .filter(Column.Basic.isDeleted == isDeleted)
                .filter(Column.Basic.id == id)
                .isEmpty(db)
        }
    }
        
    /// Fetch records where a column matches a LIKE pattern.
    func recordsLike(_ pattern: String, column: Column, isDeleted: Bool = false) async throws -> [ModelType] {
        try await db.queue.read { db in
            try ModelType
                .filter(column.like(pattern))
                .filter(Column.Basic.isDeleted == isDeleted)
                .fetchAll(db)
        }
    }

    /// Fetch records where a column equals a value.
    func fetch(column: String, value: some DatabaseValueConvertible & Sendable, isDeleted: Bool = false) async throws -> [ModelType] {
        try await db.queue.read { db in
            try ModelType
                .filter(Column(column) == value)
                .filter(Column.Basic.isDeleted == isDeleted)
                .fetchAll(db)
        }
    }
    
    /// Fetch a single record by ID.
    func fetch(id: String, isDeleted: Bool = false) async throws -> ModelType? {
        try await db.queue.read { db in
            try ModelType
                .filter(Column.Basic.id == id)
                .filter(Column.Basic.isDeleted == isDeleted)
                .fetchOne(db)
        }
    }

    /// Fetch all records.
    func fetchAll(isDeleted: Bool = false) async throws -> [ModelType] {
        try await db.queue.read { db in
            try ModelType
                .filter(Column.Basic.isDeleted == isDeleted)
                .fetchAll(db)
        }
    }

    /// Fetch records matching a query condition.
    func fetchAll(where condition: QueryInterfaceRequest<ModelType>) async throws -> [ModelType] {
        try await db.queue.read { db in
            try condition.fetchAll(db)
        }
    }
    
    func fetchCount(_ isDelete: Bool = false) async throws -> Int {
        try await db.queue.read { db in
            try ModelType
                .filter(Column.Basic.isDeleted == isDelete)
                .fetchCount(db)
        }
    }
}
