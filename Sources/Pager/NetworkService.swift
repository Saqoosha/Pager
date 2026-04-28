import Foundation

@MainActor
final class NetworkService: ObservableObject {
    static let shared = NetworkService()

    @Published var isRegistered = false
    @Published var lastError: String?

    private var workerUrl: String {
        (UserDefaults.standard.string(forKey: "workerUrl") ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var sharedSecret: String {
        if let secret = KeychainHelper.load(key: "sharedSecret") {
            return secret
        }
        // Fallback: migrate from UserDefaults if Keychain is empty
        if let legacy = UserDefaults.standard.string(forKey: "sharedSecret"), !legacy.isEmpty {
            KeychainHelper.save(key: "sharedSecret", value: legacy)
            UserDefaults.standard.removeObject(forKey: "sharedSecret")
            return legacy
        }
        return ""
    }

    func registerDevice() async {
        lastError = nil
        guard let token = UserDefaults.standard.string(forKey: "deviceToken"),
              !workerUrl.isEmpty else { return }

        guard let url = URL(string: "\(workerUrl)/register") else {
            lastError = "Invalid Worker URL"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sharedSecret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(["token": token])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200:
                    isRegistered = true
                case 401:
                    lastError = "Authentication failed — check shared secret"
                case 503:
                    lastError = "No device registered on worker"
                default:
                    lastError = "Registration failed (HTTP \(http.statusCode))"
                }
            }
        } catch {
            lastError = "Registration failed: \(error.localizedDescription)"
        }
    }

    nonisolated func sendDecision(requestId: String, decision: String) async {
        let (workerUrl, secret) = await MainActor.run { (self.workerUrl, self.sharedSecret) }
        guard !workerUrl.isEmpty, let url = URL(string: "\(workerUrl)/response") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        // Worst-case latency budget under iOS's bgTask window (~30s).
        request.timeoutInterval = 10

        let body: [String: String] = ["requestId": requestId, "decision": decision]
        request.httpBody = try? JSONEncoder().encode(body)

        for attempt in 1...2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if code == 200 { return }
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                NSLog("Pager: sendDecision attempt %d HTTP %d body=%@", attempt, code, bodyStr)
                // 4xx won't recover by retrying — surface and stop.
                if (400..<500).contains(code) {
                    await MainActor.run {
                        NetworkService.shared.lastError = "Decision send failed (HTTP \(code)): \(bodyStr)"
                    }
                    return
                }
            } catch {
                NSLog("Pager: sendDecision attempt %d error: %@", attempt, "\(error)")
                if attempt == 2 {
                    await MainActor.run {
                        NetworkService.shared.lastError = "Decision send failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func sendTestNotification() async -> String {
        lastError = nil
        guard !workerUrl.isEmpty else { return "Worker URL is empty" }

        guard let url = URL(string: "\(workerUrl)/test") else {
            return "Invalid Worker URL"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sharedSecret)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return "Sent!"
            } else if let http = response as? HTTPURLResponse {
                let detail = String(data: data, encoding: .utf8) ?? ""
                return "Failed (HTTP \(http.statusCode)): \(detail)"
            }
            return "Failed"
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }
}
