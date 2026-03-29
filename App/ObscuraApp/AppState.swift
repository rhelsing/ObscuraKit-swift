import SwiftUI
import ObscuraKit

@MainActor
class AppState: ObservableObject {
    private(set) var client: ObscuraClient

    @Published var isAuthenticated: Bool = false
    @Published var statusText: String = "Ready"
    @Published var friends: [Friend] = []
    @Published var pendingRequests: [Friend] = []
    @Published var pendingSent: [Friend] = []

    private var observationTasks: [Task<Void, Never>] = []

    private static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ObscuraData")
    }

    private static func userDir(for userId: String) -> String {
        baseDir.appendingPathComponent(userId).path
    }

    init() {
        if let saved = KeychainSession.load() {
            // Open existing user-scoped encrypted DB
            self.client = try! ObscuraClient(
                apiURL: "https://obscura.barrelmaker.dev",
                dataDirectory: Self.userDir(for: saved.userId),
                userId: saved.userId
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
            self.client = try! ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")
        }
        startObserving()
    }

    // MARK: - Auth

    func register(_ username: String, _ password: String) async {
        statusText = "Registering..."
        do {
            // Phase 1: API call only — get userId (no DB needed)
            let creds = try await ObscuraClient.registerAccount(username, password)
            guard !creds.userId.isEmpty else {
                statusText = "Error: no userId"
                return
            }

            // Phase 2: Create encrypted user-scoped client and register fully
            let userDir = Self.userDir(for: creds.userId)
            try? FileManager.default.removeItem(atPath: userDir)
            let userClient = try ObscuraClient(
                apiURL: "https://obscura.barrelmaker.dev",
                dataDirectory: userDir,
                userId: creds.userId
            )

            // Set auth tokens from phase 1 via restoreSession
            await userClient.restoreSession(
                token: creds.token,
                refreshToken: creds.refreshToken,
                userId: creds.userId,
                deviceId: nil,
                username: username
            )
            // Now provision device (generate Signal keys + register with server)
            try await userClient.provisionCurrentDevice()

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
            // Phase 1: Authenticate to get userId
            let creds = try await ObscuraClient.loginAccount(username, password)
            guard !creds.userId.isEmpty else {
                statusText = "Error: no userId"
                return
            }

            let userDir = Self.userDir(for: creds.userId)
            let existingDB = FileManager.default.fileExists(atPath: userDir)

            if existingDB {
                // Returning user — reuse their encrypted DB
                let userClient = try ObscuraClient(
                    apiURL: "https://obscura.barrelmaker.dev",
                    dataDirectory: userDir,
                    userId: creds.userId
                )
                await userClient.restoreSession(
                    token: creds.token,
                    refreshToken: creds.refreshToken,
                    userId: creds.userId,
                    deviceId: nil,
                    username: username
                )
                replaceClient(userClient)
            } else {
                // New user on this device — create encrypted DB + provision
                let userClient = try ObscuraClient(
                    apiURL: "https://obscura.barrelmaker.dev",
                    dataDirectory: userDir,
                    userId: creds.userId
                )
                await userClient.restoreSession(
                    token: creds.token,
                    refreshToken: creds.refreshToken,
                    userId: creds.userId,
                    deviceId: nil,
                    username: username
                )
                try await userClient.provisionCurrentDevice()
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

    func addFriendByCode(_ code: String) async {
        // Decode base64 friend code: {"n":"username","u":"userId"}
        guard let data = Data(base64Encoded: code),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let userId = json["u"] else {
            statusText = "Invalid friend code"
            return
        }
        let username = json["n"] ?? ""
        await befriend(userId, username: username)
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
        observationTasks.append(Task {
            for await updated in client.friends.observePendingSent().values {
                self.pendingSent = updated
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
