import Foundation
import Network

/// Finds Macs running MyInstants with “Allow iPhone remote” on, over Bonjour (remote.js advertises
/// `_myinstants._tcp` with macOS's dns-sd).
@MainActor
final class MacBrowser: ObservableObject {
    nonisolated static let serviceType = "_myinstants._tcp"

    struct Found: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    @Published private(set) var found: [Found] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            // One Mac can show up once per network interface; keep one entry per name.
            var byName: [String: Found] = [:]
            for result in results {
                if let name = Self.serviceName(result.endpoint), byName[name] == nil {
                    byName[name] = Found(name: name, endpoint: result.endpoint)
                }
            }
            let list = byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor in self?.found = list }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    nonisolated static func serviceName(_ endpoint: NWEndpoint) -> String? {
        if case let .service(name, _, _, _) = endpoint { return name }
        return nil
    }

    /// Turns a Bonjour service into an IPv4 address and port by briefly connecting to it.
    nonisolated static func resolve(_ endpoint: NWEndpoint, timeout: Double = 8) async throws -> (host: String, port: Int) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint,
                       let address = Self.hostString(host) {
                        once.run { continuation.resume(returning: (host: address, port: Int(port.rawValue))) }
                    } else {
                        once.run { continuation.resume(throwing: RemoteError.server("Couldn't get the Mac's address.")) }
                    }
                    connection.cancel()
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                    connection.cancel()
                case .cancelled:
                    once.run { continuation.resume(throwing: RemoteError.server("The Mac didn't answer.")) }
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { connection.cancel() }
        }
    }

    /// Browses for up to `timeout` seconds for a Mac with this Bonjour name, then resolves it.
    nonisolated static func find(named name: String, timeout: Double = 4) async -> (host: String, port: Int)? {
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        let once = Once()
        let endpoint: NWEndpoint? = await withCheckedContinuation { continuation in
            browser.browseResultsChangedHandler = { results, _ in
                if let match = results.first(where: { Self.serviceName($0.endpoint) == name }) {
                    once.run { continuation.resume(returning: match.endpoint) }
                    browser.cancel()
                }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                once.run { continuation.resume(returning: nil) }
                browser.cancel()
            }
        }
        guard let endpoint else { return nil }
        return try? await resolve(endpoint)
    }

    nonisolated private static func hostString(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address):
            return address.rawValue.map { String($0) }.joined(separator: ".")
        case .name(let name, _):
            return name
        default:
            return nil
        }
    }
}

/// Runs its block at most once; every Network callback above lands on the main queue.
private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func run(_ block: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { block() }
    }
}
