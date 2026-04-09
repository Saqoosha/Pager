import SwiftUI

struct ContentView: View {
    @AppStorage("workerUrl") private var workerUrl = ""
    @AppStorage("sharedSecret") private var sharedSecret = ""
    @AppStorage("deviceToken") private var deviceToken = ""
    @StateObject private var network = NetworkService.shared
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
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
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    SecureField("Shared Secret", text: $sharedSecret)
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
                }

                Section {
                    Button("Send Test Notification") {
                        Task {
                            let ok = await network.sendTestNotification()
                            testResult = ok ? "Sent!" : "Failed"
                        }
                    }
                    .disabled(!network.isRegistered)

                    if let result = testResult {
                        Text(result)
                            .foregroundStyle(result == "Sent!" ? .green : .red)
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
            .navigationTitle("Canopy Companion")
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceTokenReceived)) { _ in
            // Token updated, UI will refresh via @AppStorage
        }
    }
}
