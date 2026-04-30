import Foundation
import Darwin

/// Low-level TCP client for the Tor control protocol.
/// Uses a serial DispatchQueue for commands + a dedicated reader thread.
/// DispatchSemaphore is used for request/response sync — never blocks the main thread.
final class TorControlSocket: @unchecked Sendable {

    // MARK: - Event stream

    private(set) var eventStream: AsyncStream<String>
    private var eventContinuation: AsyncStream<String>.Continuation?

    // MARK: - Private

    private var socketFD: Int32 = -1

    /// Serialises command sends — only one command in-flight at a time.
    private let commandQueue = DispatchQueue(label: "com.torii.control.cmd", qos: .userInitiated)

    /// Guards pendingCallback (written on commandQueue, read on reader thread).
    private let lock = NSLock()
    private var pendingCallback: ((Result<[String], Error>) -> Void)?

    /// Only touched on the reader thread.
    private var receiveBuffer = ""
    private var replyLines: [String] = []

    // MARK: - Init

    init() {
        var cont: AsyncStream<String>.Continuation!
        eventStream = AsyncStream<String> { cont = $0 }
        eventContinuation = cont
    }

    // MARK: - Connect

    func connect(host: String = "127.0.0.1", port: UInt16 = 9051) async throws {
        // Fresh event stream for each connection
        var cont: AsyncStream<String>.Continuation!
        eventStream = AsyncStream<String> { cont = $0 }
        eventContinuation = cont

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw ControlError.notConnected }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let result: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw ControlError.notConnected
        }

        socketFD = fd
        Thread.detachNewThread { [weak self] in self?.readerLoop(fd: fd) }
    }

    // MARK: - Auth & Commands

    func authenticate(cookie: Data) async throws {
        let hex = cookie.map { String(format: "%02x", $0) }.joined()
        let response = try await sendCommand("AUTHENTICATE \(hex)")
        guard response.first?.hasPrefix("250") == true else {
            throw ControlError.authFailed(response.first ?? "no response")
        }
    }

    func subscribeEvents(_ events: [String]) async throws {
        let response = try await sendCommand("SETEVENTS \(events.joined(separator: " "))")
        guard response.first?.hasPrefix("250") == true else {
            throw ControlError.commandFailed(response.joined(separator: " "))
        }
    }

    func getInfo(_ key: String) async throws -> String {
        let response = try await sendCommand("GETINFO \(key)")
        for line in response {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("250-") || stripped.hasPrefix("250 ") {
                let rest = String(stripped.dropFirst(4))
                if let eq = rest.firstIndex(of: "=") {
                    return String(rest[rest.index(after: eq)...])
                }
                return rest
            }
        }
        return response.joined(separator: "\n")
    }

    func signal(_ name: String) async throws {
        let r = try await sendCommand("SIGNAL \(name)")
        guard r.first?.hasPrefix("250") == true else { throw ControlError.commandFailed(r.joined()) }
    }

    func setConf(_ key: String, value: String) async throws {
        let r = try await sendCommand("SETCONF \(key)=\(value)")
        guard r.first?.hasPrefix("250") == true else { throw ControlError.commandFailed(r.joined()) }
    }

    func resetConf(_ key: String) async throws {
        let r = try await sendCommand("RESETCONF \(key)")
        guard r.first?.hasPrefix("250") == true else { throw ControlError.commandFailed(r.joined()) }
    }

    // MARK: - Disconnect

    func disconnect() {
        let fd = socketFD
        socketFD = -1
        if fd >= 0 { Darwin.close(fd) }   // makes recv() return 0 → reader exits

        lock.lock()
        let cb = pendingCallback
        pendingCallback = nil
        lock.unlock()
        cb?(.failure(ControlError.connectionCancelled))

        eventContinuation?.finish()
    }

    // MARK: - Private: sendCommand
    //
    // Key design:
    //   1. commandQueue.async dispatches to a background thread — never blocks main actor.
    //   2. DispatchSemaphore.wait() blocks THAT background thread until the reader delivers the reply.
    //   3. cont.resume() is called from the background thread → async Task is rescheduled correctly.

    func sendCommand(_ cmd: String) async throws -> [String] {
        return try await withCheckedThrowingContinuation { cont in
            commandQueue.async { [self] in
                guard self.socketFD >= 0 else {
                    cont.resume(throwing: ControlError.notConnected)
                    return
                }

                let sem = DispatchSemaphore(value: 0)
                var reply: Result<[String], Error> = .failure(ControlError.connectionCancelled)

                self.lock.lock()
                self.pendingCallback = { result in
                    reply = result
                    sem.signal()
                }
                self.lock.unlock()

                let data = Data((cmd + "\r\n").utf8)
                let written = data.withUnsafeBytes { Darwin.write(self.socketFD, $0.baseAddress!, $0.count) }

                guard written > 0 else {
                    self.lock.lock()
                    self.pendingCallback = nil
                    self.lock.unlock()
                    cont.resume(throwing: ControlError.notConnected)
                    return
                }

                sem.wait()
                cont.resume(with: reply)
            }
        }
    }

    // MARK: - Private: reader thread (blocking recv loop)

    private func readerLoop(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            NSLog("[TCS] recv returned \(n)")
            guard n > 0 else {
                // EOF or error — fail any pending command and close event stream.
                lock.lock()
                let cb = pendingCallback
                pendingCallback = nil
                lock.unlock()
                cb?(.failure(ControlError.connectionCancelled))
                eventContinuation?.finish()
                return
            }

            guard let text = String(bytes: buf[..<n], encoding: .utf8) else { continue }
            receiveBuffer += text

            // NOTE: In Swift, "\r\n" is a SINGLE grapheme cluster, so we must
            // search for "\r\n" as the delimiter, not just "\n".
            while let range = receiveBuffer.range(of: "\r\n") {
                let line = String(receiveBuffer[receiveBuffer.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                receiveBuffer.removeSubrange(..<range.upperBound)
                guard !line.isEmpty else { continue }

                // Async event (650 …)
                if line.hasPrefix("650") {
                    eventContinuation?.yield(line)
                    continue
                }

                // Command reply accumulation
                replyLines.append(line)
                let isFinal = line.count >= 4
                    && line.dropFirst(3).prefix(1) == " "
                    && line.prefix(3).allSatisfy(\.isNumber)

                if isFinal {
                    let lines = replyLines
                    replyLines = []
                    lock.lock()
                    let cb = pendingCallback
                    pendingCallback = nil
                    lock.unlock()
                    cb?(.success(lines))
                }
            }
        }
    }
}

// MARK: - Errors

enum ControlError: LocalizedError {
    case notConnected
    case authFailed(String)
    case commandFailed(String)
    case connectionCancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:          return "Control socket not connected."
        case .authFailed(let m):     return "Control auth failed: \(m)"
        case .commandFailed(let m):  return "Control command failed: \(m)"
        case .connectionCancelled:   return "Control connection was cancelled."
        }
    }
}
