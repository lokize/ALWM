import AppKit
import SwiftUI

/// Shared Stats-like chrome and formatters for system metric plugins.
public enum StatsFormat {
    public static func percent(_ value: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func load(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func mhz(_ value: Double) -> String {
        if value <= 0 { return "—" }
        if value >= 1000 {
            return String(format: "%.0f MHz", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        return String(format: "%.0f MHz", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func celsius(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f°C", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func fahrenheit(_ value: Double?) -> String {
        guard let value else { return "—" }
        let f = value * 9 / 5 + 32
        return String(format: "%.1f°F", locale: Locale(identifier: "en_US_POSIX"), f)
    }

    public static func temperature(_ value: Double?, useFahrenheit: Bool) -> String {
        useFahrenheit ? fahrenheit(value) : celsius(value)
    }

    public static func temperatureChip(_ value: Double?) -> String {
        guard let value else { return "—°" }
        return String(format: "%.0f°", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func uptime(seconds: TimeInterval, daysWord: String, hoursWord: String) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        if days > 0 {
            return "\(days) \(daysWord) · \(hours) \(hoursWord)"
        }
        let minutes = (total % 3_600) / 60
        if hours > 0 {
            return "\(hours) \(hoursWord) · \(minutes)m"
        }
        return "\(minutes)m"
    }

    public static func bytesPerSecond(_ bps: Double) -> String {
        let abs = Swift.abs(bps)
        if abs < 1024 { return String(format: "%.0f B/s", bps) }
        if abs < 1024 * 1024 { return String(format: "%.0f KB/s", bps / 1024) }
        if abs < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", bps / (1024 * 1024)) }
        return String(format: "%.2f GB/s", bps / (1024 * 1024 * 1024))
    }

    public static func bytes(_ value: UInt64, digits: Int = 1) -> String {
        let v = Double(value)
        if v < 1024 { return String(format: "%.0f B", v) }
        if v < 1024 * 1024 {
            return String(format: "%.\(digits)f KB", locale: Locale(identifier: "en_US_POSIX"), v / 1024)
        }
        if v < 1024 * 1024 * 1024 {
            return String(format: "%.\(digits)f MB", locale: Locale(identifier: "en_US_POSIX"), v / (1024 * 1024))
        }
        return String(format: "%.\(digits)f GB", locale: Locale(identifier: "en_US_POSIX"), v / (1024 * 1024 * 1024))
    }
}

public enum StatsColors {
    public static let system = Color(red: 0.95, green: 0.35, blue: 0.35)
    public static let user = Color(red: 0.30, green: 0.55, blue: 0.95)
    public static let idle = Color(white: 0.45)
    public static let efficiency = Color(red: 0.25, green: 0.85, blue: 0.85)
    public static let performance = Color(red: 0.95, green: 0.55, blue: 0.25)
    public static let accent = Color(red: 0.35, green: 0.65, blue: 0.95)
    public static let download = Color(red: 0.30, green: 0.55, blue: 0.95)
    public static let upload = Color(red: 0.95, green: 0.35, blue: 0.35)
}

public struct StatsSectionHeader: View {
    public let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(height: 1)
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

public struct StatsDetailRow: View {
    public let title: String
    public let value: String
    public var swatch: Color?

    public init(_ title: String, value: String, swatch: Color? = nil) {
        self.title = title
        self.value = value
        self.swatch = swatch
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let swatch {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(swatch)
                    .frame(width: 8, height: 8)
            }
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

public struct StatsRingGauge: View {
    public let value: Double
    public let label: String
    public var color: Color
    public var trackOpacity: Double

    public init(value: Double, label: String, color: Color = StatsColors.accent, trackOpacity: Double = 0.22) {
        self.value = min(max(value, 0), 1)
        self.label = label
        self.color = color
        self.trackOpacity = trackOpacity
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(trackOpacity), lineWidth: 5)
            Circle()
                .trim(from: 0, to: value)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(width: 56, height: 56)
    }
}

public struct StatsHistoryChart: View {
    public let values: [Double]
    public var fill: Color
    public var line: Color

    public init(values: [Double], fill: Color = Color.secondary.opacity(0.35), line: Color = Color.primary.opacity(0.75)) {
        self.values = values
        self.fill = fill
        self.line = line
    }

    public var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack(alignment: .bottomLeading) {
                if pts.count >= 2 {
                    Path { path in
                        path.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for p in pts { path.addLine(to: p) }
                        path.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(fill)

                    Path { path in
                        path.move(to: pts[0])
                        for p in pts.dropFirst() { path.addLine(to: p) }
                    }
                    .stroke(line, lineWidth: 1.2)
                }
            }
        }
        .frame(height: 36)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty, size.width > 0, size.height > 0 else { return [] }
        let maxV = max(values.max() ?? 1, 0.01)
        let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
        return values.enumerated().map { index, value in
            let x = CGFloat(index) * step
            let y = size.height - CGFloat(min(max(value / maxV, 0), 1)) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}

public struct StatsCoreBars: View {
    public let cores: [Double]
    public var efficiencyCount: Int

    public init(cores: [Double], efficiencyCount: Int = 0) {
        self.cores = cores
        self.efficiencyCount = efficiencyCount
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                let color = index < efficiencyCount ? StatsColors.efficiency : StatsColors.performance
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, 22 * min(max(value, 0), 1)))
            }
        }
        .frame(height: 24)
    }
}

public struct StatsProcessRow: View {
    public let name: String
    public let value: String
    public var icon: NSImage?

    public init(name: String, value: String, icon: NSImage? = nil) {
        self.name = name
        self.value = value
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

public struct StatsSensorRow: View {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}

public struct StatsPopoverHeader: View {
    public let title: String
    public var systemImage: String

    public init(title: String, systemImage: String = "chart.bar.fill") {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Image(systemName: "command")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }
}

public struct StatsStatusPill: View {
    public let text: String
    public var ok: Bool

    public init(_ text: String, ok: Bool) {
        self.text = text
        self.ok = ok
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(ok ? Color.green.opacity(0.85) : Color.red.opacity(0.75))
            )
    }
}

public struct StatsDualHistoryChart: View {
    public let primary: [Double]
    public let secondary: [Double]
    public var primaryColor: Color
    public var secondaryColor: Color

    public init(
        primary: [Double],
        secondary: [Double],
        primaryColor: Color = StatsColors.download,
        secondaryColor: Color = StatsColors.upload
    ) {
        self.primary = primary
        self.secondary = secondary
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
    }

    public var body: some View {
        GeometryReader { geo in
            let maxV = max(primary.max() ?? 0, secondary.max() ?? 0, 0.01)
            ZStack {
                linePath(values: primary, in: geo.size, maxV: maxV)
                    .stroke(primaryColor, lineWidth: 1.4)
                linePath(values: secondary, in: geo.size, maxV: maxV)
                    .stroke(secondaryColor, lineWidth: 1.4)
            }
        }
        .frame(height: 40)
    }

    private func linePath(values: [Double], in size: CGSize, maxV: Double) -> Path {
        Path { path in
            guard !values.isEmpty, size.width > 0 else { return }
            let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * step
                let y = size.height - CGFloat(min(max(value / maxV, 0), 1)) * size.height
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }
}

public struct StatsConnectivityGrid: View {
    public let samples: [Bool]

    public init(samples: [Bool]) {
        self.samples = samples
    }

    public var body: some View {
        let cols = 24
        let rows = max(1, Int(ceil(Double(max(samples.count, 1)) / Double(cols))))
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<cols, id: \.self) { col in
                        let index = row * cols + col
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(cellColor(at: index))
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
    }

    private func cellColor(at index: Int) -> Color {
        guard index < samples.count else { return Color.secondary.opacity(0.12) }
        return samples[index] ? Color.green.opacity(0.85) : Color.red.opacity(0.55)
    }
}
