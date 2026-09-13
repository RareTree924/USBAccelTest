import SwiftUI

struct ContentView: View {
    @StateObject private var server = TCPServer()

    var body: some View {
        VStack(alignment: .leading) {
            Text("USB Accelerator Test — Phase 1")
                .font(.headline)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(server.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.footnote, design: .monospaced))
                    }
                }
            }
        }
        .padding()
        .onAppear { server.start() }   // starts listening as soon as the screen shows
    }
}
