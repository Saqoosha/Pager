import Foundation

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Set by `NotificationDelegate.didReceive` when the user taps a
    /// notification. `ContentView` observes this and pushes the detail view
    /// onto the navigation stack.
    @Published var pendingDetailId: String?

    private init() {}
}
