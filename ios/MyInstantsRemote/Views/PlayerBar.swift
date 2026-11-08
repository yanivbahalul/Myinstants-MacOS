import SwiftUI

/// Bottom bar on every screen: what the Mac is playing, its volume, and Stop.
struct PlayerBar: View {
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        VStack(spacing: 6) {
            if let banner = client.banner {
                Text(banner)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            HStack(spacing: 12) {
                Image(systemName: client.nowPlaying == nil ? "desktopcomputer" : "speaker.wave.2.fill")
                    .foregroundStyle(client.nowPlaying == nil ? Color.secondary : Theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.nowPlaying ?? (client.mac?.name ?? "Mac"))
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Slider(value: Binding(get: { client.volume }, set: { client.setVolume($0) }), in: 0...1)
                        .accessibilityLabel("Volume on the Mac")
                }
                Button {
                    client.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.body.weight(.bold))
                        .frame(width: 40, height: 40)
                        .background(Color(hex: "#2c4a6b"), in: Circle())
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("Stop all")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: client.banner)
    }
}
