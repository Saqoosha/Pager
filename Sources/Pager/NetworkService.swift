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
        let workerUrl = await MainActor.run { self.workerUrl }
        let secret = await MainActor.run { self.sharedSecret }
        guard !workerUrl.isEmpty, let url = URL(string: "\(workerUrl)/response") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")

        let body: [String: String] = ["requestId": requestId, "decision": decision]
        request.httpBody = try? JSONEncoder().encode(body)

        for attempt in 1...2 {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return
                }
            } catch {
                if attempt == 2 {
                    NSLog("Pager: sendDecision failed after retry: %@", "\(error)")
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
