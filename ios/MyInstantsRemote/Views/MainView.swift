import SwiftUI

struct MainView: View {
    var body: some View {
        TabView {
            FeedTab(feed: .trending, label: "Trending", symbol: "flame.fill")
            FeedTab(feed: .recent, label: "Just added", symbol: "sparkles")

            NavigationStack {
                CategoriesView().remoteChrome()
            }
            .tabItem { Label("Categories", systemImage: "square.grid.2x2.fill") }

            NavigationStack {
                SearchView().remoteChrome()
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack {
                AccountView().remoteChrome()
            }
            .tabItem { Label("Me", systemImage: "person.crop.circle") }
        }
    }

    private struct FeedTab: View {
        let feed: Feed
        let label: String
        let symbol: String

        var body: some View {
            NavigationStack {
                SoundListView(feed: feed).remoteChrome()
            }
            .tabItem { Label(label, systemImage: symbol) }
        }
    }
}

extension View {
    /// What every screen shares: dark background, the player bar (volume + stop on the Mac),
    /// the Mac menu, and where sound/profile links lead.
    func remoteChrome() -> some View {
        modifier(RemoteChrome())
    }
}

extension View {
    /// Background and player bar, for screens pushed onto a tab's stack.
    func screenChrome() -> some View {
        background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { PlayerBar() }
            .toolbarBackground(Theme.card, for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
    }
}

private struct RemoteChrome: ViewModifier {
    @EnvironmentObject private var client: RemoteClient

    func body(content: Content) -> some View {
        content
            .screenChrome()
            .navigationDestination(for: Sound.self) { SoundDetailView(sound: $0).screenChrome() }
            .navigationDestination(for: Feed.self) { SoundListView(feed: $0).screenChrome() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Section("Connected to \(client.mac?.name ?? "Mac")") {
                            Button {
                                Task { await client.refreshStatus() }
                            } label: {
                                Label("Refresh account status", systemImage: "arrow.clockwise")
                            }
                            Button(role: .destructive) {
                                client.disconnect()
                            } label: {
                                Label("Disconnect", systemImage: "xmark.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "desktopcomputer")
                    }
                }
            }
    }
}
