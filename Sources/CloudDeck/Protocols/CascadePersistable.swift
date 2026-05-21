//
//  CascadePersistable.swift
//  CloudDeck
//

import Foundation
import GRDB

public protocol CascadePersistable {
    func cascadeInsert(_ db: Database) throws
    func cascadeDelete(_ db: Database) throws
    func cascadeUpsert(_ db: Database) throws
}
