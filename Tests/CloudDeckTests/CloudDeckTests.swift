import XCTest
import CloudKit
import GRDB
@testable import CloudDeck

// MARK: - Test Model

private struct MockModel: SyncableProtocol {
    enum Columns: String, CodingKey, ColumnExpression {
        case id, name, createAt, updateAt, isDeleted, isSynced
    }

    static let zoneName: CKRecordZone.Name = "TestZone"
    static let recordType: CKRecordType = "MockModel"

    var id: String
    var name: String
    var createAt: Date
    var updateAt: Date
    var isDeleted: Bool
    var isSynced: Bool

    init(id: String = UUID().uuidString, name: String = "Test") {
        self.id = id
        self.name = name
        self.createAt = Date(timeIntervalSince1970: 1000)
        self.updateAt = Date(timeIntervalSince1970: 1000)
        self.isDeleted = false
        self.isSynced = true
    }

    init(record: CKRecord) throws {
        self.id = record.recordID.recordName
        self.name = record["name"] as? String ?? ""
        self.createAt = record.creationDate ?? Date()
        self.updateAt = record.modificationDate ?? Date()
        self.isDeleted = false
        self.isSynced = true
    }

    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["name"] = name
        return record
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.name] = name
        container[Columns.createAt] = createAt
        container[Columns.updateAt] = updateAt
        container[Columns.isDeleted] = isDeleted
        container[Columns.isSynced] = isSynced
    }
}

// MARK: - SyncableProtocol Tests

final class SyncableProtocolTests: XCTestCase {
    func testMarkDeletedUpdatesFlagsAndTimestamp() {
        var model = MockModel()
        let originalUpdate = model.updateAt
        model.markDeleted()

        XCTAssertTrue(model.isDeleted)
        XCTAssertFalse(model.isSynced)
        XCTAssertGreaterThan(model.updateAt, originalUpdate)
    }

    func testMarkModifiedUpdatesFlagsAndTimestamp() {
        var model = MockModel()
        let originalUpdate = model.updateAt
        model.markModified()

        XCTAssertFalse(model.isSynced)
        XCTAssertGreaterThan(model.updateAt, originalUpdate)
    }

    func testMarkSyncedSetsFlag() {
        var model = MockModel()
        model.isSynced = false
        model.markSynced()
        XCTAssertTrue(model.isSynced)
    }

    func testMarkDeletedAlsoUnsyncsFlagAndAdvancesTimestamp() {
        var model = MockModel()
        model.isSynced = true
        model.markDeleted()

        XCTAssertTrue(model.isDeleted)
        XCTAssertFalse(model.isSynced)
    }
}

// MARK: - SyncResult Tests

final class SyncResultTests: XCTestCase {
    func testIsSuccessWhenNoFailures() {
        let result = SyncResult(saved: 2, deleted: 1, failed: 0)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.total, 3)
    }

    func testIsSuccessReturnsFalseWhenHasFailures() {
        let result = SyncResult(saved: 0, deleted: 0, failed: 2)
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.total, 2)
    }

    func testZeroResult() {
        let result = SyncResult(saved: 0, deleted: 0, failed: 0)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.total, 0)
    }
}

// MARK: - RecordID Tests

final class RecordIDTests: XCTestCase {
    func testStaticZoneID() {
        let zoneID = MockModel.zoneID
        XCTAssertEqual(zoneID.zoneName, "TestZone")
    }

    func testStaticRecordID() {
        let recordID = MockModel.recordID(with: "abc123")
        XCTAssertEqual(recordID.recordName, "abc123")
        XCTAssertEqual(recordID.zoneID.zoneName, "TestZone")
    }

    func testInstanceRecordID() {
        let model = MockModel(id: "xyz789")
        let recordID = model.recordID()
        XCTAssertEqual(recordID.recordName, "xyz789")
        XCTAssertEqual(recordID.zoneID.zoneName, "TestZone")
    }
}

// MARK: - Mock CloudKit Tests

final class MockCloudKitManagerImpl: CloudKitProtocol {
    var shouldFail = false
    var savedRecords: [CKRecord] = []
    var deletedIDs: [CKRecord.ID] = []

    func modify(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> CKModifyResults {
        if shouldFail {
            throw NSError(domain: "TestError", code: 1)
        }
        savedRecords.append(contentsOf: saving)
        deletedIDs.append(contentsOf: deleting)

        var saveResults: [CKRecord.ID: Result<CKRecord, Error>] = [:]
        for record in saving {
            saveResults[record.recordID] = .success(record)
        }
        var deleteResults: [CKRecord.ID: Result<Void, Error>] = [:]
        for id in deleting {
            deleteResults[id] = .success(())
        }
        return (saveResults: saveResults, deleteResults: deleteResults)
    }
}

final class CloudKitProtocolTests: XCTestCase {
    func testMockModifySuccess() async throws {
        let mock = MockCloudKitManagerImpl()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone")
        let record = CKRecord(recordType: "Test", recordID: CKRecord.ID(recordName: "r1", zoneID: zoneID))

        let results = try await mock.modify(saving: [record], deleting: [])

        XCTAssertEqual(results.saveResults.count, 1)
        XCTAssertEqual(mock.savedRecords.count, 1)
    }

    func testMockModifyFailure() async {
        let mock = MockCloudKitManagerImpl()
        mock.shouldFail = true

        do {
            _ = try await mock.modify(saving: [], deleting: [])
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual((error as NSError).code, 1)
        }
    }
}

// MARK: - SyncError Tests

final class SyncErrorTests: XCTestCase {
    func testErrorDescriptions() {
        XCTAssertNotNil(SyncError.modelNotFound(id: "x").errorDescription)
        XCTAssertNotNil(SyncError.syncFailed(reason: "test").errorDescription)
        XCTAssertNotNil(SyncError.invalidData(reason: "bad").errorDescription)
        XCTAssertNotNil(SyncError.configurationError(reason: "missing").errorDescription)
        XCTAssertNotNil(SyncError.conflictError(reason: "conflict").errorDescription)
    }
}

// MARK: - Cascade Tests

final class CascadeTests: XCTestCase {
    func testDefaultCascadeInsertCallsInsert() async throws {
        let model = MockModel(id: "cascade1")
        let dbQueue = try DatabaseQueue()

        try await dbQueue.write { db in
            try db.create(table: "mockModel") { t in
                t.primaryKey("id", .text)
                t.column("name", .text)
                t.column("createAt", .datetime)
                t.column("updateAt", .datetime)
                t.column("isDeleted", .boolean)
                t.column("isSynced", .boolean)
            }
        }

        try await dbQueue.write { db in
            try model.cascadeInsert(db)
        }

        let fetched = try await dbQueue.read { db in
            try MockModel.fetchOne(db, key: "cascade1")
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "Test")
    }

    func testDefaultCascadeDeleteRemovesRecord() async throws {
        let model = MockModel(id: "cascade2")
        let dbQueue = try DatabaseQueue()

        try await dbQueue.write { db in
            try db.create(table: "mockModel") { t in
                t.primaryKey("id", .text)
                t.column("name", .text)
                t.column("createAt", .datetime)
                t.column("updateAt", .datetime)
                t.column("isDeleted", .boolean)
                t.column("isSynced", .boolean)
            }
            try model.insert(db)
        }

        try await dbQueue.write { db in
            try model.cascadeDelete(db)
        }

        let fetched = try await dbQueue.read { db in
            try MockModel.fetchOne(db, key: "cascade2")
        }

        XCTAssertNil(fetched)
    }
}
