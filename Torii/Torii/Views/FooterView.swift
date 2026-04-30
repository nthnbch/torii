import SwiftUI

struct FooterView: View {
    @EnvironmentObject var vm: TorViewModel
    @State private var copied = false

    private let socksAddress = "127.0.0.1:\(TorManager.socksPort)"

    var body: some View {
        VStack(spacing: 8) {
            // SOCKS proxy address (copyable)
            HStack(spacing: 6) {
                Label(socksAddress, systemImage: "network")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(socksAddress, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? .green : .secondary)
                .help("Copy SOCKS address")
            }

            // Torii version
            HStack {
                Text("Torii 0.1.2")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            // Tor version + update status
            HStack {
                Text("Tor \(vm.torVersion)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let latest = vm.updateAvailable {
                    Spacer()
                    Button("Update → \(latest)") {
                        NSWorkspace.shared.open(
                            URL(string: "https://www.torproject.org/download/tor/")!
                        )
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .buttonStyle(.plain)
                } else {
                    Text("· up to date")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }

                Spacer()

                // Quit button
                Button("Quit") {
                    vm.disconnect()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
