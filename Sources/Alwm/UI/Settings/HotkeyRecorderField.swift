import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - Hotkey recorder field

struct HotkeyRecorderField: View {
    @Binding var key: String
    @Binding var modifiers: [String]
    @State var recording = false
    @State var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(display)
                .font(.body.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(recording ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
            Button(recording ? "Esc…" : "Gravar") {
                if recording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }
            .buttonStyle(.bordered)
        }
        .onDisappear { stopRecording() }
    }

    var display: String {
        if recording { return "Pressione…" }
        return HotkeyActions.chord(key: key, modifiers: modifiers)
    }

    func startRecording() {
        stopRecording()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // escape
                DispatchQueue.main.async { stopRecording() }
                return nil
            }
            var mods: [String] = []
            if event.modifierFlags.contains(.command) { mods.append("command") }
            if event.modifierFlags.contains(.option) { mods.append("option") }
            if event.modifierFlags.contains(.shift) { mods.append("shift") }
            if event.modifierFlags.contains(.control) { mods.append("control") }
            if let name = Self.keyName(from: event) {
                DispatchQueue.main.async {
                    key = name
                    modifiers = mods
                    stopRecording()
                }
            }
            return nil
        }
    }

    func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = false
    }

    static func keyName(from event: NSEvent) -> String? {
        let code = event.keyCode
        let map: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
            123: "left", 124: "right", 125: "down", 126: "up",
            49: "space", 48: "tab", 36: "return", 53: "escape",
            43: ",", 47: ".",
            27: "-", 24: "=",
            33: "[", 30: "]",
            50: "grave",
            10: "grave", // ISO section — often the `~ key on ABNT/ISO
            39: "'"
        ]
        return map[code]
    }
}

