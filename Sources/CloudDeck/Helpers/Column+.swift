//
//  Column+.swift
//  CloudDeck
//
//  Created by hujinyou on 2026/6/9.
//

import GRDB

public extension Column {
    /// Predefined columns shared by all SyncableProtocol models.
    enum Basic {
        public static let id        = Column("id")
        public static let createAt  = Column("createAt")
        public static let updateAt  = Column("updateAt")
        public static let isDeleted = Column("isDeleted")
        public static let isSynced  = Column("isSynced")
    }
}
