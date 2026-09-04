import Foundation
import Darwin

public enum IPCClient {
    public static func send(_ request: IPCRequest, path: String = AlwmIPC.defaultSocketPath) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { cPtr in
                for (i, b) in pathBytes.enumerated() { cPtr[i] = b }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard ok == 0 else { throw POSIXError(.ECONNREFUSED) }

        let payload = try IPCCodec.encode(request)
        try payload.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            if write(fd, base, payload.count) < 0 { throw POSIXError(.EIO) }
        }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { throw POSIXError(.EIO) }
        let data = Data(buffer[0..<Int(n)])
        return try IPCCodec.decodeResponse(data)
    }
}
