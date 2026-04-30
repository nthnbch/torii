import SwiftUI

struct CountryPickerView: View {
    @EnvironmentObject var vm: TorViewModel

    private let countries: [ExitCountry] = [.any] + ExitCountry.commonCountries

    var body: some View {
        HStack {
            Label("Exit Country", systemImage: "globe")
                .foregroundStyle(.secondary)
                .font(.caption)

            Spacer()

            Picker("", selection: $vm.preferredCountry) {
                ForEach(countries) { country in
                    Text(country.id.isEmpty
                         ? "Any"
                         : "\(country.flag) \(country.name)")
                        .tag(country)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            .onChange(of: vm.preferredCountry) { newValue in
                vm.setExitCountry(newValue)
            }
        }
    }
}
