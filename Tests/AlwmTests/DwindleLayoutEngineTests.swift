import Testing
@testable import Alwm

@Suite("DwindleLayoutEngine")
struct DwindleLayoutEngineTests {
    let monitor = Rect(x: 0, y: 0, width: 1200, height: 800)

    @Test("splits two windows side by side")
    func twoWindowsSideBySide() {
        var ws = WorkspaceState(id: "1", name: "1", layout: .dwindle)
        let engine = DwindleLayoutEngine(settings: .default)
        let a = WindowID(pid: 1, windowNumber: 1)
        let b = WindowID(pid: 1, windowNumber: 2)
        engine.insertWindow(a, into: &ws)
        engine.insertWindow(b, into: &ws)
        let windows: [WindowID: ManagedWindow] = [
            a: ManagedWindow(id: a, title: "A", bundleID: nil, appName: "A", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            b: ManagedWindow(id: b, title: "B", bundleID: nil, appName: "B", frame: .init(x: 0, y: 0, width: 100, height: 100))
        ]
        let frames = engine.computeFrames(workspace: ws, windows: windows, monitor: monitor, active: true)
        #expect(frames.count == 2)
        let af = frames.first(where: { $0.windowID == a })!.frame
        let bf = frames.first(where: { $0.windowID == b })!.frame
        #expect(af.x < bf.x)
        #expect(abs(af.height - bf.height) < 1)
    }
}
