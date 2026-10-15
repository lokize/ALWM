import Foundation

public enum WorkspaceDiagnosticKind: String, CaseIterable, Sendable {
    case wrongWorkspace
    case wrongMonitor
    case offLayout
    case missingWindow
    case incompleteSession
    case accessibilityUnavailable
}

public enum WorkspaceDiagnosticSeverity: Int, Sendable {
    case info
    case warning
    case error
}

public struct WorkspaceDiagnosticIssue: Equatable, Sendable, Identifiable {
    public var id: String { "\(kind.rawValue):\(windowToken ?? bundleID ?? workspaceID ?? "unknown")" }
    public let kind: WorkspaceDiagnosticKind
    public let severity: WorkspaceDiagnosticSeverity
    public let appName: String?
    public let bundleID: String?
    public let windowToken: String?
    public let workspaceID: String?
    public let expected: String?
    public let observed: String?
    public let detail: String

    public init(
        kind: WorkspaceDiagnosticKind,
        severity: WorkspaceDiagnosticSeverity,
        appName: String? = nil,
        bundleID: String? = nil,
        windowToken: String? = nil,
        workspaceID: String? = nil,
        expected: String? = nil,
        observed: String? = nil,
        detail: String
    ) {
        self.kind = kind
        self.severity = severity
        self.appName = appName
        self.bundleID = bundleID
        self.windowToken = windowToken
        self.workspaceID = workspaceID
        self.expected = expected
        self.observed = observed
        self.detail = detail
    }
}

public struct WorkspaceDiagnosticReport: Equatable, Sendable {
    public let scannedAt: Date
    public let scanComplete: Bool
    public let windowCount: Int
    public let issues: [WorkspaceDiagnosticIssue]

    public init(scannedAt: Date = Date(), scanComplete: Bool, windowCount: Int, issues: [WorkspaceDiagnosticIssue]) {
        self.scannedAt = scannedAt
        self.scanComplete = scanComplete
        self.windowCount = windowCount
        self.issues = issues
    }

    public var issueCount: Int { issues.count }
    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
}
