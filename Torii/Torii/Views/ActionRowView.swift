import SwiftUI

struct ActionRowView: View {
    @EnvironmentObject var vm: TorViewModel

    var body: some View {
        HStack(spacing: 10) {
            // New Circuit
            Button {
                vm.requestNewCircuit()
            } label: {
                Group {
                    if vm.isRenewingCircuit {
                        HStack(spacing: 5) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                            Text("Building…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("New Circuit", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.status != .connected || vm.isRenewingCircuit)

            // Launch at login
            Button {
                vm.toggleLoginItem()
            } label: {
                Label(
                    vm.loginItemEnabled ? "At Login: On" : "At Login: Off",
                    systemImage: vm.loginItemEnabled ? "checkmark.circle.fill" : "circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
