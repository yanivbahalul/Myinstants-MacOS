import SwiftUI
import Network

/// Pick the Mac (found automatically, or typed in) and enter the PIN shown in its 📱 menu.
struct ConnectView: View {
    @EnvironmentObject private var client: RemoteClient
    @StateObject private var browser = MacBrowser()
    @State private var target: PairTarget?
    @State private var manualHost = ""
    @State private var manualPort = "47800"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "hifispeaker.and.homepod.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.red)
                        Text("Play myinstants sounds on your Mac")
                            .font(.headline)
                        Text("Open MyInstants on the Mac, click 📱 and turn on “Allow iPhone remote”. Both devices need to be on the same Wi-Fi.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                if let error = client.connectError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Macs on this network") {
                    if browser.found.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for MyInstants…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(browser.found) { mac in
                        Button {
                            target = .bonjour(mac)
                        } label: {
                            Label(mac.name, systemImage: "desktopcomputer")
                        }
                    }
                }

                Section {
                    TextField("IP address, e.g. 192.168.1.20", text: $manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $manualPort)
                        .keyboardType(.numberPad)
                    Button("Continue") {
                        target = .manual(host: manualHost.trimmingCharacters(in: .whitespaces),
                                         port: Int(manualPort) ?? 47800)
                    }
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Or enter the address")
                } footer: {
                    Text("The address is shown in the Mac app's 📱 menu.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("MyInstants Remote")
            .sheet(item: $target) { target in
                PinSheet(target: target)
                    .presentationDetents([.medium])
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }
}

enum PairTarget: Identifiable {
    case bonjour(MacBrowser.Found)
    case manual(host: String, port: Int)

    var id: String {
        switch self {
        case .bonjour(let mac): return "b:" + mac.name
        case .manual(let host, let port): return "m:\(host):\(port)"
        }
    }

    var title: String {
        switch self {
        case .bonjour(let mac): return mac.name
        case .manual(let host, _): return host
        }
    }
}

private struct PinSheet: View {
    let target: PairTarget
    @EnvironmentObject private var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("Enter the PIN shown on \(target.title)")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                TextField("000000", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .padding(.vertical, 10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                Button {
                    Task { await connect() }
                } label: {
                    Group {
                        if working { ProgressView() } else { Text("Connect").bold() }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pin.count < 6 || working)
                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            pin = client.savedPin
            focused = true
        }
    }

    private func connect() async {
        working = true
        error = nil
        defer { working = false }
        let host: String
        let port: Int
        let name: String
        switch target {
        case .bonjour(let mac):
            do {
                let resolved = try await MacBrowser.resolve(mac.endpoint)
                host = resolved.host
                port = resolved.port
                name = mac.name
            } catch {
                self.error = "Couldn't reach \(mac.name). Is it on the same Wi-Fi?"
                return
            }
        case .manual(let h, let p):
            host = h
            port = p
            name = h
        }
        await client.pair(name: name, host: host, port: port, pin: pin)
        if client.state == .connected {
            dismiss()
        } else {
            error = client.connectError
        }
    }
}
