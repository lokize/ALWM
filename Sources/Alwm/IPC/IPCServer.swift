import Foundation
import AlwmIPC
import Darwin

public final class IPCServer: @unchecked Sendable {
    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.alwm.ipc")
    private var socketPath: String = AlwmIPC.defaultSocketPath
    public var handler: ((IPCRequest) -> IPCResponse)?

    public init() {}

    public func start(path: String = AlwmIPC.defaultSocketPath) throws {
        stop()
        socketPath = path
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { cPtr in
                for (i, b) in pathBytes.enumerated() {
                    cPtr[i] = b
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EIO)
        }
        serverFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.setCancelHandler {
            close(fd)
        }
        acceptSource = source
        source.resume()
    }

    private func acceptClient() {
        let client = accept(serverFD, nil, nil)
        guard client >= 0 else { return }
        queue.async { [weak self] in
            self?.serve(client: client)
        }
    }

    private func serve(client: Int32) {
        defer { close(client) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let n = read(client, &buffer, buffer.count)
        guard n > 0 else { return }
        let count = Int(n)
        let data = Data(buffer[0..<count])
        do {
            let req = try IPCCodec.decodeRequest(data)
            let response = handler?(req) ?? IPCResponse(id: req.id, ok: false, message: "no handler")
            let out = try IPCCodec.encode(response)
            out.withUnsafeBytes { raw in
                if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                    _ = write(client, base, out.count)
                }
            }
        } catch {
            let response = IPCResponse(id: "?", ok: false, message: error.localizedDescription)
            if let out = try? IPCCodec.encode(response) {
                out.withUnsafeBytes { raw in
                    if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                        _ = write(client, base, out.count)
                    }
                }
            }
        }
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    deinit { stop() }
}
