//
//  OfflineWriteSupport.swift
//  Project Planner
//

import Foundation

enum OfflineWriteSupport {
    static func shouldQueue(isOnline: Bool) -> Bool {
        !isOnline
    }

    static func shouldQueue(error: Error, isOnline: Bool) -> Bool {
        if !isOnline { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain,
           underlying.code == NSURLErrorNotConnectedToInternet {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("offline") || message.contains("network") || message.contains("internet")
    }
}
