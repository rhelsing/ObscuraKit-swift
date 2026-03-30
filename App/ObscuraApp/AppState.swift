import SwiftUI
import ObscuraKit

@MainActor
class AppState: ObservableObject {
    private(set) var client: ObscuraClient

    // Auth
    @Published var isAuthenticated = false
    @Published var statusText = "Ready"

    // Infrastructure (reactive — GRDB observation)
    @Published var friends: [Friend] = []
    @Published var pendingRequests: [Friend] = []
    @Published var pendingSent: [Friend] = []

    // ORM typed models (set after schema registration)
    var messages: TypedModel<DirectMessage>!
    var profiles: TypedModel<Profile>!
    var settings: TypedModel<AppSettings>!
    var stories: TypedModel<Story>!

    // Device linking
    @Published var needsDeviceLink = false
    @Published var linkCode: String?

    private var observationTasks: [Task<Void, Never>] = []

    // MARK: - Storage

    private static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ObscuraData")
    }

    private static func userDir(for userId: String) -> String {
        baseDir.appendingPathComponent(userId).path
    }

    // MARK: - Init

    init() {
        if let saved = KeychainSession.load() {
            self.client = try! ObscuraClient(
                apiURL: "https://obscura.barrelmaker.dev",
                dataDirectory: Self.userDir(for: saved.userId),
                userId: saved.userId
            )
            defineModels()
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

    // MARK: - ORM Registration (like a Rails migration — call once after auth)

    private func defineModels() {
        client.defineModels(DirectMessage.self, Story.self, Profile.self, AppSettings.self)
        messages = client.register(DirectMessage.self)
        profiles = client.register(Profile.self)
        settings = client.register(AppSettings.self)
        stories = client.register(Story.self)
    }

    // MARK: - Auth

    func register(_ username: String, _ password: String) async {
        statusText = "Registering..."
        do {
            let creds = try await ObscuraClient.registerAccount(username, password)
            guard !creds.userId.isEmpty else {
                statusText = "Error: no userId"
                return
            }

            let userDir = Self.userDir(for: creds.userId)
            try? FileManager.default.removeItem(atPath: userDir)
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
            // First device — provision directly (no link needed)
            try await userClient.provisionCurrentDevice()

            replaceClient(userClient)
            isAuthenticated = true
            saveSession()

            // Set initial profile
            try? await profiles.upsert("\(creds.userId)_profile",
                Profile(displayName: username, bio: nil, avatarUrl: nil))

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
            // Step 1: Get userId to create user-scoped DB
            let shellCreds = try await ObscuraClient.loginAccount(username, password)
            guard !shellCreds.userId.isEmpty else {
                statusText = "Error: no userId"
                return
            }

            // Step 2: Create file-backed client with user-scoped encrypted DB
            let userDir = Self.userDir(for: shellCreds.userId)
            let userClient = try ObscuraClient(
                apiURL: "https://obscura.barrelmaker.dev",
                dataDirectory: userDir,
                userId: shellCreds.userId
            )
            replaceClient(userClient)

            // Step 3: Smart login — returns what to do next
            let scenario = try await client.loginSmart(username, password)

            switch scenario {
            case .existingDevice:
                defineModels()
                try await client.connect()
                isAuthenticated = true
                saveSession()
                statusText = "Logged in and connected"

            case .newDevice, .deviceMismatch:
                // Provision Signal keys so we can generate a link code
                try await client.loginAndProvision(username, password,
                    deviceName: "iOS-\(UUID().uuidString.prefix(4))")
                defineModels()
                saveSession()

                // Generate link code and show QR screen
                linkCode = client.generateLinkCode()
                needsDeviceLink = true
                statusText = "Scan this code on your existing device"

                // Connect and wait for approval
                try await client.connect()
                let approval = try await client.waitForMessage(timeout: 300)
                if approval.type == 11 { // DEVICE_LINK_APPROVAL
                    needsDeviceLink = false
                    isAuthenticated = true
                    statusText = "Device linked!"
                }

            case .invalidCredentials:
                statusText = "Wrong password"

            case .userNotFound:
                statusText = "User not found"
            }
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    /// Approve a device link from this device (existing device scans new device's code)
    func approveDeviceLink(_ code: String) async {
        statusText = "Approving link..."
        do {
            try await client.validateAndApproveLink(code)
            statusText = "Device linked!"
        } catch {
            statusText = "Link failed: \(error.localizedDescription)"
        }
    }

    func logout() async {
        do { try await client.logout() } catch {}
        isAuthenticated = false
        needsDeviceLink = false
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
        do {
            let decoded = try FriendCode.decode(code)
            await befriend(decoded.userId, username: decoded.username)
        } catch {
            statusText = "Invalid friend code"
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

    /// Canonical conversation ID — same from both sides.
    func conversationId(with friendUserId: String) -> String {
        guard let myId = client.userId else { return friendUserId }
        return [myId, friendUserId].sorted().joined(separator: "_")
    }

    func sendMessage(to friendUserId: String, _ text: String) async {
        guard let username = client.username else { return }
        do {
            try await messages.create(DirectMessage(
                conversationId: conversationId(with: friendUserId),
                content: text,
                senderUsername: username
            ))
            statusText = "Sent!"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    func postStory(_ content: String) async {
        guard let username = client.username else { return }
        do {
            try await stories.create(Story(content: content, authorUsername: username))
            statusText = "Story posted!"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    func updateProfile(displayName: String, bio: String?) async {
        guard let userId = client.userId else { return }
        do {
            try await profiles.upsert("\(userId)_profile",
                Profile(displayName: displayName, bio: bio, avatarUrl: nil))
            statusText = "Profile updated!"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func replaceClient(_ newClient: ObscuraClient) {
        client.disconnect()
        client = newClient
        defineModels()
        startObserving()
    }

    private func startObserving() {
        for task in observationTasks { task.cancel() }
        observationTasks.removeAll()

        // Friends (infrastructure — still uses FriendActor directly, it's not ORM)
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
