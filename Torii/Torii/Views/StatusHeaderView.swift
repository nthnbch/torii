import SwiftUI

struct StatusHeaderView: View {
    @EnvironmentObject var vm: TorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Status dot
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: dotColor.opacity(0.6), radius: dotColor == .green ? 4 : 0)

                // Title: show flag + country when connected and exit node known
                if vm.status == .connected, let node = vm.exitNode {
                    Text(node.flagEmoji)
                        .font(.system(size: 15))
                    Text(node.countryName)
                        .font(.system(size: 15, weight: .semibold))
                } else {
                    Text(vm.status.rawValue)
                        .font(.system(size: 15, weight: .semibold))
                }

                Spacer()

                // Connect / Disconnect button
                if vm.status == .disconnected || vm.status == .error {
                    connectButton
                } else {
                    disconnectButton
                }
            }

            // Detail / bootstrap progress (hidden when cleanly connected)
            if vm.statusDetail != "Connected" {
                Text(vm.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // IP row — publicIP is always the source of truth (exit IP via SOCKS
            // when connected, real IP when not). Relay nickname shown when available.
            if let ip = vm.publicIP {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(ip)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let nickname = vm.exitNode?.nickname {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(nickname)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.top, 1)
            }

            // Error message
            if let err = vm.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.bottom, 8)
    }

    private var dotColor: Color {
        switch vm.status {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .disconnected: return .secondary
        case .error:        return .red
        }
    }

    private var connectButton: some View {
        Button("Connect") { vm.connect() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.accentColor)
    }

    private var disconnectButton: some View {
        Button("Disconnect") { vm.disconnect() }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}
