import Foundation
import Network

/// A minimal TCP server the iPhone runs so the Windows PC can send it tasks
/// through the USB cable, via the usbmux tunnel (go-ios "forward").
/// Every stage prints a [DEBUG] line so you can watch the whole flow live.
final class TCPServer: ObservableObject {

    // Log lines shown in the UI so we can see what happened, live, on the phone.
    @Published var log: [String] = []

    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()

    // Must match the target port used in the go-ios "forward" command
    // and the port the Windows client connects to.
    private let port: NWEndpoint.Port = 5050

    /// Starts listening. Call once, e.g. from ContentView's onAppear.
    func start() {
        appendLog("[DEBUG] start() called — creating NWListener on port \(port)")

        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            appendLog("[DEBUG] FAILED to create listener: \(error)")
            return
        }

        appendLog("[DEBUG] Listener object created successfully")

        listener?.newConnectionHandler = { [weak self] newConnection in
            self?.appendLog("[DEBUG] newConnectionHandler fired — a client connected")
            self?.appendLog("[DEBUG] Remote endpoint: \(newConnection.endpoint)")
            self?.connection = newConnection
            self?.setupConnection(newConnection)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            self?.appendLog("[DEBUG] Listener state changed -> \(state)")
        }

        listener?.start(queue: .main)
        appendLog("[DEBUG] listener.start() called, now listening on port \(port)")
    }

    private func setupConnection(_ connection: NWConnection) {
        appendLog("[DEBUG] setupConnection() — wiring up state handler and starting receive loop")

        connection.stateUpdateHandler = { [weak self] state in
            self?.appendLog("[DEBUG] Connection state changed -> \(state)")
            if case .failed(let error) = state {
                self?.appendLog("[DEBUG] Connection FAILED: \(error)")
            }
        }
        connection.start(queue: .main)
        receiveMore(on: connection)
    }

    /// Pulls in raw bytes and hands complete lines off to handleMessage().
    private func receiveMore(on connection: NWConnection) {
        appendLog("[DEBUG] receiveMore() — waiting for next chunk of data...")

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                self.appendLog("[DEBUG] Received \(data.count) raw byte(s)")
                if let preview = String(data: data, encoding: .utf8) {
                    self.appendLog("[DEBUG] Raw bytes as text: \(preview.debugDescription)")
                }
                self.buffer.append(data)
                self.appendLog("[DEBUG] Buffer size after append: \(self.buffer.count) byte(s)")
                self.extractLines(on: connection)
            }

            if let error = error {
                self.appendLog("[DEBUG] Receive error: \(error)")
                return
            }

            if isComplete {
                self.appendLog("[DEBUG] Connection reported isComplete — peer closed the connection")
                return
            }

            // Keep waiting for the next chunk of data.
            self.receiveMore(on: connection)
        }
    }

    /// Splits the buffer on '\n' and dispatches each complete line.
    private func extractLines(on connection: NWConnection) {
        appendLog("[DEBUG] extractLines() — scanning buffer for newline byte (0x0A)")

        while let newlineIndex = buffer.firstIndex(of: 0x0A) { // ASCII '\n'
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)

            appendLog("[DEBUG] Found complete line: \(lineData.count) byte(s). Remaining buffer: \(buffer.count) byte(s)")

            if let line = String(data: lineData, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                appendLog("[DEBUG] Decoded line as UTF-8 string: \"\(trimmed)\"")
                handleMessage(trimmed, on: connection)
            } else {
                appendLog("[DEBUG] FAILED to decode line as UTF-8")
            }
        }

        appendLog("[DEBUG] No more complete lines in buffer, waiting for more data")
    }

    /// The actual "protocol" for this test — just two message shapes.
    private func handleMessage(_ message: String, on connection: NWConnection) {
        appendLog("[DEBUG] handleMessage() — classifying message: \"\(message)\"")
        appendLog("Received: \(message)")

        if message == "Hello iPhone" {
            appendLog("[DEBUG] Matched greeting task -> replying with 'Hello Windows'")
            send("Hello Windows", on: connection)

        } else if message.hasPrefix("SUM:") {
            appendLog("[DEBUG] Matched SUM task -> parsing numbers")

            let rawList = message.dropFirst("SUM:".count)
            appendLog("[DEBUG] Raw number list string: \"\(rawList)\"")

            let parts = rawList.split(separator: ",")
            appendLog("[DEBUG] Split into \(parts.count) piece(s): \(parts)")

            let numbers = parts.compactMap { Int($0) }
            appendLog("[DEBUG] Parsed as integers: \(numbers)")

            var total = 0
            for n in numbers {
                total += n
                appendLog("[DEBUG] Running total after adding \(n): \(total)")
            }

            appendLog("Computed sum = \(total)")
            send("RESULT:\(total)", on: connection)

        } else {
            appendLog("[DEBUG] Message did not match any known task type")
            appendLog("Unrecognized message: \(message)")
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let data = (text + "\n").data(using: .utf8)!
        appendLog("[DEBUG] send() — sending \(data.count) byte(s): \"\(text)\"")

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.appendLog("[DEBUG] Send FAILED: \(error)")
            } else {
                self?.appendLog("[DEBUG] Send completed successfully")
                self?.appendLog("Sent: \(text)")
            }
        })
    }

    private func appendLog(_ text: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(text)"
        DispatchQueue.main.async {
            self.log.append(line)
        }
        print(line) // also visible in Xcode's console / device console
    }
}
