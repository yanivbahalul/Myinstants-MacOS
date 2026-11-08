import SwiftUI

struct CategoriesView: View {
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Category.all) { category in
                    NavigationLink(value: Feed.category(category)) {
                        VStack(spacing: 8) {
                            Image(systemName: category.symbol)
                                .font(.title2)
                                .foregroundStyle(Theme.accent)
                            Text(category.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 86)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("Categories")
    }
}

/// Searches as you type, like the desktop app (after a short pause).
struct SearchView: View {
    @State private var query = ""
    @State private var feed: Feed?

    var body: some View {
        Group {
            if let feed {
                SoundListView(feed: feed)
                    .id(feed.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Search the whole myinstants library")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Sound name")
        .onSubmit(of: .search) { apply() }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            apply()
        }
    }

    private func apply() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: Feed? = trimmed.isEmpty ? nil : .search(trimmed)
        if next != feed { feed = next }
    }
}

/// The Mac's myinstants.com account: favorites and uploads (sign in happens on the Mac).
struct AccountView: View {
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        List {
            if client.loggedIn {
                Section {
                    NavigationLink(value: Feed.favorites) {
                        Label("Favorites", systemImage: "heart.fill")
                    }
                    NavigationLink(value: Feed.uploaded) {
                        Label("Uploaded", systemImage: "arrow.up.circle.fill")
                    }
                } footer: {
                    Text("This is the myinstants.com account signed in on \(client.mac?.name ?? "your Mac").")
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Not signed in").font(.headline)
                        Text("Sign in to myinstants.com in the MyInstants app on your Mac to see your favorites and uploads here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Button("Check again") { Task { await client.refreshStatus() } }
                }
            }

            Section("Mac") {
                LabeledContent("Connected to", value: client.mac?.name ?? "—")
                if let mac = client.mac {
                    LabeledContent("Address", value: "\(mac.host):\(mac.port)")
                }
                Button("Disconnect", role: .destructive) { client.disconnect() }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Me")
        .task { await client.refreshStatus() }
    }
}
