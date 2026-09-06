import AppKit

/// Compact workspace-bar chip: SF Symbol + short value (macOS Control Center density).
public final class StatsBarChipView: NSView {
    public var onClick: (() -> Void)?

    private let symbolName: String
    private let value: String
    private let unit: String?
    private let tint: NSColor
    private let scale: CGFloat

    public init(
        symbolName: String?,
        value: String,
        unit: String? = nil,
        tint: NSColor = .labelColor,
        scale: CGFloat,
        tooltip: String,
        onClick: (() -> Void)? = nil
    ) {
        self.symbolName = symbolName ?? ""
        self.value = value
        self.unit = unit
        self.tint = tint
        self.scale = scale
        self.onClick = onClick
        super.init(frame: .zero)
        toolTip = tooltip
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    private func build() {
        let fontSize = max(9, 10 * scale)
        let iconSize = max(10, 11 * scale)
        let padX = max(4, 5 * scale)
        let gap = max(3, 3.5 * scale)
        let chipH = max(14, 16 * scale)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = gap
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        if !symbolName.isEmpty {
            let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            icon.contentTintColor = tint
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: iconSize + 1),
                icon.heightAnchor.constraint(equalToConstant: iconSize + 1)
            ])
            row.addArrangedSubview(icon)
        }

        let valueField = NSTextField(labelWithString: value)
        valueField.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        valueField.textColor = tint
        valueField.isEditable = false
        valueField.isBezeled = false
        valueField.drawsBackground = false
        valueField.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(valueField)

        if let unit, !unit.isEmpty {
            let unitField = NSTextField(labelWithString: unit)
            unitField.font = .monospacedDigitSystemFont(ofSize: max(8, fontSize - 1), weight: .medium)
            unitField.textColor = tint.withAlphaComponent(0.72)
            unitField.isEditable = false
            unitField.isBezeled = false
            unitField.drawsBackground = false
            unitField.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(unitField)
        }

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: chipH)
        ])
    }
}

/// Maps 0…1 utilization to label / orange / red for compact chips.
public enum StatsBarChipPressure {
    public static func tint(for fraction: Double) -> NSColor {
        if fraction >= 0.90 { return .systemRed }
        if fraction >= 0.70 { return .systemOrange }
        return .labelColor
    }

    public static func tint(percent: Int) -> NSColor {
        tint(for: Double(percent) / 100.0)
    }

    /// Battery: low is bad (invert).
    public static func batteryTint(percent: Int, charging: Bool) -> NSColor {
        if charging { return .systemGreen }
        if percent <= 15 { return .systemRed }
        if percent <= 30 { return .systemOrange }
        return .labelColor
    }

    public static func batterySymbol(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch percent {
        case 90...100: return "battery.100"
        case 65..<90: return "battery.75"
        case 40..<65: return "battery.50"
        case 15..<40: return "battery.25"
        default: return "battery.0"
        }
    }
}
