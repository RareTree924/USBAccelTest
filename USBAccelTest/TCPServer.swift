import Foundation
import Network
import SwiftProtobuf
import Accelerate

final class TCPServer: ObservableObject {

    @Published var log: [String] = []

    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
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

    private func receiveMore(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.appendLog("[DEBUG] Received \(data.count) raw byte(s)")
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

    private func extractMessages(on connection: NWConnection) {
        while true {
            if expectedPayloadLength == nil {
                guard buffer.count >= 4 else { break }
                let header = buffer.prefix(4)
                let length = header.reduce(0) { ($0 << 8) | UInt32($1) }
                buffer.removeFirst(4)
                expectedPayloadLength = Int(length)
            }
            guard let needed = expectedPayloadLength, buffer.count >= needed else { break }
            let payload = buffer.prefix(needed)
            buffer.removeFirst(needed)
            expectedPayloadLength = nil

            do {
                let request = try Usbaccel_TaskRequest(serializedBytes: payload)
                appendLog("[DEBUG] TaskRequest id=\(request.taskID) op=\(request.op) unit=\(request.computeUnit)")
                handleTask(request, on: connection)
            } catch {
                appendLog("[DEBUG] Protobuf parse FAILED: \(error)")
            }
        }
    }

    // Executes the requested op. Currently CPU-only via Accelerate;
    // GPU/ANE requests are rejected with a clear error until Metal/CoreML land.
    private func handleTask(_ request: Usbaccel_TaskRequest, on connection: NWConnection) {
        var response = Usbaccel_TaskResponse()
        response.taskID = request.taskID
        response.computeUnitUsed = .cpu

        if request.computeUnit != .cpu {
            response.success = false
            response.errorMessage = "Compute unit \(request.computeUnit) not implemented yet — CPU only for now"
            sendMessage(response, on: connection)
            return
        }

        let a = request.inputA
        let b = request.inputB
        let scalar = request.scalar
        let scalarB = request.scalarB

        switch request.op {
        case .add:
            guard a.count == b.count, !a.isEmpty else { return fail(&response, "ADD requires input_a and input_b of equal, nonzero length", on: connection) }
            var out = [Float](repeating: 0, count: a.count)
            vDSP_vadd(a, 1, b, 1, &out, 1, vDSP_Length(a.count))
            response.success = true; response.outputFloats = out

        case .subtract:
            guard a.count == b.count, !a.isEmpty else { return fail(&response, "SUBTRACT requires equal-length input_a/input_b", on: connection) }
            var out = [Float](repeating: 0, count: a.count)
            vDSP_vsub(b, 1, a, 1, &out, 1, vDSP_Length(a.count)) // vDSP_vsub computes a - b as (B, A) order
            response.success = true; response.outputFloats = out

        case .multiply:
            guard a.count == b.count, !a.isEmpty else { return fail(&response, "MULTIPLY requires equal-length input_a/input_b", on: connection) }
            var out = [Float](repeating: 0, count: a.count)
            vDSP_vmul(a, 1, b, 1, &out, 1, vDSP_Length(a.count))
            response.success = true; response.outputFloats = out

        case .divide:
            guard a.count == b.count, !a.isEmpty else { return fail(&response, "DIVIDE requires equal-length input_a/input_b", on: connection) }
            var out = [Float](repeating: 0, count: a.count)
            vDSP_vdiv(b, 1, a, 1, &out, 1, vDSP_Length(a.count)) // vDSP_vdiv computes a/b as (B, A) order
            response.success = true; response.outputFloats = out

        case .scale:
            guard !a.isEmpty else { return fail(&response, "SCALE requires nonzero input_a", on: connection) }
            var s = scalar
            var out = [Float](repeating: 0, count: a.count)
            vDSP_vsmul(a, 1, &s, &out, 1, vDSP_Length(a.count))
            response.success = true; response.outputFloats = out

        case .offset:
            guard !a.isEmpty else { return fail(&response, "OFFSET requires nonzero input_a", on: connection) }
            var s = scalar
            var out = [Float](repeating: 0, count: a.count)
            vDSP_vsadd(a, 1, &s, &out, 1, vDSP_Length(a.count))
            response.success = true; response.outputFloats = out

        case .dotProduct:
            guard a.count == b.count, !a.isEmpty else { return fail(&response, "DOT_PRODUCT requires equal-length input_a/input_b", on: connection) }
            var result: Float = 0
            vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
            response.success = true; response.outputFloats = [result]

        case .sum:
            guard !a.isEmpty else { return fail(&response, "SUM requires nonzero input_a", on: connection) }
            var result: Float = 0
            vDSP_sve(a, 1, &result, vDSP_Length(a.count))
            response.success = true; response.outputFloats = [result]

        case .mean:
            guard !a.isEmpty else { return fail(&response, "MEAN requires nonzero input_a", on: connection) }
            var result: Float = 0
            vDSP_meanv(a, 1, &result, vDSP_Length(a.count))
            response.success = true; response.outputFloats = [result]

        case .min:
            guard !a.isEmpty else { return fail(&response, "MIN requires nonzero input_a", on: connection) }
            var result: Float = 0
            vDSP_minv(a, 1, &result, vDSP_Length(a.count))
            response.success = true; response.outputFloats = [result]

        case .max:
            guard !a.isEmpty else { return fail(&response, "MAX requires nonzero input_a", on: connection) }
            var result: Float = 0
            vDSP_maxv(a, 1, &result, vDSP_Length(a.count))
            response.success = true; response.outputFloats = [result]

        case .abs:
            guard !a.isEmpty else { return fail(&response, "ABS requires nonzero input_a", on: connection) }
            var out = [Float](repeating: 0, count: a.count)
            vDSP_vabs(a, 1, &out, 1, vDSP_Length(a.count))
            response.success = true; response.outputFloats = out

        case .sqrt:
            guard !a.isEmpty else { return fail(&response, "SQRT requires nonzero input_a", on: connection) }
            var out = [Float](repeating: 0, count: a.count)
            var count = Int32(a.count)
            vvsqrtf(&out, a, &count)
            response.success = true; response.outputFloats = out

        case .square:
            guard !a.isEmpty else { return fail(&response, "SQUARE requires nonzero input_a", on: connection) }
            var out = [Float](repeating: 0, count: a.count)
            vDSP_vsq(a, 1, &out, 1, vDSP_Length(a.count))
            response.success = true; response.outputFloats = out

        case .negate:
            guard !a.isEmpty else { return fail(&response, "NEGATE requires nonzero input_a", on: connection) }
            var out = [Float](repeating: 0, count: a.count)
            vDSP_vneg(a, 1, &out, 1, vDSP_Length(a.count))
            response.success = true; response.outputFloats = out

        case .clip:
            guard !a.isEmpty else { return fail(&response, "CLIP requires nonzero input_a", on: connection) }
            var lo = scalar, hi = scalarB
            var out = [Float](repeating: 0, count: a.count)
            vDSP_vclip(a, 1, &lo, &hi, &out, 1, vDSP_Length(a.count))
            response.success = true; response.outputFloats = out

        case .reciprocal, .cumulativeSum, .sortAscending, .sortDescending, .reverse, .normalize, .matrixMultiply:
            response.success = false
            response.errorMessage = "Op \(request.op) not implemented yet"

        case .unknownOp, .UNRECOGNIZED:
            response.success = false
            response.errorMessage = "Unknown or unrecognized op"
        }

        appendLog("[DEBUG] \(request.op) -> success=\(response.success) output=\(response.outputFloats)")
        sendMessage(response, on: connection)
    }

    private func fail(_ response: inout Usbaccel_TaskResponse, _ message: String, on connection: NWConnection) {
        response.success = false
        response.errorMessage = message
        appendLog("[DEBUG] Task failed: \(message)")
        sendMessage(response, on: connection)
    }

    private func sendMessage(_ message: SwiftProtobuf.Message, on connection: NWConnection) {
        do {
            let payload = try message.serializedData()
            var length = UInt32(payload.count).bigEndian
            var packet = Data(bytes: &length, count: 4)
            packet.append(payload)
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
