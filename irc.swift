import Foundation
import Network

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

// Define a signal handler function
func handleSIGINT(signal: Int32) {
    print("\nReceived SIGINT (Ctrl+C). Cleaning up and exiting...")
    // Perform any cleanup tasks here
    exit(0)
}

signal(SIGINT, handleSIGINT);

private extension Array where Element == UInt8 {
    func toUInt32Array() -> [UInt32] {
        var result = [UInt32]()
        for i in stride(from: 0, to: count, by: 4) {
            let value = (UInt32(self[i]) << 24) |
                        (UInt32(self[i + 1]) << 16) |
                        (UInt32(self[i + 2]) << 8) |
                        UInt32(self[i + 3])
            result.append(value)
        }
        return result
    }
}

private func sha1(_ data: Data) -> [UInt8] {
    var hash: [UInt32] = [
        0x67452301,
        0xEFCDAB89,
        0x98BADCFE,
        0x10325476,
        0xC3D2E1F0
    ]

    var message = data
    let originalLength = UInt64(data.count * 8)
    
    // Append '1' bit
    message.append(0x80)
    
    // Append padding (zeros) until length ≡ 448 (mod 512)
    while (message.count % 64) != 56 {
        message.append(0x00)
    }
    
    // Append original message length as 64-bit big-endian
    message.append(contentsOf: originalLength.bigEndianBytes)
    
    // Process each 512-bit chunk
    for chunk in message.chunked(into: 64) {
        var words = chunk.toUInt32Array()
        
        for i in 16..<80 {
            let value = words[i-3] ^ words[i-8] ^ words[i-14] ^ words[i-16]
            words.append(value.leftRotated(by: 1))
        }

        var a = hash[0], b = hash[1], c = hash[2], d = hash[3], e = hash[4]

        for i in 0..<80 {
            let (f, k): (UInt32, UInt32)
            switch i {
            case 0..<20:
                f = (b & c) | (~b & d)
                k = 0x5A827999
            case 20..<40:
                f = b ^ c ^ d
                k = 0x6ED9EBA1
            case 40..<60:
                f = (b & c) | (b & d) | (c & d)
                k = 0x8F1BBCDC
            default:
                f = b ^ c ^ d
                k = 0xCA62C1D6
            }

            let temp = a.leftRotated(by: 5) &+ f &+ e &+ k &+ words[i]
            e = d
            d = c
            c = b.leftRotated(by: 30)
            b = a
            a = temp
        }

        hash[0] &+= a
        hash[1] &+= b
        hash[2] &+= c
        hash[3] &+= d
        hash[4] &+= e
    }

    return hash.flatMap { $0.bigEndianBytes }
}

// Helpers for bitwise operations
private extension UInt32 {
    func leftRotated(by bits: UInt32) -> UInt32 {
        return (self << bits) | (self >> (32 - bits))
    }
    
    var bigEndianBytes: [UInt8] {
        return [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
    }
}

private extension UInt64 {
    var bigEndianBytes: [UInt8] {
        return [
            UInt8((self >> 56) & 0xFF),
            UInt8((self >> 48) & 0xFF),
            UInt8((self >> 40) & 0xFF),
            UInt8((self >> 32) & 0xFF),
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
    }
}

private extension Data {
    func chunked(into size: Int) -> [[UInt8]] {
        return stride(from: 0, to: count, by: size).map { i in
            Array(self[i..<Swift.min(i + size, count)])
        }
    }

    func toUInt32Array() -> [UInt32] {
        var result = [UInt32]()
        for i in stride(from: 0, to: count, by: 4) {
            let value = (UInt32(self[i]) << 24) |
                        (UInt32(self[i + 1]) << 16) |
                        (UInt32(self[i + 2]) << 8) |
                        UInt32(self[i + 3])
            result.append(value)
        }
        return result
    }
}

protocol IRCCommand {
    func execute(connectionID: UUID, components: [String], server: IRCWebSocketServer)
}

class IRCCommandRegistry {
    private var commands: [String: IRCCommand] = [:]
    
    func register(command: String, handler: IRCCommand) {
        commands[command] = handler
    }
    
