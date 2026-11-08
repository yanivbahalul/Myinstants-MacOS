import SwiftUI

/// A grid of sounds loaded through the Mac, page by page as you scroll.
struct SoundListView: View {
    let feed: Feed
    @EnvironmentObject private var client: RemoteClient
    @State private var sounds: [Sound] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?

    /// What myinstants.com serves per page on its endless lists (same as the desktop app).
    private let pageSize = 36

    var body: some View {
        ScrollView {
            SoundGrid(sounds: sounds, isFavorites: feed.isFavorites) { removed in
                sounds.removeAll { $0.id == removed.id }
            }
            .padding(.top, 12)
            footer
                .padding(.vertical, 24)
        }
        .navigationTitle(feed.title)
        .refreshable { await reload() }
        .task(id: feed) {
            if sounds.isEmpty { await reload() }
        }
    }

    @ViewBuilder private var footer: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else if let error {
            VStack(spacing: 10) {
                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await loadMore() } }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)
        } else if sounds.isEmpty && page > 0 {
            Text(feed.empty)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        } else if hasMore && page > 0 {
            // Reaching the bottom loads the next page.
            Color.clear
                .frame(height: 1)
                .onAppear { Task { await loadMore() } }
        }
    }

    private func reload() async {
        sounds = []
        page = 0
        hasMore = true
        error = nil
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let next = page + 1
            let result = try await client.sounds(feed, page: next)
            let known = Set(sounds.map(\.id))
            sounds.append(contentsOf: result.sounds.filter { !known.contains($0.id) })
            page = next
            hasMore = !result.sounds.isEmpty && (result.pager?.hasNext ?? (result.sounds.count >= pageSize))
        } catch is CancellationError {
            // The view went away mid-load; nothing to show.
        } catch {
            self.error = "Couldn't load sounds: \(error.localizedDescription)"
        }
    }
}
