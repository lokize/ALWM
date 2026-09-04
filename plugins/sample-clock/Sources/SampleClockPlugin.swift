import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n

/// HH:mm on the workspace bar.
public final class SampleClockPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.sample-clock"

    private weak var context: AlwmPluginContext?
    private var timer: Timer?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        timer?.invalidate()
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.context?.requestBarRefresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
        languageObserver = NotificationCenter.default.addObserver(
            forName: .alwmLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.context?.requestBarRefresh()
        }
    }

    public func unload() {
        timer?.invalidate()
        timer = nil
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        let scale = context?.barScale ?? 1
        let fontSize = max(9, 10 * scale)
        let text = Self.timeString()
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        field.textColor = .labelColor
        field.isEditable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.toolTip = PluginL10n.t("plugin.clock.tooltip")
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)

        let padX = max(5, 6 * scale)
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: padX),
            field.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -padX),
            field.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            wrap.heightAnchor.constraint(greaterThanOrEqualToConstant: max(14, 16 * scale))
        ])
        return wrap
    }

    public func barSignature() -> String {
        "clock:\(Self.timeString()):\(PluginL10n.currentCode)"
    }

    private static func timeString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: PluginL10n.currentCode)
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: SampleClockPlugin())
}
