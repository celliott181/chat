import Foundation
import Network

protocol IRCCommand {
    func execute(connectionID: UUID, components: [String], server: IRCWebSocketServer)
}

class IRCCommandRegistry {
    private var commands: [String: IRCCommand] = [:]
    
    func register(command: String, handler: IRCCommand) {
        commands[command.uppercased()] = handler
    }
    
    func execute(command: String, connectionID: UUID, components: [String], server: IRCWebSocketServer) {
        if let handler = commands[command.uppercased()] {
            handler.execute(connectionID: connectionID, components: components, server: server)
        } else {
            server.send(connectionID, "Unknown command")
        }
    }
}

class IRCWebSocketServer {
    private var listener: NWListener?
    private var connections: [UUID: (connection: NWConnection, lastActive: Date)] = [:]
    private var nicknames: [UUID: String] = [:] // Stores user nicknames
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
        connections[connectionID] = (connection, Date())
        nicknames[connectionID] = "Anonymous" // Default nickname
        connection.start(queue: .main)
        print("Client connected")
        
        receive(connectionID)
    }
    
    private func receive(_ connectionID: UUID) {
        guard let connection = connections[connectionID]?.connection else { return }
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else { return }
            
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                self.logMessage(text)
                print("Received: \(text)")
                let components = text.split(separator: " ", maxSplits: 1).map(String.init)
                if let command = components.first?.uppercased() {
                    self.commandRegistry.execute(command: command, connectionID: connectionID, components: components, server: self)
                }
            }
            
            if isComplete {
                self.disconnect(connectionID)
            } else {
                self.connections[connectionID]?.lastActive = Date()
                self.receive(connectionID)
            }
        }
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
    
    func setNickname(_ connectionID: UUID, nickname: String) {
        nicknames[connectionID] = nickname
    }
    
    func getNickname(_ connectionID: UUID) -> String {
        return nicknames[connectionID] ?? "Anonymous"
    }
    
    fileprivate func disconnect(_ connectionID: UUID) {
        connections[connectionID]?.connection.cancel()
        connections.removeValue(forKey: connectionID)
        nicknames.removeValue(forKey: connectionID) // Remove nickname when user disconnects
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
        server.setNickname(connectionID, nickname: nickname)
        server.send(connectionID, "Your nickname is now \(nickname)")
    }
}

struct MsgCommand: IRCCommand {
    func execute(connectionID: UUID, components: [String], server: IRCWebSocketServer) {
        let nickname = server.getNickname(connectionID)
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

let server = IRCWebSocketServer(commandRegistry: commandRegistry)
server.start(port: 8080)

RunLoop.main.run()
