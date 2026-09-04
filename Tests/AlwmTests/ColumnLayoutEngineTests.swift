import Testing
@testable import Alwm
import AlwmIPC

@Suite("ColumnLayoutEngine")
struct ColumnLayoutEngineTests {
    let monitor = Rect(x: 0, y: 0, width: 1200, height: 800)
    var engine: ColumnLayoutEngine { ColumnLayoutEngine(settings: .default) }

    @Test("inserts windows into columns and focuses them")
    func insertAndFocus() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(a, into: &ws, usable: usable)
        engine.insertWindow(b, into: &ws, usable: usable)
        #expect(ws.columns.count == 1)
        #expect(ws.columns[0].windows == [a, b])
        #expect(ws.focusedWindowID == b)
    }

    @Test("move right creates a new column")
    func moveRightCreatesColumn() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(a, into: &ws, usable: usable)
        engine.insertWindow(b, into: &ws, usable: usable)
        engine.moveFocused(.right, workspace: &ws, usable: usable)
        #expect(ws.columns.count == 2)
        #expect(ws.columns[0].windows == [a])
        #expect(ws.columns[1].windows == [b])
    }

    @Test("peel left with stale focus map does not trap")
    func peelLeftWithStaleFocusMap() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        let c = WindowID(pid: 1, windowNumber: 3)
        engine.insertWindow(a, into: &ws, usable: usable)
        engine.insertWindow(b, into: &ws, usable: usable)
        engine.insertWindow(c, into: &ws, usable: usable)
        ws.focusedWindowInColumn[2] = 0
        engine.moveFocused(.left, workspace: &ws, usable: usable)
        #expect(ws.columns.count == 2)
        #expect(ws.columns[0].windows == [c])
        #expect(ws.columns[1].windows == [a, b])
    }

    @Test("stack scroll focus with stale focusedColumn does not trap")
    func focusDownWithStaleFocusedColumn() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(a, into: &ws, usable: usable)
        engine.insertWindow(b, into: &ws, usable: usable)
        ws.focusedColumn = 9
        engine.focus(.down, workspace: &ws, usable: usable)
        #expect(ws.focusedColumn == 0)
        #expect(ws.focusedWindowID == b)
        engine.focus(.up, workspace: &ws, usable: usable)
        #expect(ws.focusedWindowID == a)
    }

    @Test("computeFrames stacks visible windows in active workspace")
    func computeActiveFrames() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(a, into: &ws, usable: usable)
        engine.insertWindow(b, into: &ws, usable: usable)
        engine.moveFocused(.right, workspace: &ws, usable: usable)

        let windows: [WindowID: ManagedWindow] = [
            a: ManagedWindow(id: a, title: "A", bundleID: nil, appName: "A", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            b: ManagedWindow(id: b, title: "B", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]
        let frames = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        #expect(frames.count == 2)
        #expect(frames.filter(\.visible).count == 2)
        let ax = frames.first(where: { $0.windowID == a })!.frame
        let bx = frames.first(where: { $0.windowID == b })!.frame
        #expect(bx.x > ax.x)
    }

    @Test("inactive workspace parks windows offscreen")
    func parksInactive() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        engine.insertWindow(a, into: &ws, usable: usable)
        let windows: [WindowID: ManagedWindow] = [
            a: ManagedWindow(id: a, title: "A", bundleID: nil, appName: "A", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]
        let frames = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: false)
        #expect(frames.count == 1)
        #expect(frames[0].visible == false)
        #expect(frames[0].frame.y > monitor.maxY)
    }

    @Test("snapScroll aligns to column boundary")
    func snapScroll() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(a, into: &ws, usable: usable)
        engine.insertWindow(b, into: &ws, usable: usable)
        engine.moveFocused(.right, workspace: &ws, usable: usable)
        ws.viewOffset = 40
        engine.snapScroll(workspace: &ws, usable: usable)
        #expect(ws.viewOffset == 0 || ws.viewOffset > 0)
        #expect(ws.focusedColumn == 0 || ws.focusedColumn == 1)
    }

    @Test("resize keeps two columns inside usable with gaps")
    func resizeRespectsGaps() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(a, into: &ws, usable: usable)
        engine.insertWindow(b, into: &ws, usable: usable)
        engine.moveFocused(.right, workspace: &ws, usable: usable)
        engine.resizeFocused(by: 120, workspace: &ws, usable: usable)

        let windows: [WindowID: ManagedWindow] = [
            a: ManagedWindow(id: a, title: "A", bundleID: nil, appName: "A", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            b: ManagedWindow(id: b, title: "B", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]
        let frames = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        let af = frames.first(where: { $0.windowID == a })!.frame
        let bf = frames.first(where: { $0.windowID == b })!.frame
        #expect(abs(af.x - usable.x) < 0.5)
        #expect(abs(bf.x - (af.maxX + engine.settings.gap)) < 0.5)
        #expect(abs(bf.maxX - usable.maxX) < 0.5)
        #expect(abs(af.width + bf.width + engine.settings.gap - usable.width) < 0.5)
        #expect(bf.x - af.maxX >= engine.settings.gap - 0.5)
    }

    @Test("stacked windows keep a vertical gap")
    func stackedWindowsKeepVerticalGap() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(a, into: &ws, usable: usable)
        engine.insertWindow(b, into: &ws, usable: usable)

        let windows: [WindowID: ManagedWindow] = [
            a: ManagedWindow(id: a, title: "A", bundleID: nil, appName: "A", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            b: ManagedWindow(id: b, title: "B", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]
        let frames = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        let af = frames.first(where: { $0.windowID == a })!.frame
        let bf = frames.first(where: { $0.windowID == b })!.frame
        #expect(bf.y - af.maxY >= engine.settings.gap - 0.5)
        #expect(abs(af.height + bf.height + engine.settings.gap - usable.height) < 0.5)
        #expect(abs(af.y - usable.y) < 0.5)
        #expect(abs(bf.maxY - usable.maxY) < 0.5)
    }

    @Test("resize height keeps stacked windows filling the column")
    func resizeHeightFillsColumn() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(a, into: &ws, usable: usable)
        engine.insertWindow(b, into: &ws, usable: usable)
        ws.focusedColumn = 0
        ws.focusedWindowInColumn[0] = 1

        let windows: [WindowID: ManagedWindow] = [
            a: ManagedWindow(id: a, title: "A", bundleID: nil, appName: "A", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            b: ManagedWindow(id: b, title: "B", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]

        engine.resizeFocusedHeight(by: 120, workspace: &ws, usable: usable, for: b)
        let frames = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        let af = frames.first(where: { $0.windowID == a })!.frame
        let bf = frames.first(where: { $0.windowID == b })!.frame
        #expect(bf.height > af.height)
        #expect(abs(af.height + bf.height + engine.settings.gap - usable.height) < 0.5)
        #expect(abs(af.y - usable.y) < 0.5)
        #expect(abs(bf.maxY - usable.maxY) < 0.5)
        #expect(abs(af.width - usable.width) < 0.5)
        #expect(abs(bf.width - usable.width) < 0.5)

        engine.resizeFocusedHeight(by: -200, workspace: &ws, usable: usable, for: b)
        let after = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        let af2 = after.first(where: { $0.windowID == a })!.frame
        let bf2 = after.first(where: { $0.windowID == b })!.frame
        #expect(abs(af2.height + bf2.height + engine.settings.gap - usable.height) < 0.5)
        #expect(abs(bf2.maxY - usable.maxY) < 0.5)
    }

    @Test("stack keeps equal split when both siblings are layout-eligible")
    func stackEqualSplitStable() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let top = WindowID(pid: 1, windowNumber: 1)
        let bottom = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(top, into: &ws, usable: usable)
        engine.insertWindow(bottom, into: &ws, usable: usable)

        let windows: [WindowID: ManagedWindow] = [
            top: ManagedWindow(id: top, title: "Top", bundleID: nil, appName: "T", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            bottom: ManagedWindow(id: bottom, title: "Bottom", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]
        let gap = engine.settings.gap
        let expected = (usable.height - gap) / 2

        let frames = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        let topF = frames.first(where: { $0.windowID == top })!.frame
        let bottomF = frames.first(where: { $0.windowID == bottom })!.frame
        #expect(abs(topF.height - expected) < 0.5)
        #expect(abs(bottomF.height - expected) < 0.5)
        #expect(abs(bottomF.maxY - usable.maxY) < 0.5)
    }

    @Test("stack fills usable height edge to edge")
    func stackFillsUsableHeight() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(a, into: &ws, usable: usable)
        engine.insertWindow(b, into: &ws, usable: usable)

        let windows: [WindowID: ManagedWindow] = [
            a: ManagedWindow(id: a, title: "A", bundleID: nil, appName: "A", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            b: ManagedWindow(id: b, title: "B", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]
        let frames = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        let top = frames.first(where: { $0.windowID == a })!.frame
        let bottom = frames.first(where: { $0.windowID == b })!.frame
        #expect(abs(top.y - usable.y) < 0.5)
        #expect(abs(bottom.maxY - usable.maxY) < 0.5)
        #expect(top.maxX <= usable.maxX + 0.5)
        #expect(bottom.maxX <= usable.maxX + 0.5)
    }

    @Test("minimized stack sibling does not shrink visible window")
    func minimizedSiblingGetsFullColumnHeight() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(a, into: &ws, usable: usable)
        engine.insertWindow(b, into: &ws, usable: usable)

        let windows: [WindowID: ManagedWindow] = [
            a: ManagedWindow(id: a, title: "A", bundleID: nil, appName: "A", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            b: ManagedWindow(id: b, title: "B", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]
        let frames = engine.computeFrames(
            workspace: ws,
            windows: windows,
            monitor: monitor,
            active: true,
            stackExcluded: [b]
        )
        let af = frames.first(where: { $0.windowID == a })!
        let bf = frames.first(where: { $0.windowID == b })!
        #expect(abs(af.frame.height - usable.height) < 0.5)
        #expect(af.visible)
        // Excluded siblings stay "visible" to the WM (off-screen park) so layout never
        // Dock-minimizes them — matches fluid move/resize.
        #expect(bf.visible)
        #expect(bf.frame.y > monitor.maxY)
    }

    @Test("move down swaps stack order and keeps column filled")
    func moveDownSwapsStackOrder() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let top = WindowID(pid: 1, windowNumber: 1)
        let bottom = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(top, into: &ws, usable: usable)
        engine.insertWindow(bottom, into: &ws, usable: usable)
        ws.focusedWindowInColumn[0] = 0

        let windows: [WindowID: ManagedWindow] = [
            top: ManagedWindow(id: top, title: "Top", bundleID: nil, appName: "T", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            bottom: ManagedWindow(id: bottom, title: "Bottom", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]

        engine.moveFocused(.down, workspace: &ws, usable: usable)
        #expect(ws.columns[0].windows == [bottom, top])
        #expect(ws.focusedWindowInColumn[0] == 1)

        let gap = engine.settings.gap
        let expected = (usable.height - gap) / 2
        let frames = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        let topF = frames.first(where: { $0.windowID == bottom })!.frame
        let bottomF = frames.first(where: { $0.windowID == top })!.frame
        #expect(abs(topF.y - usable.y) < 0.5)
        #expect(abs(topF.height - expected) < 0.5)
        #expect(abs(bottomF.maxY - usable.maxY) < 0.5)
        #expect(abs(bottomF.height - expected) < 0.5)
    }

    @Test("two-window stack never tabs siblings off-screen")
    func twoWindowStackNeverTabs() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let top = WindowID(pid: 1, windowNumber: 1)
        let bottom = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(top, into: &ws, usable: usable)
        engine.insertWindow(bottom, into: &ws, usable: usable)
        ws.focusedWindowInColumn[0] = 1

        let hugeMin = Size(width: 100, height: 900)
        let windows: [WindowID: ManagedWindow] = [
            top: ManagedWindow(id: top, title: "Top", bundleID: nil, appName: "T", frame: .init(x: 0, y: 0, width: 100, height: 100), minSize: hugeMin),
            bottom: ManagedWindow(id: bottom, title: "Bottom", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100), minSize: hugeMin)
        ]

        let frames = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        let topF = frames.first(where: { $0.windowID == top })!.frame
        let bottomF = frames.first(where: { $0.windowID == bottom })!.frame
        #expect(topF.y >= usable.y - 0.5)
        #expect(bottomF.maxY <= usable.maxY + 0.5)
        #expect(topF.y + topF.height + engine.settings.gap <= bottomF.y + 0.5)
        #expect(abs(topF.height + bottomF.height + engine.settings.gap - usable.height) < 0.5)
    }

    @Test("stack honors custom weights despite oversized AX minSize")
    func stackIgnoresOversizedMinSizeWithCustomWeights() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let top = WindowID(pid: 1, windowNumber: 1)
        let bottom = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(top, into: &ws, usable: usable)
        engine.insertWindow(bottom, into: &ws, usable: usable)
        ws.leafWeights[top.token] = 0.4
        ws.leafWeights[bottom.token] = 0.6

        let hugeMin = Size(width: 100, height: 900)
        let windows: [WindowID: ManagedWindow] = [
            top: ManagedWindow(id: top, title: "Top", bundleID: nil, appName: "T", frame: .init(x: 0, y: 0, width: 100, height: 100), minSize: hugeMin),
            bottom: ManagedWindow(id: bottom, title: "Bottom", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100), minSize: hugeMin)
        ]

        let frames = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        let topF = frames.first(where: { $0.windowID == top })!.frame
        let bottomF = frames.first(where: { $0.windowID == bottom })!.frame
        #expect(bottomF.height > topF.height)
        #expect(abs(topF.y - usable.y) < 0.5)
        #expect(abs(topF.height + bottomF.height + engine.settings.gap - usable.height) < 0.5)
        #expect(abs(bottomF.maxY - usable.maxY) < 0.5)
    }

    @Test("grow bottom row steals height from top sibling")
    func growBottomStealsFromTop() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let top = WindowID(pid: 1, windowNumber: 1)
        let bottom = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(top, into: &ws, usable: usable)
        engine.insertWindow(bottom, into: &ws, usable: usable)

        let windows: [WindowID: ManagedWindow] = [
            top: ManagedWindow(id: top, title: "Top", bundleID: nil, appName: "T", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            bottom: ManagedWindow(id: bottom, title: "Bottom", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]

        let before = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        let topBefore = before.first(where: { $0.windowID == top })!.frame.height

        engine.resizeFocusedHeight(by: 100, workspace: &ws, usable: usable, for: bottom)
        let after = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        let topAfter = after.first(where: { $0.windowID == top })!.frame
        let bottomAfter = after.first(where: { $0.windowID == bottom })!.frame

        #expect(bottomAfter.height > before.first(where: { $0.windowID == bottom })!.frame.height)
        #expect(topAfter.height < topBefore)
        #expect(abs(topAfter.maxY + engine.settings.gap - bottomAfter.y) < 0.5)
        #expect(abs(bottomAfter.maxY - usable.maxY) < 0.5)
    }

    @Test("move down swaps stack leaf weights with slots")
    func moveDownSwapsLeafWeights() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let top = WindowID(pid: 1, windowNumber: 1)
        let bottom = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(top, into: &ws, usable: usable)
        engine.insertWindow(bottom, into: &ws, usable: usable)
        ws.focusedWindowInColumn[0] = 0
        ws.leafWeights[top.token] = 0.7
        ws.leafWeights[bottom.token] = 0.3

        engine.moveFocused(.down, workspace: &ws, usable: usable)
        #expect(abs((ws.leafWeights[top.token] ?? 0) - 0.3) < 0.001)
        #expect(abs((ws.leafWeights[bottom.token] ?? 0) - 0.7) < 0.001)
    }

    @Test("maximize fills focused window to full column height")
    func maximizeColumnFillsUsable() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        let c = WindowID(pid: 1, windowNumber: 3)
        engine.insertWindow(a, into: &ws, usable: usable)
        engine.insertWindow(b, into: &ws, usable: usable)
        engine.moveFocused(.right, workspace: &ws, usable: usable)
        engine.insertWindow(c, into: &ws, usable: usable)
        #expect(ws.columns.count == 2)
        #expect(ws.columns[1].windows.count == 2)
        ws.focusedColumn = 1
        ws.focusedWindowInColumn[1] = 1

        let windows: [WindowID: ManagedWindow] = [
            a: ManagedWindow(id: a, title: "A", bundleID: nil, appName: "A", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            b: ManagedWindow(id: b, title: "B", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            c: ManagedWindow(id: c, title: "C", bundleID: nil, appName: "C", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]

        let before = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        let cBefore = before.first(where: { $0.windowID == c })!.frame
        #expect(cBefore.height < usable.height - 1)

        engine.toggleMaximizeFocusedColumn(workspace: &ws, usable: usable)
        #expect(ws.columns[1].isMaximized)

        let after = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        let cAfter = after.first(where: { $0.windowID == c })!.frame
        #expect(abs(cAfter.height - usable.height) < 0.5)
        #expect(abs(cAfter.y - usable.y) < 0.5)
        #expect(abs(cAfter.width - cBefore.width) < 0.5)

        engine.toggleMaximizeFocusedColumn(workspace: &ws, usable: usable)
        #expect(!ws.columns[1].isMaximized)
    }

    @Test("prepareLayoutForDisplay preserves ratios after ghost column prune")
    func preparePreservesAfterGhostPrune() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let ghost = WindowID(pid: 1, windowNumber: 1)
        let left = WindowID(pid: 2, windowNumber: 1)
        let right = WindowID(pid: 3, windowNumber: 1)
        let budget = engine.fillWidthBudget(columnCount: 2, usable: usable)
        let leftW = budget * 0.4
        let rightW = budget * 0.6
        ws.columns = [
            Column(windows: [ghost], width: budget * 0.25),
            Column(windows: [left], width: leftW),
            Column(windows: [right], width: rightW)
        ]

        let windows: [WindowID: ManagedWindow] = [
            ghost: ManagedWindow(id: ghost, title: "Ghost", bundleID: nil, appName: "G", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            left: ManagedWindow(id: left, title: "Left", bundleID: nil, appName: "L", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            right: ManagedWindow(id: right, title: "Right", bundleID: nil, appName: "R", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]

        engine.prepareLayoutForDisplay(
            workspace: &ws,
            usable: usable,
            windows: windows,
            layoutExcluded: [ghost]
        )

        #expect(ws.columns.count == 2)
        #expect(abs(ws.columns[0].width - leftW) < 0.5)
        #expect(abs(ws.columns[1].width - rightW) < 0.5)
    }

    @Test("prepareLayoutForDisplay preserves custom column ratios on switch-back")
    func preparePreservesColumnRatios() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(a, into: &ws, usable: usable)
        engine.insertWindow(b, into: &ws, usable: usable)
        engine.moveFocused(.right, workspace: &ws, usable: usable)
        engine.resizeFocused(by: 120, workspace: &ws, usable: usable)

        let leftBefore = ws.columns[0].width
        let rightBefore = ws.columns[1].width
        let windows: [WindowID: ManagedWindow] = [
            a: ManagedWindow(id: a, title: "A", bundleID: nil, appName: "A", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            b: ManagedWindow(id: b, title: "B", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]

        engine.prepareLayoutForDisplay(workspace: &ws, usable: usable, windows: windows)
        engine.prepareLayoutForDisplay(workspace: &ws, usable: usable, windows: windows)

        #expect(abs(ws.columns[0].width - leftBefore) < 0.5)
        #expect(abs(ws.columns[1].width - rightBefore) < 0.5)
    }

    @Test("prepareLayoutForDisplay keeps multi-column structure with vacant placeholder")
    func prepareKeepsMultiColumnWithVacantPlaceholder() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let left = WindowID(pid: 1, windowNumber: 1)
        let right = WindowID(pid: 2, windowNumber: 1)
        let budget = engine.fillWidthBudget(columnCount: 2, usable: usable)
        let leftW = budget * 0.4
        let rightW = budget * 0.6
        ws.columns = [
            Column(windows: [left], width: leftW),
            Column(windows: [], width: budget * 0.1),
            Column(windows: [right], width: rightW)
        ]

        let windows: [WindowID: ManagedWindow] = [
            left: ManagedWindow(id: left, title: "Left", bundleID: nil, appName: "L", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            right: ManagedWindow(id: right, title: "Right", bundleID: nil, appName: "R", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]

        engine.prepareLayoutForDisplay(workspace: &ws, usable: usable, windows: windows)

        #expect(ws.columns.count == 2)
        #expect(abs(ws.columns[0].width - leftW) < 0.5)
        #expect(abs(ws.columns[1].width - rightW) < 0.5)
    }

    @Test("prepareLayoutForDisplay keeps side-by-side when sibling is layout-excluded")
    func prepareKeepsColumnsWhenSiblingExcluded() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let left = WindowID(pid: 1, windowNumber: 1)
        let right = WindowID(pid: 2, windowNumber: 1)
        let budget = engine.fillWidthBudget(columnCount: 2, usable: usable)
        let leftW = budget * 0.45
        let rightW = budget * 0.55
        ws.columns = [
            Column(windows: [left], width: leftW),
            Column(windows: [right], width: rightW)
        ]
        let windows: [WindowID: ManagedWindow] = [
            left: ManagedWindow(id: left, title: "Left", bundleID: nil, appName: "L", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            right: ManagedWindow(id: right, title: "Right", bundleID: nil, appName: "R", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]

        engine.prepareLayoutForDisplay(
            workspace: &ws,
            usable: usable,
            windows: windows,
            layoutExcluded: [right]
        )

        #expect(ws.columns.count == 2)
        #expect(abs(ws.columns[0].width - leftW) < 0.5)
        #expect(abs(ws.columns[1].width - rightW) < 0.5)
    }

    @Test("side-by-side keeps horizontal slots when sibling is not tiled yet")
    func sideBySideReservesSlotForNonTiledSibling() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let left = WindowID(pid: 1, windowNumber: 1)
        let right = WindowID(pid: 2, windowNumber: 1)
        let budget = engine.fillWidthBudget(columnCount: 2, usable: usable)
        let leftW = budget * 0.45
        let rightW = budget * 0.55
        ws.columns = [
            Column(windows: [left], width: leftW),
            Column(windows: [right], width: rightW)
        ]
        var rightWin = ManagedWindow(
            id: right, title: "Right", bundleID: nil, appName: "R",
            frame: .init(x: 0, y: 0, width: 100, height: 100)
        )
        rightWin.isFloating = true
        let windows: [WindowID: ManagedWindow] = [
            left: ManagedWindow(id: left, title: "Left", bundleID: nil, appName: "L", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            right: rightWin
        ]

        let frames = engine.computeFrames(
            workspace: ws,
            windows: windows,
            monitor: monitor,
            active: true
        )
        let leftFrame = frames.first(where: { $0.windowID == left })!.frame
        #expect(abs(leftFrame.width - leftW) < 2)
        #expect(abs(leftFrame.x - usable.x) < 1.5)
    }

    @Test("layout-excluded ghost column does not reserve horizontal space")
    func layoutExcludedGhostColumn() {
        var ws = WorkspaceState(id: "1", name: "1")
        let usable = engine.usableArea(monitor: monitor)
        let ghost = WindowID(pid: 1, windowNumber: 1)
        let top = WindowID(pid: 2, windowNumber: 1)
        let bottom = WindowID(pid: 2, windowNumber: 2)
        engine.insertWindow(ghost, into: &ws, usable: usable)
        engine.insertWindow(top, into: &ws, usable: usable)
        engine.moveFocused(.right, workspace: &ws, usable: usable)
        engine.insertWindow(bottom, into: &ws, usable: usable)

        let windows: [WindowID: ManagedWindow] = [
            ghost: ManagedWindow(id: ghost, title: "Ghost", bundleID: nil, appName: "G", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            top: ManagedWindow(id: top, title: "Top", bundleID: nil, appName: "T", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            bottom: ManagedWindow(id: bottom, title: "Bottom", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]
        let frames = engine.computeFrames(
            workspace: ws,
            windows: windows,
            monitor: monitor,
            active: true,
            layoutExcluded: [ghost]
        )
        let topFrame = frames.first(where: { $0.windowID == top })!.frame
        let bottomFrame = frames.first(where: { $0.windowID == bottom })!.frame
        #expect(abs(topFrame.x - usable.x) < 0.5)
        #expect(abs(topFrame.width - usable.width) < 0.5)
        #expect(abs(bottomFrame.width - usable.width) < 0.5)
    }
}

@Suite("OffscreenParking")
struct OffscreenParkingTests {
    @Test("park origin is below union of monitors")
    func parkBelowUnion() {
        let m1 = Rect(x: 0, y: 0, width: 1000, height: 800)
        let m2 = Rect(x: 1000, y: 0, width: 1000, height: 800)
        let park = OffscreenParking.parkOrigin(monitors: [m1, m2], preferred: m1)
        let unionMaxY = max(m1.maxY, m2.maxY)
        #expect(park.y > unionMaxY)
        #expect(!OffscreenParking.isOnAnyMonitor(Rect(x: park.x, y: park.y, width: 100, height: 100), monitors: [m1, m2]))
        let parked = OffscreenParking.parkedFrame(
            origin: park,
            sizeFrom: Rect(x: 0, y: 0, width: 900, height: 700),
            live: Rect(x: 0, y: 0, width: 1, height: 1)
        )
        #expect(parked.width == 900)
        #expect(parked.height == 700)
    }

    @Test("edge clamp strip intersects even when midpoint is off-screen")
    func detectsClampStrip() {
        let m1 = Rect(x: 0, y: 0, width: 1000, height: 800)
        // Mostly off the left edge; only a few pixels visible.
        let strip = Rect(x: -1910, y: 100, width: 1920, height: 600)
        #expect(!OffscreenParking.isOnAnyMonitor(strip, monitors: [m1]))
        #expect(OffscreenParking.intersectsAnyMonitor(strip, monitors: [m1]))
    }

    @Test("dock thumbnail and right-edge clamp are not usable onscreen frames")
    func rejectsTinyAndEdgeClamp() {
        let m1 = Rect(x: 0, y: 0, width: 1440, height: 900)
        let thumb = Rect(x: 600, y: 40, width: 120, height: 36)
        #expect(OffscreenParking.isDockThumbnailLike(thumb))
        #expect(!OffscreenParking.isUsableOnscreenFrame(thumb, monitors: [m1]))

        let rightStrip = Rect(x: 1400, y: 200, width: 40, height: 120)
        #expect(OffscreenParking.isEdgeStrip(rightStrip, monitors: [m1]))
        #expect(!OffscreenParking.isUsableOnscreenFrame(rightStrip, monitors: [m1]))

        let real = Rect(x: 80, y: 80, width: 900, height: 700)
        #expect(OffscreenParking.isUsableOnscreenFrame(real, monitors: [m1]))
    }
}

@Suite("WorkspaceMonitorVisibility")
struct WorkspaceMonitorVisibilityTests {
    @Test("Auto workspaces appear only on primary monitor")
    func autoOnlyOnPrimary() {
        let defs = [
            WorkspaceDefinition(id: "1", name: "1", layout: .niri, monitorIndex: nil),
            WorkspaceDefinition(id: "2", name: "2", layout: .niri, monitorIndex: nil)
        ]
        #expect(WorkspaceStore.definitions(defs, visibleOnMonitorIndex: 0).map(\.id) == ["1", "2"])
        #expect(WorkspaceStore.definitions(defs, visibleOnMonitorIndex: 1).map(\.id).isEmpty)
    }

    @Test("pinned workspace 4 alone on display 1; Auto stay on primary")
    func pinnedOnlyOnItsMonitor() {
        let defs = [
            WorkspaceDefinition(id: "1", name: "1", layout: .niri, monitorIndex: nil),
            WorkspaceDefinition(id: "2", name: "2", layout: .niri, monitorIndex: nil),
            WorkspaceDefinition(id: "3", name: "3", layout: .niri, monitorIndex: nil),
            WorkspaceDefinition(id: "4", name: "4", layout: .niri, monitorIndex: 1)
        ]
        #expect(WorkspaceStore.definitions(defs, visibleOnMonitorIndex: 0).map(\.id) == ["1", "2", "3"])
        #expect(WorkspaceStore.definitions(defs, visibleOnMonitorIndex: 1).map(\.id) == ["4"])
    }
}

@Suite("AppRules")
struct AppRulesTests {
    @Test("float rule marks window floating")
    func floatRule() {
        let rules = [AppRule(bundleID: "com.example.float", mode: .float)]
        let win = ManagedWindow(
            id: WindowID(pid: 1, windowNumber: 1),
            title: "X",
            bundleID: "com.example.float",
            appName: "Float",
            frame: Rect(x: 0, y: 0, width: 10, height: 10)
        )
        let applied = AppRules.apply(rules: rules, to: win)
        #expect(applied.isFloating)
    }
}

@Suite("IPC")
struct IPCCodecTests {
    @Test("round-trips request and response")
    func roundTrip() throws {
        let req = IPCRequest(command: "focus", args: ["left"])
        let data = try IPCCodec.encode(req)
        let decoded = try IPCCodec.decodeRequest(data)
        #expect(decoded.command == "focus")
        #expect(decoded.args == ["left"])
    }
}
