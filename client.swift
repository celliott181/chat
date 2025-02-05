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

class IRCClient {
    private var connection: NWConnection
    private var messages: [String] = []
    private var inputBuffer: String = ""
    private let maxInputLines: Int
    private let maxMessages: Int
    
    init(host: String, port: UInt16) {
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.maxMessages = max(5, getTerminalSize().rows - 5)
        self.maxInputLines = max(1, Int(Double(getTerminalSize().rows) * 0.2))
    }
    
    func start() {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.messages.append("# Connected to server.")
                self.renderUI()
                self.receiveMessages()
            case .failed(let error):
                print("# Connection failed: \(error)")
            default:
                break
            }
        }
        
        connection.start(queue: .global())

        inputLoop()
    }
    
    private func receiveMessages() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
            if let data = data, let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                self.messages.append(message)
                if self.messages.count > self.maxMessages {
                    self.messages.removeFirst()
                }
                self.renderUI()
            }
            if error == nil {
                self.receiveMessages()
            }
        }
    }
    
    private func inputLoop() {
        while true {
            if let input = readLine(strippingNewline: false) {
                inputBuffer += input
                if inputBuffer.hasSuffix("\n") {
                    sendMessage(inputBuffer.trimmingCharacters(in: .newlines))
                    inputBuffer = ""
                }
                renderUI()
            }
        }
    }
    
    private func sendMessage(_ message: String) {
        let data = (message + "\n").data(using: .utf8) ?? Data()
        connection.send(content: data, completion: .contentProcessed({ _ in }))
    }
    
    private func renderUI() {
        let (rows, cols) = getTerminalSize()
        let inputLines = min(maxInputLines, inputBuffer.split(separator: "\n").count)
        let feedHeight = rows - inputLines - 2
        
        print("\u{001B}[2J") // Clear screen
        print(messages.suffix(feedHeight).joined(separator: "\n"))
        print(String(repeating: "-", count: cols))
        print(inputBuffer)
    }
}

func getTerminalSize() -> (rows: Int, cols: Int) {
    var w = winsize()
    _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &w)
    return (Int(w.ws_row), Int(w.ws_col))
}

let client = IRCClient(host: "localhost", port: 8080)
client.start()
