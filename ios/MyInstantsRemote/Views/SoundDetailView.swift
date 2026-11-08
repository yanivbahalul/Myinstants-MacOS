import SwiftUI

/// A sound's own page: big button, counts, uploader and "You might also like".
struct SoundDetailView: View {
    let sound: Sound
    @EnvironmentObject private var client: RemoteClient
    @State private var detail: SoundDetail?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text(detail?.name ?? sound.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                OrbButton(color: Color(hex: detail?.color ?? sound.color), size: 180, label: sound.name) {
                    client.play(detail?.url ?? sound.url, name: detail?.name ?? sound.name)
                }
                .padding(.vertical, 6)

                if let detail {
                    VStack(spacing: 6) {
                        if let favorites = detail.favorites {
                            Text("**\(favorites)** users favorited this sound")
                        }
                        if let uploader = detail.uploader {
                            HStack(spacing: 4) {
                                Text("Uploaded by")
                                NavigationLink(value: Feed.profile(uploader)) {
                                    Text(uploader.name).underline()
                                }
                                if let views = detail.views {
                                    Text("· \(views) views")
                                }
                            }
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        if sound.soundId != nil {
                            Button {
                                Task {
                                    do {
                                        try await client.setFavorite(sound, on: true)
                                        client.showBanner("Added to favorites")
                                    } catch {
                                        client.show(error)
                                    }
                                }
                            } label: {
                                Label("Favorite", systemImage: "heart")
                            }
                        }
                        if let page = sound.page, let url = URL(string: "https://www.myinstants.com" + page) {
                            ShareLink(item: url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .buttonStyle(.bordered)

                    if !detail.related.isEmpty {
                        Text("You might also like")
                            .font(.headline)
                            .padding(.top, 16)
                        SoundGrid(sounds: detail.related)
                    }
                } else if let error {
                    VStack(spacing: 10) {
                        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try again") { Task { await load() } }.buttonStyle(.bordered)
                    }
                    .padding()
                } else {
                    ProgressView().padding()
                }
            }
            .padding(.vertical, 20)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { if detail == nil { await load() } }
    }

    private func load() async {
        guard let page = sound.page else {
            error = "This sound has no page."
            return
        }
        error = nil
        do {
            detail = try await client.detail(page)
        } catch is CancellationError {
        } catch {
            self.error = "Couldn't load this sound: \(error.localizedDescription)"
        }
    }
}