    func execute(command: String, connectionID: UUID, components: [String], server: IRCWebSocketServer) {
        if let handler = commands[command] {
            handler.execute(connectionID: connectionID, components: components, server: server)
        } else {
            server.send(connectionID, "Unknown command")
        }
    }
}

class UserRegistry {
    private var nicknames: [UUID: String] = [:]
    private let queue = DispatchQueue(label: "UserRegistryQueue", attributes: .concurrent)
    
    func setNickname(_ connectionID: UUID, nickname: String) {
        queue.async(flags: .barrier) {
            self.nicknames[connectionID] = nickname
        }
    }
    
    func getNickname(_ connectionID: UUID) -> String {
        queue.sync {
            nicknames[connectionID] ?? "Anonymous"
        }
    }
    
    func removeUser(_ connectionID: UUID) {
        queue.async(flags: .barrier) {
            self.nicknames.removeValue(forKey: connectionID)
        }
    }
}

class IRCWebSocketServer {
    private var listener: NWListener?
    private var connections: [UUID: (connection: NWConnection, lastActive: Date)] = [:]
    private let commandRegistry: IRCCommandRegistry
    private let ttl: TimeInterval = 600 // 10 minutes
    
    init(commandRegistry: IRCCommandRegistry) {
        self.commandRegistry = commandRegistry
    }
    
