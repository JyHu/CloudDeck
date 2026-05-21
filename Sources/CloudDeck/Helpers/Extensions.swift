//
//  Extensions.swift
//  CloudDeck
//

import Foundation

/// Internal utility: Convert a sequence to a dictionary keyed by a property.
extension Sequence {
    func toMap<Key: Hashable>(_ keyPath: (Element) -> Key) -> [Key: Element] {
        var map: [Key: Element] = [:]
        for element in self {
            map[keyPath(element)] = element
        }
        return map
    }
}
