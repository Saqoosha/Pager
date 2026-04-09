import Foundation

@MainActor
final class NetworkService: ObservableObject {
    static let shared = NetworkService()

    @Published var isRegistered = false

    private var workerUrl: String {
        UserDefaults.standard.string(forKey: "workerUrl") ?? ""
    }

    private var sharedSecret: String {
        UserDefaults.standard.string(forKey: "sharedSecret") ?? ""
    }

    func registerDevice() async {
        guard let token = UserDefaults.standard.string(forKey: "deviceToken"),
              !workerUrl.isEmpty else { return }

        var request = URLRequest(url: URL(string: "\(workerUrl)/register")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sharedSecret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(["token": token])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                isRegistered = true
            }
        } catch {
            print("Registration failed: \(error)")
        }
    }

    nonisolated func sendDecision(requestId: String, decision: String) async {
        let workerUrl = await MainActor.run { self.workerUrl }
        let secret = await MainActor.run { self.sharedSecret }
        guard !workerUrl.isEmpty else { return }

        var request = URLRequest(url: URL(string: "\(workerUrl)/response")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")

        let body: [String: String] = ["requestId": requestId, "decision": decision]
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let _ = try await URLSession.shared.data(for: request)
        } catch {
            print("Decision send failed: \(error)")
        }
    }

    func sendTestNotification() async -> Bool {
        guard !workerUrl.isEmpty else { return false }

        var request = URLRequest(url: URL(string: "\(workerUrl)/test")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sharedSecret)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            print("Test notification failed: \(error)")
            return false
        }
    }
}
