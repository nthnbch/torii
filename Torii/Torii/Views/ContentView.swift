import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: TorViewModel

    var body: some View {
        VStack(spacing: 0) {
            StatusHeaderView()
            BandwidthView()
            Divider().padding(.vertical, 4)
            ActionRowView()
            Divider().padding(.vertical, 4)
            CountryPickerView()
            Divider().padding(.vertical, 4)
            FooterView()
        }
        .padding(14)
        .frame(width: 300)
        .background(.background)
    }
}
