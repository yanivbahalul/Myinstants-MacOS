import SwiftUI

/// The glossy round myinstants button, drawn natively so it looks sharp at any size.
struct OrbButton: View {
    let color: Color
    var size: CGFloat = 78
    var label: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(OrbStyle(color: color, size: size))
            .accessibilityLabel(label.isEmpty ? "Play" : "Play \(label)")
    }
}

private struct OrbStyle: ButtonStyle {
    let color: Color
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return ZStack {
            // dark rim / base
            Circle()
                .fill(Color.black.opacity(0.55))
            Circle()
                .fill(color)
                .padding(size * 0.06)
            // shading toward the bottom
            Circle()
                .fill(LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom))
                .padding(size * 0.06)
            // glossy highlight
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(pressed ? 0.35 : 0.7), .white.opacity(0.03)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.62, height: size * 0.38)
                .offset(y: -size * 0.2)
        }
        .frame(width: size, height: size)
        .brightness(pressed ? -0.1 : 0)
        .scaleEffect(pressed ? 0.92 : 1)
        .shadow(color: .black.opacity(0.55), radius: pressed ? 2 : 6, y: pressed ? 1 : 5)
        .animation(.easeOut(duration: 0.08), value: pressed)
        .contentShape(Circle())
    }
}

/// One sound in a grid: the button plays it on the Mac, the name opens its page.
struct SoundTile: View {
    let sound: Sound
    var isFavorite = false
    var onUnfavorited: (() -> Void)? = nil
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        VStack(spacing: 6) {
            OrbButton(color: Color(hex: sound.color), label: sound.name) {
                client.play(sound)
            }
            nameLabel
        }
        .frame(maxWidth: .infinity)
        .contextMenu {
            Button {
                client.play(sound)
            } label: {
                Label("Play on Mac", systemImage: "play.fill")
            }
            if sound.soundId != nil {
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    if isFavorite {
                        Label("Remove from favorites", systemImage: "heart.slash")
                    } else {
                        Label("Add to favorites", systemImage: "heart")
                    }
                }
            }
            if let page = sound.page, let url = URL(string: "https://www.myinstants.com" + page) {
                ShareLink(item: url) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    @ViewBuilder private var nameLabel: some View {
        let text = Text(sound.name)
            .font(.caption)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(height: 32, alignment: .top)
        if sound.page != nil {
            NavigationLink(value: sound) {
                text.foregroundStyle(.primary).underline()
            }
            .buttonStyle(.plain)
        } else {
            text
        }
    }

    private func toggleFavorite() async {
        do {
            try await client.setFavorite(sound, on: !isFavorite)
            client.showBanner(isFavorite ? "Removed from favorites" : "Added to favorites")
            if isFavorite { onUnfavorited?() }
        } catch {
            client.show(error)
        }
    }
}

struct SoundGrid: View {
    let sounds: [Sound]
    var isFavorites = false
    var onUnfavorited: ((Sound) -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(sounds) { sound in
                SoundTile(sound: sound, isFavorite: isFavorites) { onUnfavorited?(sound) }
            }
        }
        .padding(.horizontal, 12)
    }
}
