import SwiftUI

struct ContentView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            HistoryListView()
                .navigationDestination(for: HistoryRoute.self) { route in
                    switch route {
                    case .detail(let id):
                        HistoryDetailView(id: id)
                    case .settings:
                        SettingsView()
                    }
                }
        }
        .onChange(of: appState.pendingDetailId) { _, newValue in
            guard let id = newValue else { return }
            navPath = NavigationPath()
            navPath.append(HistoryRoute.detail(id))
            appState.pendingDetailId = nil
        }
    }
}

private struct SettingsView: View {
    @AppStorage("workerUrl") private var workerUrl = ""
    @AppStorage("deviceToken") private var deviceToken = ""
    @ObservedObject private var network = NetworkService.shared
    @State private var sharedSecret = Self.loadOrMigrateSecret()
    @State private var testResult: String?

    /// Migrate sharedSecret from UserDefaults to Keychain on first launch after update
    private static func loadOrMigrateSecret() -> String {
        if let existing = KeychainHelper.load(key: "sharedSecret") {
            return existing
        }
        if let legacy = UserDefaults.standard.string(forKey: "sharedSecret"), !legacy.isEmpty {
            KeychainHelper.save(key: "sharedSecret", value: legacy)
            UserDefaults.standard.removeObject(forKey: "sharedSecret")
            return legacy
        }
        return ""
    }

    var body: some View {
        Form {
            Section("Device Token") {
                if deviceToken.isEmpty {
                    Text("Waiting for APNs token...")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text(deviceToken)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                        Spacer()
                        Button("Copy") {
                            UIPasteboard.general.string = deviceToken
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Section("Worker Configuration") {
                TextField("Worker URL", text: $workerUrl)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                SecureField("Shared Secret", text: $sharedSecret)
                    .onChange(of: sharedSecret) { _, newValue in
                        if newValue.isEmpty {
                            KeychainHelper.delete(key: "sharedSecret")
                        } else {
                            KeychainHelper.save(key: "sharedSecret", value: newValue)
                        }
                    }
            }

            Section {
                Button("Register Device") {
                    Task { await network.registerDevice() }
                }
                .disabled(deviceToken.isEmpty || workerUrl.isEmpty || sharedSecret.isEmpty)

                if network.isRegistered {
                    Label("Registered", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                if let error = network.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section {
                Button("Send Test Notification") {
                    Task {
                        testResult = await network.sendTestNotification()
                    }
                }
                .disabled(!network.isRegistered)

                if let result = testResult {
                    Text(result)
                        .foregroundStyle(result == "Sent!" ? .green : .red)
                        .font(.caption)
                }
            }

            Section("How to Use") {
                Text("""
                1. Deploy the Cloudflare Worker
                2. Enter the Worker URL and shared secret above
                3. Tap "Register Device"
                4. Configure the hook in Claude Code settings
                5. Permission requests will appear as notifications with Allow/Deny buttons
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .deviceTokenReceived)) { _ in
            // Token updated, UI will refresh via @AppStorage
        }
    }
}
