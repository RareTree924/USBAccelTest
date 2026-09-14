import Foundation
import Network
import SwiftProtobuf
import Accelerate

/// TCP server on the iPhone that receives length-prefixed Protobuf
/// TaskRequests from Windows, executes them, and replies with a
/// TaskResponse — same framing/schema as the Windows C++ client.
final class TCPServer: ObservableObject {

    @Published var log: [String] = []

    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    // nil = still reading the 4-byte length header; else = bytes still needed for the payload
    private var expectedPayloadLength: Int?

    private let port: NWEndpoint.Port = 5050

    func start() {
        appendLog("[DEBUG] start() — creating NWListener on port \(port)")
        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            appendLog("[DEBUG] FAILED to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] newConnection in
            self?.appendLog("[DEBUG] New connection from \(newConnection.endpoint)")
            self?.connection = newConnection
            self?.setupConnection(newConnection)
        }
        listener?.stateUpdateHandler = { [weak self] state in
            self?.appendLog("[DEBUG] Listener state -> \(state)")
        }
        listener?.start(queue: .main)
        appendLog("[DEBUG] Listening on port \(port)")
    }

    private func setupConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            self?.appendLog("[DEBUG] Connection state -> \(state)")
        }
        connection.start(queue: .main)
        receiveMore(on: connection)
    }

    // Pulls in raw bytes; parsing of complete messages happens in extractMessages().
    private func receiveMore(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                self.appendLog("[DEBUG] Received \(data.count) raw byte(s), buffer now \(self.buffer.count + data.count)")
                self.buffer.append(data)
                self.extractMessages(on: connection)
            }
            if let error = error {
                self.appendLog("[DEBUG] Receive error: \(error)")
                return
            }
            if isComplete {
                self.appendLog("[DEBUG] Peer closed the connection")
                return
            }
            self.receiveMore(on: connection)
        }
    }

    // Length-prefix framing: 4-byte big-endian length, then that many payload bytes.
    // Loops so multiple complete messages in one chunk are all processed.
    private func extractMessages(on connection: NWConnection) {
        while true {
            if expectedPayloadLength == nil {
                guard buffer.count >= 4 else { break }
                let header = buffer.prefix(4)
                let length = header.reduce(0) { ($0 << 8) | UInt32($1) } // big-endian bytes -> UInt32
                buffer.removeFirst(4)
                expectedPayloadLength = Int(length)
                appendLog("[DEBUG] Header parsed: expecting \(length)-byte payload")
            }

            guard let needed = expectedPayloadLength, buffer.count >= needed else { break }
            let payload = buffer.prefix(needed)
            buffer.removeFirst(needed)
            expectedPayloadLength = nil

            do {
                let request = try Usbaccel_TaskRequest(serializedBytes: payload)
                appendLog("[DEBUG] Parsed TaskRequest: op=\"\(request.op)\", \(request.inputFloats.count) float(s)")
                handleTask(request, on: connection)
            } catch {
                appendLog("[DEBUG] Protobuf parse FAILED: \(error)")
            }
        }
    }

    // Runs the requested op and sends back a TaskResponse.
    private func handleTask(_ request: Usbaccel_TaskRequest, on connection: NWConnection) {
        var response = Usbaccel_TaskResponse()

        switch request.op {
        case "vdsp_multiply":
            let input = request.inputFloats
            var output = [Float](repeating: 0, count: input.count)
            var scalar: Float = 2.0
            // vDSP_vsmul: hardware-accelerated multiply of a vector by a scalar (Accelerate/CPU SIMD).
            vDSP_vsmul(input, 1, &scalar, &output, 1, vDSP_Length(input.count))

            response.success = true
            response.outputFloats = output
            appendLog("[DEBUG] vdsp_multiply: \(input) * \(scalar) = \(output)")

        default:
            response.success = false
            response.errorMessage = "Unknown op: \(request.op)"
            appendLog("[DEBUG] Unknown op requested: \(request.op)")
        }

        sendMessage(response, on: connection)
    }

    // Serializes a Protobuf message with the same 4-byte big-endian length prefix Windows expects.
    private func sendMessage(_ message: SwiftProtobuf.Message, on connection: NWConnection) {
        do {
            let payload = try message.serializedData()
            var length = UInt32(payload.count).bigEndian
            var packet = Data(bytes: &length, count: 4)
            packet.append(payload)

            appendLog("[DEBUG] Sending \(payload.count)-byte payload (+ 4-byte header)")
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    self?.appendLog("[DEBUG] Send FAILED: \(error)")
                } else {
                    self?.appendLog("[DEBUG] Send completed successfully")
                }
            })
        } catch {
            appendLog("[DEBUG] Serialization FAILED: \(error)")
        }
    }

    private func appendLog(_ text: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(text)"
        DispatchQueue.main.async { self.log.append(line) }
        print(line)
    }
}
