import Foundation

public enum AlwmIPC {
    public static let defaultSocketPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/state/alwm/alwm.sock"
    }()

    public static let protocolVersion = 1
}

public struct IPCRequest: Codable, Sendable {
    public var id: String
    public var command: String
    public var args: [String]

    public init(id: String = UUID().uuidString, command: String, args: [String] = []) {
        self.id = id
        self.command = command
        self.args = args
    }
}

public struct IPCResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var message: String
    public var data: [String: String]?

    public init(id: String, ok: Bool, message: String, data: [String: String]? = nil) {
        self.id = id
        self.ok = ok
        self.message = message
        self.data = data
    }
}

public enum IPCCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(contentsOf: [0x0A]) // newline-delimited JSON
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> IPCRequest {
        try JSONDecoder().decode(IPCRequest.self, from: firstLine(data))
    }

    public static func decodeResponse(_ data: Data) throws -> IPCResponse {
        try JSONDecoder().decode(IPCResponse.self, from: firstLine(data))
    }

    public static func firstLine(_ data: Data) -> Data {
        if let idx = data.firstIndex(of: 0x0A) {
            return data.subdata(in: data.startIndex..<idx)
        }
        return data
    }
}
