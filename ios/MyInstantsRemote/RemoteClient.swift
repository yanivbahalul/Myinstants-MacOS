import SwiftUI
import UIKit

enum RemoteError: LocalizedError {
    case badPin
    case locked
    case notConnected
    case invalidAddress
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badPin: return "Wrong PIN. Check the PIN in the 📱 menu of MyInstants on your Mac."
        case .locked: return "Too many wrong PINs. Wait a few minutes and try again."
        case .notConnected: return "Not connected to a Mac."
        case .invalidAddress: return "That address doesn't look right."
        case .server(let message): return message
        }
    }
}

/// Talks to the MyInstants app on the Mac (remote.js). The phone only browses and sends commands;
/// every sound plays on the Mac.
@MainActor
final class RemoteClient: ObservableObject {
    enum State: Equatable { case disconnected, connecting, connected }

    struct Mac: Codable, Equatable {
        var name: String
        var host: String
        var port: Int
        var pin: String
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var mac: Mac?
    @Published private(set) var loggedIn = false
    @Published private(set) var volume: Double = 1
    @Published private(set) var nowPlaying: String?
    @Published var connectError: String?
    /// False while the paired Mac isn't answering (the health check keeps trying).
    @Published private(set) var reachable = true
    @Published var banner: String?

    private static let storeKey = "pairedMac"
    private let session: URLSession
    private var volumeTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private let haptics = UIImpactFeedbackGenerator(style: .medium)

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode(Mac.self, from: data) {
            mac = saved
        }
    }

    // MARK: Pairing

    /// On launch: reconnect to the Mac paired last time. Its address can change (DHCP), so if the
    /// saved one doesn't answer, look the Mac up again by its Bonjour name.
    func restore() async {
        guard let saved = mac, state == .disconnected else { return }
        state = .connecting
        do {
            try await handshake(saved)
            return
        } catch RemoteError.badPin {
            fail("The PIN changed on \(saved.name). Enter the new one.")
            return
        } catch {}
        if let found = await MacBrowser.find(named: saved.name) {
            var moved = saved
            moved.host = found.host
            moved.port = found.port
            do {
                try await handshake(moved)
                return
            } catch {
                fail(error.localizedDescription)
                return
            }
        }
        fail("Couldn't reach \(saved.name). Make sure MyInstants is open there and “Allow iPhone remote” is on.")
    }

    func pair(name: String, host: String, port: Int, pin: String) async {
        // No .connecting state here: the PIN sheet shows its own spinner and stays up on failure.
        connectError = nil
        do {
            try await handshake(Mac(name: name, host: host, port: port,
                                    pin: pin.trimmingCharacters(in: .whitespaces)))
        } catch {
            fail(error.localizedDescription)
        }
    }

    func disconnect() {
        stopHealthChecks()
        state = .disconnected
        nowPlaying = nil
        mac = nil
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
    }

    var savedPin: String { mac?.pin ?? "" }

    private func fail(_ message: String) {
        stopHealthChecks()
        state = .disconnected
        connectError = message
    }

    private func handshake(_ candidate: Mac) async throws {
        let hello: Hello = try await request(candidate, "GET", "/api/hello", timeout: 6)
        mac = Mac(name: hello.name, host: candidate.host, port: candidate.port, pin: candidate.pin)
        saveMac()
        loggedIn = hello.loggedIn
        if let v = hello.volume { volume = v }
        connectError = nil
        reachable = true
        state = .connected
        startHealthChecks()
    }

