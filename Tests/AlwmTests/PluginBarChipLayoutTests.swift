import CoreGraphics
import Testing
@testable import Alwm
import AlwmPluginAPI

@Suite("Plugin bar chip sizing")
struct PluginBarChipLayoutTests {
    @Test("effective chip scale respects the bar's inner height")
    @MainActor
    func scaleFitsPillHeight() {
        let controller = WorkspaceBarController()
        var settings = WorkspaceBarSettings.default
        settings.widthScale = 1.199

        let scale = controller.pluginBarScale(settings: settings, pillHeight: 19)

        #expect(abs(scale - CGFloat(17.0 / 16.0)) < 0.001)
        #expect(max(14, 16 * scale) <= 17)
    }

    @Test("plugin scale also fits the fixed-height Docker chip host")
    @MainActor
    func scaleFitsDockerHost() {
        let controller = WorkspaceBarController()
        var settings = WorkspaceBarSettings.default
        settings.widthScale = 1.199

        let scale = controller.pluginBarScale(settings: settings, pillHeight: 24)

        #expect(16 * scale <= 19)
    }

    @Test("fixed chip width fits the active Steam and Nintendo fields")
    func fixedWidthFitsActivePriceChip() {
        for scale: CGFloat in [0.8, 1.0, 1.199, 1.8] {
            let gaps = 3 * max(3, 3.5 * scale)
            let padding = 2 * max(4, 5 * scale)
            let contentWidth = PluginBarChipLayout.badgeWidth(scale: scale)
                + PluginBarChipLayout.steamThumbWidth(scale: scale)
                + PluginBarChipLayout.steamNameWidth(scale: scale)
                + PluginBarChipLayout.steamPriceWidth(scale: scale)
                + gaps
                + padding

            #expect(PluginBarChipLayout.chipWidth(scale: scale) >= contentWidth)
        }
    }
}
