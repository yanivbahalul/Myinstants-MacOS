import SwiftUI

/// A myinstants button in the site's own look (same images and layout as the desktop app), with a
/// drawn fallback until those images have been downloaded.
struct OrbButton: View {
    enum Kind { case small, large }

    let color: Color
    var kind: Kind = .small
    var label: String = ""
    let action: () -> Void
    @ObservedObject private var art = ButtonArt.shared

    var body: some View {
        Group {
            if let sprite = (kind == .small ? art.small : art.large) {
                Button(action: action) { EmptyView() }
                    .buttonStyle(SpriteStyle(color: color, sprite: sprite))
                    .transition(.opacity)
            } else {
                // Same footprint as the real button, so nothing jumps when the images arrive.
                let layout = kind == .small ? ButtonArt.smallLayout : ButtonArt.largeLayout
                Button(action: action) { EmptyView() }
                    .buttonStyle(DrawnStyle(color: color, layout: layout))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: kind == .small ? art.small != nil : art.large != nil)
        .accessibilityLabel(label.isEmpty ? "Play" : "Play \(label)")
    }
}

/// Exactly how index.html stacks a button: the shadow image, then the colored disc, then the glossy
/// transparent sprite on top, which switches to its "pressed" frame while held.
private struct SpriteStyle: ButtonStyle {
    let color: Color
    let sprite: ButtonArt.Sprite

    func makeBody(configuration: Configuration) -> some View {
        let s = sprite.layout
        return ZStack(alignment: .topLeading) {
            Image(uiImage: sprite.shadow)
                .resizable()
                .interpolation(.high)
                .frame(width: s.width, height: s.height)
            Ellipse()
                .fill(color)
                .frame(width: s.disc.width, height: s.disc.height)
                .offset(x: s.disc.minX, y: s.disc.minY)
            Image(uiImage: configuration.isPressed ? sprite.pressed : sprite.normal)
                .resizable()
                .interpolation(.high)
                .frame(width: s.width, height: s.height)
        }
        .frame(width: s.width, height: s.height, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

/// Stand-in until the site's images are downloaded: the same colored disc in the same spot, with a
/// soft gloss and no dark rim (that rim was the black edge that flashed before the real art loaded).
private struct DrawnStyle: ButtonStyle {
    let color: Color
    let layout: ButtonArt.Layout

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let disc = layout.disc
        return ZStack(alignment: .topLeading) {
            Ellipse()
                .fill(color)
                .overlay(
                    Ellipse().fill(LinearGradient(colors: [.white.opacity(pressed ? 0.15 : 0.35), .clear, .black.opacity(0.2)],
                                                  startPoint: .top, endPoint: .bottom))
                )
                .frame(width: disc.width, height: disc.height)
                .shadow(color: .black.opacity(0.35), radius: pressed ? 1 : 3, y: pressed ? 1 : 3)
                .offset(x: disc.minX, y: disc.minY + (pressed ? 2 : 0))
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .contentShape(Rectangle())
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

    private let columns = [GridItem(.adaptive(minimum: 98, maximum: 130), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(sounds) { sound in
                SoundTile(sound: sound, isFavorite: isFavorites) { onUnfavorited?(sound) }
            }
        }
        .padding(.horizontal, 12)
    }
}
