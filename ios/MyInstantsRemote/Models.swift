import SwiftUI

/// One sound button, as the Mac app's `toTile` sends it.
struct Sound: Identifiable, Decodable, Hashable {
    let name: String
    /// The MP3 on myinstants.com; this is what the Mac is asked to play.
    let url: String
    /// The sound's own page on myinstants.com (`/en/instant/...`), if the list had one.
    let page: String?
    let color: String?
    /// myinstants.com's numeric id, needed to favorite it.
    let soundId: String?

    var id: String { url }

    enum CodingKeys: String, CodingKey {
        case name, url, page, color
        case soundId = "id"
    }
}

struct Pager: Decodable, Hashable {
    let last: Int
    let hasNext: Bool
}

struct SoundPage: Decodable {
    let sounds: [Sound]
    let pager: Pager?
}

struct Uploader: Decodable, Hashable {
    let name: String
    let path: String
}

/// A sound's own page: big button, counts, uploader and related sounds.
struct SoundDetail: Decodable {
    let name: String
    let favorites: String?
    let views: String?
    let uploader: Uploader?
    let color: String?
    let url: String?
    let related: [Sound]
}

struct Hello: Decodable {
    let name: String
    let version: String
    let loggedIn: Bool
    let volume: Double?
}

struct OK: Decodable {
    let ok: Bool
}

struct ErrorBody: Decodable {
    let error: String
}

/// A list of sounds the Mac can load: a page path on myinstants.com plus how to title it.
struct Feed: Hashable, Identifiable {
    let key: String
    let title: String
    let path: String
    var empty: String = "No sounds here."

    var id: String { key }
    var isFavorites: Bool { key == "favs" }

    static let trending = Feed(key: "home", title: "Trending", path: "/en/index/il/")
    static let recent = Feed(key: "recent", title: "Just added", path: "/en/recent/")
    static let favorites = Feed(key: "favs", title: "Favorites", path: "/en/favorites/",
                                empty: "You haven't favorited anything yet.")
    static let uploaded = Feed(key: "uploaded", title: "Uploaded", path: "/en/uploaded/",
                               empty: "You haven't uploaded any sounds yet.")

    static func search(_ query: String) -> Feed {
        Feed(key: "search:\(query)", title: "“\(query)”",
             path: "/en/search/?name=\(uriEncode(query))",
             empty: "No sounds found for “\(query)”.")
    }

    static func category(_ category: Category) -> Feed {
        Feed(key: "cat:\(category.slug)", title: category.name,
             path: "/en/categories/\(uriEncode(category.slug))/")
    }

    static func profile(_ uploader: Uploader) -> Feed {
        Feed(key: "profile:\(uploader.path)", title: uploader.name, path: uploader.path,
             empty: "This profile has no sounds.")
    }
}

struct Category: Identifiable, Hashable {
    let name: String
    let slug: String
    let symbol: String
    var id: String { slug }

    // Same list as the desktop app's CATEGORIES (index.html).
    static let all: [Category] = [
        Category(name: "Anime & Manga", slug: "anime & manga", symbol: "sparkles.tv"),
        Category(name: "Games", slug: "games", symbol: "gamecontroller"),
        Category(name: "Memes", slug: "memes", symbol: "face.smiling"),
        Category(name: "Movies", slug: "movies", symbol: "film"),
        Category(name: "Music", slug: "music", symbol: "music.note"),
        Category(name: "Politics", slug: "politics", symbol: "building.columns"),
        Category(name: "Pranks", slug: "pranks", symbol: "theatermasks"),
        Category(name: "Reactions", slug: "reactions", symbol: "hand.thumbsup"),
        Category(name: "Sound Effects", slug: "sound effects", symbol: "waveform"),
        Category(name: "Sports", slug: "sports", symbol: "sportscourt"),
        Category(name: "Television", slug: "television", symbol: "tv"),
        Category(name: "Tiktok Trends", slug: "tiktok trends", symbol: "chart.line.uptrend.xyaxis"),
        Category(name: "Viral", slug: "viral", symbol: "flame"),
        Category(name: "Whatsapp Audios", slug: "whatsapp audios", symbol: "bubble.left.and.bubble.right"),
    ]
}

/// JavaScript's encodeURIComponent, so paths match what the desktop app builds.
func uriEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-_.!~*'()")
    // alphanumerics includes non-ASCII letters; restrict to ASCII so Hebrew etc. get encoded.
    let ascii = CharacterSet(charactersIn: Unicode.Scalar(0x21)!...Unicode.Scalar(0x7E)!)
    return s.addingPercentEncoding(withAllowedCharacters: allowed.intersection(ascii)) ?? s
}

extension Color {
    /// `#rgb`, `#rrggbb` or `#rrggbbaa`, as myinstants.com writes its button colors.
    init(hex: String?, fallback: Color = Color(red: 1, green: 0, blue: 0)) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces) else { self = fallback; return }
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { self = fallback; return }
        let hasAlpha = h.count == 8
        let r = Double((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(v & 0xFF) / 255 : 1
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

enum Theme {
    static let background = Color(hex: "#15202b")
    static let card = Color(hex: "#1e2732")
    static let accent = Color(hex: "#6ea0d6")
}
