import SwiftUI

@main
struct ToriiApp: App {
    @StateObject private var viewModel = TorViewModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(viewModel)
        } label: {
            MenuBarIconView(status: viewModel.status)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIconView: View {
    let status: TorConnectionStatus

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.palette)
            .foregroundStyle(dotColor, .primary)
    }

    private var iconName: String {
        switch status {
        case .connected:    return "shield.lefthalf.filled"
        case .connecting:   return "shield.lefthalf.filled"
        case .disconnected: return "shield.slash"
        case .error:        return "shield.slash"
        }
    }

    private var dotColor: Color {
        switch status {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .disconnected: return .secondary
        case .error:        return .red
        }
    }
}
