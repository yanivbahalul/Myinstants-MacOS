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
    @Environment(\.scenePhase) private var scenePhase

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
        .background(Theme.background.ignoresSafeArea())
        .task { await client.restore() }
        .task { await ButtonArt.shared.load() }
        .onChange(of: scenePhase) { phase in
            // Back from the background: make sure the Mac is still there straight away.
            if phase == .active { Task { await client.checkHealth() } }
        }
    }
}
