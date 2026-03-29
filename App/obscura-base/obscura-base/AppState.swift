import SwiftUI
import ObscuraKit

@MainActor
class AppState: ObservableObject {
    private(set) var client: ObscuraClient

    @Published var isAuthenticated: Bool = false
    @Published var statusText: String = "Ready"
    @Published var friends: [Friend] = []
    @Published var pendingRequests: [Friend] = []

    private var observationTasks: [Task<Void, Never>] = []

    private static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ObscuraData")
    }

    /// User-scoped data directory: ObscuraData/{userId}/
    private static func userDir(for userId: String) -> String {
        baseDir.appendingPathComponent(userId).path
    }

    init() {
        if let saved = KeychainSession.load() {
            // Open existing user-scoped DB — pick up where they left off
            self.client = try! ObscuraClient(
                apiURL: "https://obscura.barrelmaker.dev",
                dataDirectory: Self.userDir(for: saved.userId)
            )
            Task {
                await client.restoreSession(
                    token: saved.token,
                    refreshToken: saved.refreshToken,
                    userId: saved.userId,
                    deviceId: saved.deviceId,
                    username: saved.username
                )
                let tokenOk = await client.ensureFreshToken()
                guard tokenOk else {
                    KeychainSession.clear()
                    isAuthenticated = false
                    return
                }
                saveSession()
                do {
                    try await client.connect()
                    isAuthenticated = true
                } catch {
                    isAuthenticated = false
                }
            }
        } else {
            // No session — lightweight in-memory client for auth only
            self.client = try! ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")
        }
        startObserving()
    }

    // MARK: - Auth

    func register(_ username: String, _ password: String) async {
        statusText = "Registering..."
        do {
            // Register into a temp directory (userId unknown until API responds)
            let tempDir = Self.baseDir.appendingPathComponent("_pending").path
            try? FileManager.default.removeItem(atPath: tempDir)
            let tempClient = try ObscuraClient(
                apiURL: "https://obscura.barrelmaker.dev",
                dataDirectory: tempDir
            )
            try await tempClient.register(username, password)

            guard let userId = tempClient.userId else {
                statusText = "Error: no userId"
                return
            }

            // Move temp DB to user-scoped path: ObscuraData/{userId}/
            let userDir = Self.userDir(for: userId)
            try? FileManager.default.removeItem(atPath: userDir)
            try FileManager.default.moveItem(atPath: tempDir, toPath: userDir)

            // Open the real client from the user's DB
            let userClient = try ObscuraClient(
                apiURL: "https://obscura.barrelmaker.dev",
                dataDirectory: userDir
            )
            await userClient.restoreSession(
                token: tempClient.token!,
                refreshToken: tempClient.refreshToken,
                userId: userId,
                deviceId: tempClient.deviceId,
                username: username
            )

            replaceClient(userClient)
            isAuthenticated = true
            saveSession()
            try? await Task.sleep(nanoseconds: 600_000_000)
            try await client.connect()
            statusText = "Registered and connected"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    func login(_ username: String, _ password: String) async {
        statusText = "Logging in..."
        do {
            // First: authenticate to get userId + tokens
            let tempClient = try ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")
            try await tempClient.loginAndProvision(username, password)

            guard let userId = tempClient.userId else {
                statusText = "Error: no userId"
                return
            }

            let userDir = Self.userDir(for: userId)
            let existingDB = FileManager.default.fileExists(atPath: userDir)

            if existingDB {
                // User has data on this device — reuse their DB, just refresh auth
                let userClient = try ObscuraClient(
                    apiURL: "https://obscura.barrelmaker.dev",
                    dataDirectory: userDir
                )
                await userClient.restoreSession(
                    token: tempClient.token!,
                    refreshToken: tempClient.refreshToken,
                    userId: userId,
                    deviceId: tempClient.deviceId,
                    username: username
                )
                replaceClient(userClient)
            } else {
                // First time on this device — provision into user-scoped dir
                let tempDir = Self.baseDir.appendingPathComponent("_pending").path
                try? FileManager.default.removeItem(atPath: tempDir)
                let provClient = try ObscuraClient(
                    apiURL: "https://obscura.barrelmaker.dev",
                    dataDirectory: tempDir
                )
                try await provClient.loginAndProvision(username, password)
                try FileManager.default.moveItem(atPath: tempDir, toPath: userDir)

                let userClient = try ObscuraClient(
                    apiURL: "https://obscura.barrelmaker.dev",
                    dataDirectory: userDir
                )
                await userClient.restoreSession(
                    token: provClient.token!,
                    refreshToken: provClient.refreshToken,
                    userId: userId,
                    deviceId: provClient.deviceId,
                    username: username
                )
                replaceClient(userClient)
            }

            isAuthenticated = true
            saveSession()
            try await client.connect()
            statusText = "Logged in and connected"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    func logout() async {
        do { try await client.logout() } catch {}
        isAuthenticated = false
        KeychainSession.clear()
        // DB stays on disk — user can log back in and pick up where they left off
        statusText = "Logged out"
    }

    // MARK: - Actions

    func befriend(_ userId: String, username: String = "") async {
        do {
            try await client.befriend(userId, username: username)
            statusText = "Friend request sent!"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    func acceptFriend(_ userId: String, username: String = "") async {
        do {
            try await client.acceptFriend(userId, username: username)
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

    // MARK: - Private

    private func replaceClient(_ newClient: ObscuraClient) {
        client.disconnect()
        client = newClient
        startObserving()
    }

    private func startObserving() {
        for task in observationTasks { task.cancel() }
        observationTasks.removeAll()

        observationTasks.append(Task {
            for await updated in client.friends.observeAccepted().values {
                self.friends = updated
            }
        })
        observationTasks.append(Task {
            for await updated in client.friends.observePending().values {
                self.pendingRequests = updated
            }
        })
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
