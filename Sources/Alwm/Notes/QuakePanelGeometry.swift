import Foundation

/// Shared Quake-style panel frames for terminal + notepad overlays.
enum QuakePanelGeometry {
    static func visibleFrame(
        edge: QuakeEdge,
        sizeRatio: Double,
        lengthRatio: Double,
        inset: Double,
        monitor: MonitorInfo
    ) -> Rect {
        let mon = monitor.frame
        let insetVal = max(0, inset)
        let size = min(0.95, max(0.15, sizeRatio))
        let length = min(1.0, max(0.2, lengthRatio))

        switch edge {
        case .top:
            let height = max(160, mon.height * size)
            let width = max(200, (mon.width - insetVal * 2) * length)
            let x = mon.x + insetVal + ((mon.width - insetVal * 2) - width) / 2
            return Rect(x: x, y: mon.y + insetVal, width: width, height: height)
        case .bottom:
            let height = max(160, mon.height * size)
            let width = max(200, (mon.width - insetVal * 2) * length)
            let x = mon.x + insetVal + ((mon.width - insetVal * 2) - width) / 2
            return Rect(x: x, y: mon.maxY - height - insetVal, width: width, height: height)
        case .left:
            let width = max(200, mon.width * size)
            let height = max(160, (mon.height - insetVal * 2) * length)
            let y = mon.y + insetVal + ((mon.height - insetVal * 2) - height) / 2
            return Rect(x: mon.x + insetVal, y: y, width: width, height: height)
        case .right:
            let width = max(200, mon.width * size)
            let height = max(160, (mon.height - insetVal * 2) * length)
            let y = mon.y + insetVal + ((mon.height - insetVal * 2) - height) / 2
            return Rect(x: mon.maxX - width - insetVal, y: y, width: width, height: height)
        }
    }

    static func hiddenFrame(edge: QuakeEdge, visible: Rect, monitor: MonitorInfo) -> Rect {
        let mon = monitor.frame
        switch edge {
        case .top:
            return Rect(x: visible.x, y: mon.y - visible.height - 40, width: visible.width, height: visible.height)
        case .bottom:
            return Rect(x: visible.x, y: mon.maxY + 40, width: visible.width, height: visible.height)
        case .left:
            return Rect(x: mon.x - visible.width - 40, y: visible.y, width: visible.width, height: visible.height)
        case .right:
            return Rect(x: mon.maxX + 40, y: visible.y, width: visible.width, height: visible.height)
        }
    }

    static func visibleFrame(settings: NotepadSettings, monitor: MonitorInfo) -> Rect {
        visibleFrame(
            edge: settings.edge,
            sizeRatio: settings.sizeRatio,
            lengthRatio: settings.lengthRatio,
            inset: settings.inset,
            monitor: monitor
        )
    }

    static func hiddenFrame(settings: NotepadSettings, monitor: MonitorInfo) -> Rect {
        let visible = visibleFrame(settings: settings, monitor: monitor)
        return hiddenFrame(edge: settings.edge, visible: visible, monitor: monitor)
    }

    static func visibleFrame(settings: QuakeSettings, monitor: MonitorInfo) -> Rect {
        visibleFrame(
            edge: settings.edge,
            sizeRatio: settings.sizeRatio,
            lengthRatio: settings.lengthRatio,
            inset: settings.inset,
            monitor: monitor
        )
    }

    static func hiddenFrame(settings: QuakeSettings, monitor: MonitorInfo) -> Rect {
        let visible = visibleFrame(settings: settings, monitor: monitor)
        return hiddenFrame(edge: settings.edge, visible: visible, monitor: monitor)
    }
}
