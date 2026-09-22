import AppKit
import Foundation
import AlwmL10n

// MARK: - Models

struct CalculatorEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var expression: String
    var result: String
    var note: String
    var pinned: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        expression: String,
        result: String,
        note: String = "",
        pinned: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.expression = expression
        self.result = result
        self.note = note
        self.pinned = pinned
        self.createdAt = createdAt
    }

    var searchBlob: String {
        "\(expression) \(result) \(note)".lowercased()
    }
}

struct CalculatorSettings: Codable, Equatable, Sendable {
    /// Max history rows (0 = unlimited).
    var maxHistory: Int = 200
    var degMode: Bool = true
    /// When true, show scientific keypad rows.
    var scientificMode: Bool = true
}

// MARK: - Store

final class CalculatorStore: ObservableObject, @unchecked Sendable {
    static let shared = CalculatorStore()

    @Published private(set) var display: String = "0"
    @Published private(set) var expression: String = ""
    /// Spotlight-style live estimate for the current expression (nil if incomplete).
    @Published private(set) var livePreview: String?
    /// Pretty expression shown while typing (expression + current operand).
    @Published private(set) var liveExpression: String = ""
    @Published private(set) var memory: Double = 0
    @Published private(set) var history: [CalculatorEntry] = []
    @Published private(set) var settings = CalculatorSettings()
    @Published private(set) var lastError: String?
    @Published var searchQuery: String = ""
    @Published var editingNoteID: UUID?

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    /// History row updated live while typing the same calculation (until C).
    private var liveHistoryID: UUID?

    private init() {
        load()
    }

