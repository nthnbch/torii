import SwiftUI

struct BandwidthView: View {
    @EnvironmentObject var vm: TorViewModel

    var body: some View {
        HStack(spacing: 0) {
            bandwidthItem(
                arrow: "arrow.down.circle.fill",
                color: .blue,
                label: "Download",
                value: BandwidthSample.formatted(vm.downloadSpeed)
            )
            Divider().frame(height: 28)
            bandwidthItem(
                arrow: "arrow.up.circle.fill",
                color: .orange,
                label: "Upload",
                value: BandwidthSample.formatted(vm.uploadSpeed)
            )
        }
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .opacity(vm.status == .connected ? 1 : 0.4)
    }

    private func bandwidthItem(arrow: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: arrow)
                .foregroundStyle(color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
