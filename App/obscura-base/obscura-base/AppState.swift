import SwiftUI
import ObscuraKit

/// App-level state — owns the ObscuraClient for the process lifetime.
/// iOS equivalent of Kotlin's ObscuraApp.kt.
/// Session credentials stored in Keychain (iOS Keychain Services).
@MainActor
class AppState: ObservableObject {
    let client: ObscuraClient

    @Published var isAuthenticated: Bool = false
    @Published var statusText: String = "Ready"
    @Published var friends: [Friend] = []
    @Published var pendingRequests: [Friend] = []

    init() {
        // Safe to force-try: only fails if URL is not HTTPS
        self.client = try! ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")

        // Restore session if saved
        if let saved = KeychainSession.load() {
            Task {
                await client.restoreSession(
                    token: saved.token,
                    refreshToken: saved.refreshToken,
                    userId: saved.userId,
                    deviceId: saved.deviceId,
                    username: saved.username
                )
                do {
                    try await client.connect()
                    isAuthenticated = true
                } catch {
                    // Session expired — need to re-login
                    isAuthenticated = false
                }
            }
        }

        // Start GRDB observation for reactive friend list
        startObserving()
    }

    private func startObserving() {
        // Friends (accepted)
        Task {
            for await updated in client.friends.observeAccepted().values {
                self.friends = updated
            }
        }

        // Pending requests
        Task {
            for await updated in client.friends.observePending().values {
                self.pendingRequests = updated
            }
        }
    }

    func register(_ username: String, _ password: String) async {
        statusText = "Registering '\(username)'..."
        do {
            try await client.register(username, password)
            isAuthenticated = true
            saveSession()
            try await client.connect()
            statusText = "Registered and connected"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    func login(_ username: String, _ password: String) async {
        statusText = "Logging in..."
        do {
            try await client.login(username, password)
            isAuthenticated = true
            saveSession()
            try await client.connect()
            statusText = "Logged in and connected"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    func logout() async {
        do {
            try await client.logout()
        } catch {}
        isAuthenticated = false
        KeychainSession.clear()
        statusText = "Logged out"
    }

    func befriend(_ userId: String) async {
        do {
            try await client.befriend(userId)
            statusText = "Friend request sent!"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    func acceptFriend(_ userId: String) async {
        do {
            try await client.acceptFriend(userId)
            statusText = "Accepted!"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    func send(to friendUserId: String, _ text: String) async {
        do {
            try await client.send(to: friendUserId, text)
            statusText = "Sent!"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    private func saveSession() {
        guard let token = client.token,
              let userId = client.userId else { return }
        KeychainSession.save(SessionData(
            token: token,
            refreshToken: client.refreshToken,
            userId: userId,
            deviceId: client.deviceId,
            username: client.username
        ))
    }
}