    var barLabel: String {
        let raw: String
        if let livePreview, !livePreview.isEmpty {
            raw = livePreview
        } else {
            raw = display.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if raw.isEmpty || raw == "0" { return "Calc" }
        if raw.count <= 8 { return raw }
        return String(raw.prefix(7)) + "…"
    }

    var barTint: NSColor {
        lastError == nil ? .systemOrange : .systemRed
    }

    var tooltip: String {
        let loc = localeCode()
        if let lastError, !lastError.isEmpty {
            return lastError
        }
        if let livePreview, !livePreview.isEmpty, !liveExpression.isEmpty {
            return "\(liveExpression) = \(livePreview)"
        }
        if history.isEmpty {
            return PluginL10n.t("plugin.calculator.tooltip.empty", locale: loc)
        }
        return PluginL10n.tf(
            "plugin.calculator.tooltip.last",
            locale: loc,
            display
        )
    }

    var filteredHistory: [CalculatorEntry] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = history.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.createdAt > b.createdAt
        }
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.searchBlob.contains(q) }
    }

    var hasMemory: Bool { abs(memory) > 1e-12 }

    // MARK: - Keypad (continuous expression until C)

    func inputDigit(_ d: String) {
        lastError = nil
        if d == "." {
            if currentNumberHasDot() { bump(); return }
            if expression.isEmpty || endsWithOperator || expression.hasSuffix("(") {
                expression += "0."
            } else {
                expression += "."
            }
        } else if expression == "0" {
            expression = d
        } else if endsWithOperator || expression.hasSuffix("(") || expression.isEmpty {
            expression += d
        } else {
            expression += d
        }
        bump()
    }

    func inputOperator(_ op: String) {
        lastError = nil
        if expression.isEmpty {
            expression = "0" + op
        } else if endsWithOperator {
            expression.removeLast()
            expression += op
        } else {
            expression += op
        }
        bump()
    }

    func inputParen(_ p: String) {
        lastError = nil
        if p == "(" {
            if expression.isEmpty || endsWithOperator || expression.hasSuffix("(") {
                expression += "("
            } else {
                expression += "×("
            }
        } else {
            expression += ")"
        }
        bump()
    }

    func inputConstant(_ value: Double, symbol: String) {
        lastError = nil
        _ = value
        if expression.isEmpty || endsWithOperator || expression.hasSuffix("(") {
            expression += symbol
        } else {
            expression += "×" + symbol
        }
        bump()
    }

    func toggleSign() {
        lastError = nil
        guard let range = trailingNumberRange() else {
            bump()
            return
        }
        let num = String(expression[range])
        if num.hasPrefix("-") {
            let unsigned = String(num.dropFirst())
            expression.replaceSubrange(range, with: unsigned)
        } else if num.hasPrefix("("), num.hasSuffix(")"), num.count > 2,
                  num[num.index(after: num.startIndex)] == "-" {
            // (-n) → n
            let inner = String(num.dropFirst(2).dropLast())
            expression.replaceSubrange(range, with: inner)
        } else {
            expression.replaceSubrange(range, with: "(-\(num))")
        }
        bump()
    }

    func percent() {
        lastError = nil
        guard let range = trailingNumberRange(),
              let v = Double(String(expression[range]).replacingOccurrences(of: ",", with: "."))
        else { bump(); return }
        expression.replaceSubrange(range, with: format(v / 100))
        bump()
    }

    func applyUnary(_ kind: UnaryOp) {
        lastError = nil
        let source: String
        if let range = trailingNumberRange() {
            source = String(expression[range])
        } else if let preview = livePreview {
            source = preview
        } else {
            source = display
        }
        let cleaned = source
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let v = Double(cleaned) else { bump(); return }
        let out: Double
        switch kind {
        case .sqrt:
            guard v >= 0 else {
                lastError = PluginL10n.t("plugin.calculator.error.domain", locale: localeCode())
                bump()
                return
            }
            out = Darwin.sqrt(v)
        case .square:
            out = v * v
        case .reciprocal:
            guard abs(v) > 1e-15 else {
                lastError = PluginL10n.t("plugin.calculator.error.divzero", locale: localeCode())
                bump()
                return
            }
            out = 1 / v
        case .sin, .cos, .tan:
            let rad = settings.degMode ? v * .pi / 180 : v
            switch kind {
            case .sin: out = Darwin.sin(rad)
            case .cos: out = Darwin.cos(rad)
            case .tan: out = Darwin.tan(rad)
            default: out = v
            }
        }
        let result = format(out)
        expression = kind.wrap(format(v))
        display = result
        upsertLiveHistory(expression: expression, result: result)
        bump()
    }

    func clearAll() {
        display = "0"
        expression = ""
        livePreview = nil
        liveExpression = ""
        lastError = nil
        liveHistoryID = nil
        bump()
    }

    func backspace() {
        lastError = nil
        if !expression.isEmpty {
            expression.removeLast()
        }
        bump()
    }

    func evaluate() {
        lastError = nil
        refreshLivePreview()
        guard let preview = livePreview else {
            // Try hard evaluate current expression.
            let expr = normalizedMath(expression)
            do {
                let value = try CalculatorMath.evaluate(expr)
                let result = format(value)
                display = result
                saveHistoryEntry(expression: expression.isEmpty ? result : expression, result: result)
                // Keep going from the result until C — expression becomes the value.
                expression = result
                liveHistoryID = nil
                bump()
            } catch {
                lastError = PluginL10n.t("plugin.calculator.error.invalid", locale: localeCode())
                bump()
            }
            return
        }
        let pretty = expression.isEmpty ? preview : expression
        display = preview
        saveHistoryEntry(expression: pretty, result: preview)
        // Continue the same “tape”: next +/− builds on the result; only C clears.
        expression = preview
        liveHistoryID = nil
        bump()
    }

    // MARK: - Memory

    func memoryClear() {
        memory = 0
        bump()
    }

    func memoryRecall() {
        let s = format(memory)
        if expression.isEmpty || endsWithOperator || expression.hasSuffix("(") {
            expression += s
        } else {
            expression += "×" + s
        }
        bump()
    }

    func memoryAdd() {
        if let v = Double((livePreview ?? display).replacingOccurrences(of: ",", with: ".")) {
            memory += v
            bump()
        }
    }

    func memorySubtract() {
        if let v = Double((livePreview ?? display).replacingOccurrences(of: ",", with: ".")) {
            memory -= v
            bump()
        }
    }

    // MARK: - History

    func updateNote(id: UUID, note: String) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        history[idx].note = note
        persist()
        bump()
    }

    func togglePin(id: UUID) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        history[idx].pinned.toggle()
        persist()
        bump()
    }

    func deleteEntry(id: UUID) {
        if liveHistoryID == id { liveHistoryID = nil }
        history.removeAll { $0.id == id }
        persist()
        bump()
    }

    func clearUnpinnedHistory() {
        history.removeAll { !$0.pinned }
        if let id = liveHistoryID, !history.contains(where: { $0.id == id }) {
            liveHistoryID = nil
        }
        persist()
        bump()
    }

    func clearAllHistory() {
        history.removeAll()
        liveHistoryID = nil
        persist()
        bump()
    }

    func reuseEntry(_ entry: CalculatorEntry) {
        expression = entry.expression
        display = entry.result
        liveHistoryID = nil
        lastError = nil
        bump()
    }

    func copyResult(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func setDegMode(_ deg: Bool) {
        settings.degMode = deg
        persist()
        bump()
    }

    func setScientificMode(_ on: Bool) {
        settings.scientificMode = on
        persist()
        bump()
        Task { @MainActor in
            CalculatorPanelController.syncPanelSizeIfOpen()
        }
    }

    // MARK: - Expression helpers

    private var endsWithOperator: Bool {
        guard let last = expression.last else { return false }
        return "+-×÷^".contains(last)
    }

    private func currentNumberHasDot() -> Bool {
        guard let range = trailingNumberRange() else { return false }
        return String(expression[range]).contains(".")
    }

    private func trailingNumberRange() -> Range<String.Index>? {
        guard !expression.isEmpty else { return nil }
        var i = expression.endIndex
        // Optional trailing (...)
        if expression.hasSuffix(")") {
            var depth = 0
            while i > expression.startIndex {
                i = expression.index(before: i)
                let c = expression[i]
                if c == ")" { depth += 1 }
                else if c == "(" {
                    depth -= 1
                    if depth == 0 {
                        return i..<expression.endIndex
                    }
                }
            }
            return nil
        }
        var start = expression.endIndex
        while start > expression.startIndex {
            let prev = expression.index(before: start)
            let c = expression[prev]
            if c.isNumber || c == "." || c == "e" || c == "E" {
                start = prev
                continue
            }
            if (c == "+" || c == "-"), start > expression.startIndex {
                let before = expression.index(before: start)
                // exponent sign
                if expression[before] == "e" || expression[before] == "E" {
                    start = prev
                    continue
                }
            }
            break
        }
        if start == expression.endIndex { return nil }
        return start..<expression.endIndex
    }

    private func normalizedMath(_ pretty: String) -> String {
        pretty
            .replacingOccurrences(of: "π", with: String(Double.pi))
            .replacingOccurrences(of: "e", with: String(Darwin.M_E))
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "^", with: "**")
    }

    func handleKey(_ chars: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers.contains(.command) {
            if chars.lowercased() == "c" {
                copyResult(display)
                return true
            }
            if chars.lowercased() == "v" {
                if let s = NSPasteboard.general.string(forType: .string) {
                    let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let v = Double(cleaned.replacingOccurrences(of: ",", with: ".")) {
                        let formatted = format(v)
                        if expression.isEmpty || endsWithOperator || expression.hasSuffix("(") {
                            expression += formatted
                        } else {
                            expression += "×" + formatted
                        }
                        bump()
                        return true
                    }
                }
            }
            return false
        }
        switch keyCode {
        case 51, 117: // delete / forward delete
            backspace()
            return true
        case 36, 76: // return / keypad enter
            evaluate()
            return true
        case 53: // escape
            clearAll()
            return true
        default:
            break
        }
        for ch in chars {
            switch ch {
            case "0"..."9":
                inputDigit(String(ch))
                return true
            case ".", ",":
                inputDigit(".")
                return true
            case "+":
                inputOperator("+")
                return true
            case "-":
                inputOperator("-")
                return true
            case "*", "x", "X":
                inputOperator("×")
                return true
            case "/":
                inputOperator("÷")
                return true
            case "^":
                inputOperator("^")
                return true
            case "%":
                percent()
                return true
            case "(":
                inputParen("(")
                return true
            case ")":
                inputParen(")")
                return true
            case "=", "\r", "\n":
                evaluate()
                return true
            case "c", "C":
                clearAll()
                return true
            default:
                continue
            }
        }
        return false
    }

    // MARK: - Private

    enum UnaryOp {
        case sqrt, square, reciprocal, sin, cos, tan

        func wrap(_ inner: String) -> String {
            switch self {
            case .sqrt: return "√(\(inner))"
            case .square: return "(\(inner))²"
            case .reciprocal: return "1/(\(inner))"
            case .sin: return "sin(\(inner))"
            case .cos: return "cos(\(inner))"
            case .tan: return "tan(\(inner))"
            }
        }
    }

    private func format(_ value: Double) -> String {
        if value.isNaN || value.isInfinite {
            return "Error"
        }
        if abs(value) < 1e-12 { return "0" }
        let absV = abs(value)
        if absV >= 1e12 || (absV > 0 && absV < 1e-6) {
            return String(format: "%.6g", value)
        }
        var s = String(format: "%.10g", value)
        if s.contains("e") || s.contains("E") { return s }
        if s.contains(".") {
            while s.last == "0" { s.removeLast() }
            if s.last == "." { s.removeLast() }
        }
        return s
    }

    private func saveHistoryEntry(expression: String, result: String) {
        let expr = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expr.isEmpty, result != "Error" else { return }
        if let id = liveHistoryID, let idx = history.firstIndex(where: { $0.id == id }) {
            history[idx].expression = expr
            history[idx].result = result
            history[idx].createdAt = Date()
            if idx != 0 {
                let entry = history.remove(at: idx)
                history.insert(entry, at: 0)
            }
            liveHistoryID = nil
            trimHistory()
            persist()
            return
        }
        if let first = history.first, first.expression == expr, first.result == result {
            liveHistoryID = nil
            return
        }
        history.insert(
            CalculatorEntry(expression: expr, result: result),
            at: 0
        )
        liveHistoryID = nil
        trimHistory()
        persist()
    }

    /// Keep one draft history row in sync with the live estimate for this calculation.
    private func upsertLiveHistory(expression: String, result: String) {
        let expr = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expr.isEmpty, result != "Error" else { return }
        let hasOp = expr.contains(where: { "+-×÷^".contains($0) })
            || expr.contains("√") || expr.contains("sin") || expr.contains("cos") || expr.contains("tan")
            || expr.contains("²") || expr.hasPrefix("1/")
        guard hasOp else { return }

        if let id = liveHistoryID, let idx = history.firstIndex(where: { $0.id == id }) {
            if history[idx].expression == expr, history[idx].result == result { return }
            history[idx].expression = expr
            history[idx].result = result
            history[idx].createdAt = Date()
            if idx != 0 {
                let entry = history.remove(at: idx)
                history.insert(entry, at: 0)
            }
        } else {
            let entry = CalculatorEntry(expression: expr, result: result)
            liveHistoryID = entry.id
            history.insert(entry, at: 0)
        }
        trimHistory()
        persist()
    }

    private func trimHistory() {
        let limit = settings.maxHistory
        guard limit > 0 else { return }
        let pinned = history.filter(\.pinned)
        var rest = history.filter { !$0.pinned }
        let room = max(0, limit - pinned.count)
        if rest.count > room {
            rest = Array(rest.prefix(room))
        }
        history = pinned + rest
        if let id = liveHistoryID, !history.contains(where: { $0.id == id }) {
            liveHistoryID = nil
        }
    }

    private func bump() {
        refreshLivePreview()
        objectWillChange.send()
        onChange?()
    }

    private func refreshLivePreview() {
        let pretty = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        liveExpression = pretty
        guard !pretty.isEmpty else {
            livePreview = nil
            display = "0"
            return
        }
        let expr = normalizedMath(pretty)
        if let value = CalculatorMath.liveEvaluate(expr) {
            let formatted = format(value)
            let hasOp = pretty.contains(where: { "+-×÷^".contains($0) })
                || pretty.contains("√") || pretty.contains("sin") || pretty.contains("cos")
                || pretty.contains("tan") || pretty.contains("²") || pretty.contains("(")
            if hasOp {
                livePreview = formatted
                display = formatted
                upsertLiveHistory(expression: pretty, result: formatted)
            } else {
                // Lone number — show it, no estimate pill / no history spam.
                livePreview = nil
                display = formatted
            }
        } else {
            livePreview = nil
            if let range = trailingNumberRange() {
                display = String(expression[range])
            }
        }
    }

    // MARK: - Persistence

    private var pluginDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alwm/plugins", isDirectory: true)
    }

    private var settingsURL: URL {
        pluginDir.appendingPathComponent("dev.alwm.calculator.json")
    }

    private struct Persisted: Codable {
        var settings: CalculatorSettings
        var memory: Double
        var history: [CalculatorEntry]
        var display: String?
        var expression: String?
    }

    private func load() {
        guard let data = try? Data(contentsOf: settingsURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let decoded = try? dec.decode(Persisted.self, from: data) else { return }
        settings = decoded.settings
        memory = decoded.memory
        history = decoded.history
        if let d = decoded.display, !d.isEmpty { display = d }
        if let e = decoded.expression { expression = e }
        refreshLivePreview()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let payload = Persisted(
            settings: settings,
            memory: memory,
            history: history,
            display: display,
            expression: expression
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(payload) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }
}

// MARK: - Expression evaluator

enum CalculatorMath {
    enum MathError: Error {
        case invalid
    }

    static func evaluate(_ raw: String) throws -> Double {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw MathError.invalid }
        var tokens = try tokenize(s)
        let rpn = try toRPN(&tokens)
        return try evalRPN(rpn)
    }

    /// Best-effort evaluation for Spotlight-style live estimates.
    /// Strips trailing operators and closes open parentheses.
    static func liveEvaluate(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while let last = s.last {
            if "+-*/^".contains(last) {
                s.removeLast()
                continue
            }
            if last == "(" {
                s.removeLast()
                continue
            }
            break
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let opens = s.filter { $0 == "(" }.count
        let closes = s.filter { $0 == ")" }.count
        if opens > closes {
            s += String(repeating: ")", count: opens - closes)
        } else if closes > opens {
            return nil
        }
        return try? evaluate(s)
    }

    private enum Token: Equatable {
        case number(Double)
        case op(Character)
        case lparen
        case rparen
    }

    private static func tokenize(_ s: String) throws -> [Token] {
        var out: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c.isWhitespace {
                i = s.index(after: i)
                continue
            }
            if c == "(" {
                out.append(.lparen)
                i = s.index(after: i)
                continue
            }
            if c == ")" {
                out.append(.rparen)
                i = s.index(after: i)
                continue
            }
            if "+*/^".contains(c) {
                out.append(.op(c))
                i = s.index(after: i)
                continue
            }
            if c == "-" {
                let unary: Bool
                if out.isEmpty {
                    unary = true
                } else if case .op = out.last {
                    unary = true
                } else if case .lparen = out.last {
                    unary = true
                } else {
                    unary = false
                }
                if unary {
                    // Treat as part of number if digits follow, else 0 - x
                    let next = s.index(after: i)
                    if next < s.endIndex, s[next].isNumber || s[next] == "." {
                        var j = next
                        var num = "-"
                        while j < s.endIndex, s[j].isNumber || s[j] == "." || s[j] == "e" || s[j] == "E" {
                            if s[j] == "e" || s[j] == "E" {
                                num.append(s[j])
                                j = s.index(after: j)
                                if j < s.endIndex, s[j] == "+" || s[j] == "-" {
                                    num.append(s[j])
                                    j = s.index(after: j)
                                }
                                continue
                            }
                            num.append(s[j])
                            j = s.index(after: j)
                        }
                        guard let v = Double(num) else { throw MathError.invalid }
                        out.append(.number(v))
                        i = j
                        continue
                    }
                    out.append(.number(0))
                    out.append(.op("-"))
                    i = s.index(after: i)
                    continue
                }
                out.append(.op("-"))
                i = s.index(after: i)
                continue
            }
            if c.isNumber || c == "." {
                var j = i
                var num = ""
                while j < s.endIndex, s[j].isNumber || s[j] == "." || s[j] == "e" || s[j] == "E" {
                    if s[j] == "e" || s[j] == "E" {
                        num.append(s[j])
                        j = s.index(after: j)
                        if j < s.endIndex, s[j] == "+" || s[j] == "-" {
                            num.append(s[j])
                            j = s.index(after: j)
                        }
                        continue
                    }
                    num.append(s[j])
                    j = s.index(after: j)
                }
                guard let v = Double(num) else { throw MathError.invalid }
                out.append(.number(v))
                i = j
                continue
            }
            // multi-char ** already normalized to single ^ by caller using **
            if c == "*" {
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "*" {
                    out.append(.op("^"))
                    i = s.index(after: next)
                    continue
                }
                out.append(.op("*"))
                i = s.index(after: i)
                continue
            }
            throw MathError.invalid
        }
        return out
    }

    private static func precedence(_ op: Character) -> Int {
        switch op {
        case "+", "-": return 1
        case "*", "/": return 2
        case "^": return 3
        default: return 0
        }
    }

    private static func rightAssoc(_ op: Character) -> Bool {
        op == "^"
    }

    private static func toRPN(_ tokens: inout [Token]) throws -> [Token] {
        var output: [Token] = []
        var stack: [Token] = []
        for t in tokens {
            switch t {
            case .number:
                output.append(t)
            case .op(let o):
                while let top = stack.last, case .op(let to) = top {
                    let pop: Bool
                    if rightAssoc(o) {
                        pop = precedence(to) > precedence(o)
                    } else {
                        pop = precedence(to) >= precedence(o)
                    }
                    if pop {
                        output.append(stack.removeLast())
                    } else {
                        break
                    }
                }
                stack.append(t)
            case .lparen:
                stack.append(t)
            case .rparen:
                var found = false
                while let top = stack.last {
                    stack.removeLast()
                    if case .lparen = top {
                        found = true
                        break
                    }
                    output.append(top)
                }
                if !found { throw MathError.invalid }
            }
        }
        while let top = stack.popLast() {
            if case .lparen = top { throw MathError.invalid }
            if case .rparen = top { throw MathError.invalid }
            output.append(top)
        }
        return output
    }

    private static func evalRPN(_ rpn: [Token]) throws -> Double {
        var stack: [Double] = []
        for t in rpn {
            switch t {
            case .number(let n):
                stack.append(n)
            case .op(let o):
                guard stack.count >= 2 else { throw MathError.invalid }
                let b = stack.removeLast()
                let a = stack.removeLast()
                let r: Double
                switch o {
                case "+": r = a + b
                case "-": r = a - b
                case "*": r = a * b
                case "/":
                    guard abs(b) > 1e-15 else { throw MathError.invalid }
                    r = a / b
                case "^": r = pow(a, b)
                default: throw MathError.invalid
                }
                stack.append(r)
            default:
                throw MathError.invalid
            }
        }
        guard stack.count == 1 else { throw MathError.invalid }
        return stack[0]
    }
}
