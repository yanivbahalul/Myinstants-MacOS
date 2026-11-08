import SwiftUI

@main
struct MyInstantsRemoteApp: App {
    @StateObject private var client = RemoteClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        Group {
            switch client.state {
            case .connected:
                MainView()
            case .connecting:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Connecting to \(client.mac?.name ?? "your Mac")…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
            case .disconnected:
                ConnectView()
            }
        }
        .task { await client.restore() }
        .task { await ButtonArt.shared.load() }
    }
}
