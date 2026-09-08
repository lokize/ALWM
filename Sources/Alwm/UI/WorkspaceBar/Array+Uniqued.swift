import AppKit
import Foundation
import AlwmPluginAPI

// MARK: - Array uniqued helpers

extension Array {
    func uniqued<T: Hashable>(by key: (Element) -> T?) -> [Element] {
        var seen = Set<T>()
        return filter { el in
            guard let k = key(el) else { return true }
            return seen.insert(k).inserted
        }
    }

    func uniqued() -> [Element] where Element: Hashable {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
