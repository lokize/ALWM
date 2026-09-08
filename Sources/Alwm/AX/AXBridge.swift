import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

// MARK: - AX value bridging helpers

enum AXBridge {
    static func int(_ value: AnyObject?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    static func bool(_ value: AnyObject?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }
}