    func start(port: UInt16) {
        do {
            let parameters = NWParameters.tcp
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            listener?.start(queue: .main)
            print("Server started on port \(port)")
            
            startConnectionCleanup()
        } catch {
            print("Failed to start server: \(error)")
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let connectionID = UUID()
        
        connection.start(queue: .main)
        print("Client connected, awaiting handshake...")

        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let request = String(data: data, encoding: .utf8) else {
                self?.disconnect(connectionID)
                return
            }

            if request.starts(with: "GET ") {
                if let secWebSocketKey = self.extractWebSocketKey(from: request) {
                    let response = self.websocketHandshakeResponse(for: secWebSocketKey)
                    connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
                        print("WebSocket handshake complete.")
                        self.connections[connectionID] = (connection, Date()) // Store the connection
                        self.receiveWebSocketFrames(connectionID) // Start receiving WebSocket messages
                    }))
                } else {
                    self.disconnect(connectionID)
                }
            } else {
                // If it's not a WebSocket connection, treat it as a plain IRC connection
                self.connections[connectionID] = (connection, Date())
                self.receive(connectionID)
            }
        }
    }

    private func extractWebSocketKey(from request: String) -> String? {
        let lines = request.components(separatedBy: "\r\n")
        for line in lines {
            if line.starts(with: "Sec-WebSocket-Key:") {
                return line.components(separatedBy: ": ").last
            }
        }
        return nil
    }

    private func websocketHandshakeResponse(for key: String) -> String {
        let magicString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key.trimmingCharacters(in: .whitespaces) + magicString
        let hash = sha1(Data(combined.utf8)) // Use manual SHA-1 implementation
        let acceptKeyBase64 = Data(hash).base64EncodedString()

        return """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(acceptKeyBase64)\r
        \r\n
        """
    }

    private func handleReceivedMessage(_ message: String, from connectionID: UUID) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        logMessage(trimmedMessage)
        print("Received: \(trimmedMessage)")

        let components = trimmedMessage.split(separator: " ", maxSplits: 1).map(String.init)
        if let command = components.first?.uppercased() {
            commandRegistry.execute(command: command, connectionID: connectionID, components: components, server: self)
        }
    }

    private func receiveWebSocketFrames(_ connectionID: UUID) {
        guard let connection = connections[connectionID]?.connection else { return }

        connection.receive(minimumIncompleteLength: 2, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data else { return }

            let message = self.decodeWebSocketFrame(data)
            handleReceivedMessage(message, from: connectionID)

            if isComplete {
                self.disconnect(connectionID)
            } else {
                self.receiveWebSocketFrames(connectionID)
            }
        }
    }

    private func receive(_ connectionID: UUID) {
        guard let connection = connections[connectionID]?.connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else { return }

            if let text = String(data: data, encoding: .utf8) {
                handleReceivedMessage(text, from: connectionID)
            }

            if isComplete {
                self.disconnect(connectionID)
            } else {
                self.connections[connectionID]?.lastActive = Date()
                self.receive(connectionID)
            }
        }
    }

    private func decodeWebSocketFrame(_ data: Data) -> String {
        guard data.count >= 2 else { return "" }

        let firstByte = data[0]
        let secondByte = data[1]
        let isMasked = (secondByte & 0x80) != 0
        var payloadLength = secondByte & 0x7F
        var offset = 2

        if payloadLength == 126 {
            guard data.count >= 4 else { return "" }
            payloadLength = UInt8(data[2]) << 8 | UInt8(data[3])
            offset += 2
        } else if payloadLength == 127 {
            return "" // Ignore messages that are too large
        }

        var maskingKey: [UInt8] = []
        if isMasked {
            guard data.count >= offset + 4 else { return "" }
            maskingKey = Array(data[offset..<(offset + 4)])
            offset += 4
        }

        let payloadBytes = Array(data[offset..<(offset + Int(payloadLength))])
        let unmaskedBytes = payloadBytes.enumerated().map { $0.element ^ maskingKey[$0.offset % 4] }
        
        return String(bytes: unmaskedBytes, encoding: .utf8) ?? ""
    }
    
    func send(_ connectionID: UUID, _ message: String) {
        guard let connection = connections[connectionID]?.connection else { return }
        let data = (message + "\n").data(using: .utf8) ?? Data()
        connection.send(content: data, completion: .contentProcessed({ _ in }))
    }
    
    func broadcast(_ message: String) {
        for connectionID in connections.keys {
            send(connectionID, message)
        }
    }

    fileprivate func disconnect(_ connectionID: UUID) {
        connections[connectionID]?.connection.cancel()
        connections.removeValue(forKey: connectionID)
        userRegistry.removeUser(connectionID) // Remove user on disconnect
        print("Client disconnected")
    }
    
    private func startConnectionCleanup() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.cleanupConnections()
        }
    }
    
    private func cleanupConnections() {
        let now = Date()
        for (connectionID, (_, lastActive)) in connections {
            if now.timeIntervalSince(lastActive) > ttl {
                print("Disconnecting idle client")
                disconnect(connectionID)
            }
        }
    }
    
    private func logMessage(_ message: String) {
        Task {
            let logEntry = "[\(Date())] \(message)\n"
            let logURL = URL(fileURLWithPath: "irc_server.log")
            
            do {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                if let data = logEntry.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } catch {
                do {
                    try logEntry.write(to: logURL, atomically: true, encoding: .utf8)
                } catch {
                    print("Failed to log message: \(error)")
                }
            }
        }
    }
}

struct NickCommand: IRCCommand {
    func execute(connectionID: UUID, components: [String], server: IRCWebSocketServer) {
        let nickname = components.count > 1 ? components[1] : "Anonymous"
        userRegistry.setNickname(connectionID, nickname: nickname)
        server.send(connectionID, "Your nickname is now \(nickname)")
    }
}

struct MsgCommand: IRCCommand {
    func execute(connectionID: UUID, components: [String], server: IRCWebSocketServer) {
        let nickname = userRegistry.getNickname(connectionID)
        let message = components.count > 1 ? components[1] : "(empty)"
        server.broadcast("\(nickname): \(message)")
    }
}

struct QuitCommand: IRCCommand {
    func execute(connectionID: UUID, components: [String], server: IRCWebSocketServer) {
        server.send(connectionID, "Goodbye!")
        server.disconnect(connectionID)
    }
}

let commandRegistry = IRCCommandRegistry()
commandRegistry.register(command: "NICK", handler: NickCommand())
commandRegistry.register(command: "MSG", handler: MsgCommand())
commandRegistry.register(command: "QUIT", handler: QuitCommand())

let userRegistry = UserRegistry()

let server = IRCWebSocketServer(commandRegistry: commandRegistry)
server.start(port: 8080)

RunLoop.main.run()
