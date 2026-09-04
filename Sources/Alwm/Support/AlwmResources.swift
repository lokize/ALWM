import AppKit
import Foundation

/// Anchor class so `Bundle(for:)` resolves the Alwm binary / framework.
private final class AlwmResourceAnchor: NSObject {}

/// Resource lookup that works in both `swift run` and the packaged `.app`.
/// Never touches `Bundle.module` — that asserts when `ALWM_Alwm.bundle` is missing
/// (GitHub DMG / Applications install without the SPM resource bundle).
enum AlwmResources {
    static func url(forResource name: String, withExtension ext: String?) -> URL? {
        var candidates: [Bundle] = [Bundle.main]
        candidates.append(Bundle(for: AlwmResourceAnchor.self))
        if let spm = spmResourceBundle {
            candidates.append(spm)
        }

        for bundle in candidates {
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    /// Packaged copy of SwiftPM's `ALWM_Alwm.bundle` when present.
    private static var spmResourceBundle: Bundle? {
        let names = ["ALWM_Alwm", "Alwm_Alwm"]
        for name in names {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("\(name).bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
            if let url = Bundle.main.url(forResource: name, withExtension: "bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }
}