    private func saveMac() {
        if let mac, let data = try? JSONEncoder().encode(mac) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    // MARK: Health check

    /// While connected, checks every few seconds that the Mac still answers. If it doesn't, finds it
    /// again over Bonjour (new IP or port after a restart) and carries on without re-pairing.
    private func startHealthChecks() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.checkHealth()
            }
        }
    }

    private func stopHealthChecks() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    /// Also called when the app comes back to the foreground.
    func checkHealth() async {
        guard state == .connected, let current = mac else { return }
        do {
            let hello: Hello = try await request(current, "GET", "/api/hello", timeout: 4)
            loggedIn = hello.loggedIn
            setReachable(true)
        } catch RemoteError.badPin {
            fail("The PIN changed on \(current.name). Enter the new one.")
        } catch {
            setReachable(await relocate())
        }
    }

    private func setReachable(_ ok: Bool) {
        guard ok != reachable else { return }
        reachable = ok
        if ok { showBanner("Reconnected to \(mac?.name ?? "the Mac")") }
    }

    /// Looks the paired Mac up again by its Bonjour name. True if it was found and answers.
    private func relocate() async -> Bool {
        guard let current = mac, let found = await MacBrowser.find(named: current.name, timeout: 3) else {
            return false
        }
        var moved = current
        moved.host = found.host
        moved.port = found.port
        guard let hello: Hello = try? await request(moved, "GET", "/api/hello", timeout: 4) else { return false }
        guard state == .connected else { return false }
        mac = moved
        saveMac()
        loggedIn = hello.loggedIn
        return true
    }

    private static func isUnreachable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet]
            .contains(error.code)
    }

    /// Re-reads whether the Mac is signed in to myinstants.com (it may have just signed in there).
    func refreshStatus() async {
        if let hello: Hello = try? await call("GET", "/api/hello") {
            loggedIn = hello.loggedIn
            if let v = hello.volume { volume = v }
        }
    }

    // MARK: Browsing

    func sounds(_ feed: Feed, page: Int) async throws -> SoundPage {
        try await call("GET", "/api/sounds", query: ["path": feed.path, "page": String(page)])
    }

    func detail(_ page: String) async throws -> SoundDetail {
        try await call("GET", "/api/instant", query: ["page": page])
    }

    func setFavorite(_ sound: Sound, on: Bool) async throws {
        guard let id = sound.soundId else { throw RemoteError.server("This sound can't be favorited.") }
        let _: OK = try await call("POST", "/api/favorite", body: ["id": id, "on": on])
    }

    // MARK: Playback (on the Mac)

    func play(_ url: String, name: String) {
        haptics.impactOccurred()
        nowPlaying = name
        Task {
            do {
                let _: OK = try await call("POST", "/api/play", body: ["url": url, "name": name], timeout: 8)
            } catch {
                show(error)
            }
        }
    }

    func play(_ sound: Sound) { play(sound.url, name: sound.name) }

    func stop() {
        nowPlaying = nil
        Task {
            do {
                let _: OK = try await call("POST", "/api/stop", timeout: 8)
            } catch {
                show(error)
            }
        }
    }

    /// Follows the slider live, but only sends the latest value once it settles for a moment.
    func setVolume(_ value: Double) {
        volume = value
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let _: OK? = try? await call("POST", "/api/volume", body: ["volume": value], timeout: 8)
        }
    }

    func show(_ error: Error) {
        if Self.isUnreachable(error) {
            showBanner("Can't reach \(mac?.name ?? "the Mac"). Is MyInstants open there?")
        } else {
            showBanner(error.localizedDescription)
        }
    }

    func showBanner(_ message: String) {
        banner = message
        bannerTask?.cancel()
        bannerTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            banner = nil
        }
    }

    // MARK: HTTP

    private func call<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                    body: [String: Any]? = nil, timeout: TimeInterval = 90) async throws -> T {
        guard let current = mac, state == .connected else { throw RemoteError.notConnected }
        do {
            return try await request(current, method, path, query: query, body: body, timeout: timeout)
        } catch let error where Self.isUnreachable(error) {
            // The Mac may have a new address; find it again and retry once.
            guard await relocate(), let moved = mac else {
                setReachable(false)
                throw error
            }
            setReachable(true)
            return try await request(moved, method, path, query: query, body: body, timeout: timeout)
        }
    }

    private func request<T: Decodable>(_ mac: Mac, _ method: String, _ path: String,
                                       query: [String: String] = [:], body: [String: Any]? = nil,
                                       timeout: TimeInterval = 90) async throws -> T {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = mac.host
        comps.port = mac.port
        comps.path = path
        if !query.isEmpty {
            comps.percentEncodedQuery = query
                .map { "\(uriEncode($0.key))=\(uriEncode($0.value))" }
                .joined(separator: "&")
        }
        guard let url = comps.url else { throw RemoteError.invalidAddress }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(mac.pin, forHTTPHeaderField: "X-Pin")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return try JSONDecoder().decode(T.self, from: data)
        case 401:
            throw RemoteError.badPin
        case 429:
            throw RemoteError.locked
        default:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "The Mac answered \(status)."
            throw RemoteError.server(message.prefix(1).uppercased() + message.dropFirst())
        }
    }
}
