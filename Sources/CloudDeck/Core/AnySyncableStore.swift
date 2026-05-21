//
//  AnySyncableStore.swift
//  CloudDeck
//

/// Type-erased wrapper for SyncableStore, enabling heterogeneous store collections.
public final class AnySyncableStore: @unchecked Sendable {
    public let store: any SyncableStore

    private let _save: @Sendable (any SyncableProtocol) async throws -> Void
    private let _saveAll: @Sendable ([any SyncableProtocol]) async throws -> Void
    private let _delete: @Sendable (String) async throws -> Void
    private let _deleteAll: @Sendable ([String]) async throws -> Void
    private let _deleteM: @Sendable (any SyncableProtocol) async throws -> Void
    private let _deleteMAll: @Sendable ([any SyncableProtocol]) async throws -> Void

    public init<S: SyncableStore>(_ store: S) {
        self.store = store

        _save = { obj in
            try await store.save(obj as! S.ModelType)
        }
        _saveAll = { objs in
            try await store.saveAll(objs as! [S.ModelType])
        }
        _delete = {
            try await store.delete($0)
        }
        _deleteAll = {
            try await store.deleteAll($0)
        }
        _deleteM = {
            try await store.delete($0 as! S.ModelType)
        }
        _deleteMAll = {
            try await store.deleteAll($0 as! [S.ModelType])
        }
    }

    public func save(_ object: any SyncableProtocol) async throws {
        try await _save(object)
    }

    public func saveAll(_ objects: [any SyncableProtocol]) async throws {
        try await _saveAll(objects)
    }

    public func delete(_ objectID: String) async throws {
        try await _delete(objectID)
    }

    public func deleteAll(_ objectIDs: [String]) async throws {
        try await _deleteAll(objectIDs)
    }

    public func delete(_ object: any SyncableProtocol) async throws {
        try await _deleteM(object)
    }

    public func deleteAll(_ objects: [any SyncableProtocol]) async throws {
        try await _deleteMAll(objects)
    }
}
