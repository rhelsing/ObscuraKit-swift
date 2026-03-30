import SwiftUI
import ObscuraKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.needsDeviceLink {
                DeviceLinkView()
            } else if !appState.isAuthenticated {
                AuthView()
            } else {
                MainView()
            }
        }
    }
}

// MARK: - Auth

struct AuthView: View {
    @EnvironmentObject var appState: AppState
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            SecureField("Password (12+ chars)", text: $password)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Button("Register") {
                    Task { await appState.register(username, password) }
                }
                .buttonStyle(.borderedProminent)

                Button("Login") {
                    Task { await appState.login(username, password) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

// MARK: - Device Link (enforced for new devices)

struct DeviceLinkView: View {
    @EnvironmentObject var appState: AppState
    @State private var scanInput = ""

    var body: some View {
        VStack(spacing: 16) {
            if let code = appState.linkCode {
                // This device needs approval — show code for existing device to scan
                Text("Link This Device")
                    .font(.headline)
                Text("Show this code to your existing device:")
                    .font(.caption)

                Text(code)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(12)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .onTapGesture {
                        UIPasteboard.general.string = code
                        appState.statusText = "Link code copied!"
                    }

                Text("Waiting for approval...")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ProgressView()
            } else {
                // This is the existing device — scan new device's code
                Text("Approve New Device")
                    .font(.headline)

                TextField("Paste link code from new device", text: $scanInput)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                Button("Approve") {
                    let code = scanInput
                    scanInput = ""
                    Task { await appState.approveDeviceLink(code) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(scanInput.isEmpty)
            }
        }
        .padding()
    }
}

// MARK: - Main (tabbed)

struct MainView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            FriendsTab()
                .tabItem { Label("Friends", systemImage: "person.2") }

            StoriesTab()
                .tabItem { Label("Stories", systemImage: "book") }

            ProfileTab()
                .tabItem { Label("Profile", systemImage: "person.circle") }

            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

// MARK: - Friends Tab

struct FriendsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var friendCodeInput = ""
    @State private var selectedFriend: Friend?
    @State private var linkCodeInput = ""

    private var myCode: String? {
        guard let userId = appState.client.userId,
              let username = appState.client.username else { return nil }
        return FriendCode.encode(userId: userId, username: username)
    }

    var body: some View {
        NavigationStack {
        List {
            // My friend code — selectable so Cmd+C works in simulator
            if let code = myCode {
                Section("My Friend Code") {
                    TextField("", text: .constant(code))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            // Add friend
            Section("Add Friend") {
                HStack {
                    TextField("Paste friend code", text: $friendCodeInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Add") {
                        let code = friendCodeInput
                        friendCodeInput = ""
                        Task { await appState.addFriendByCode(code) }
                    }
                    .disabled(friendCodeInput.isEmpty)
                }
            }

            // Link a new device
            Section("Link Device") {
                HStack {
                    TextField("Paste device link code", text: $linkCodeInput)
                        .autocorrectionDisabled()
                    Button("Approve") {
                        let code = linkCodeInput
                        linkCodeInput = ""
                        Task { await appState.approveDeviceLink(code) }
                    }
                    .disabled(linkCodeInput.isEmpty)
                }
            }

            // Pending received
            if !appState.pendingRequests.isEmpty {
                Section("Requests") {
                    ForEach(appState.pendingRequests, id: \.userId) { req in
                        HStack {
                            Text(req.username)
                            Spacer()
                            Button("Accept") {
                                Task { await appState.acceptFriend(req.userId, username: req.username) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            // Pending sent
            if !appState.pendingSent.isEmpty {
                Section("Sent") {
                    ForEach(appState.pendingSent, id: \.userId) { req in
                        HStack {
                            Text(req.username.isEmpty ? String(req.userId.prefix(8)) + "..." : req.username)
                            Spacer()
                            Text("pending").font(.caption2).foregroundColor(.orange)
                        }
                    }
                }
            }

            // Friends
            Section("Friends (\(appState.friends.count))") {
                ForEach(appState.friends, id: \.userId) { friend in
                    NavigationLink(value: friend.userId) {
                        Text(friend.username)
                    }
                }
            }
        }
        .navigationDestination(for: String.self) { friendUserId in
            let friend = appState.friends.first { $0.userId == friendUserId }
            ChatView(friendUserId: friendUserId, friendUsername: friend?.username ?? "")
        }
        .navigationTitle("Friends")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Logout") {
                    Task { await appState.logout() }
                }
                .foregroundColor(.red)
            }
        }
        } // NavigationStack
    }
}

// MARK: - Chat (ORM messages)

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    let friendUserId: String
    let friendUsername: String
    @State private var messageText = ""
    @State private var messages: [DirectMessage] = []
    @State private var friendIsTyping = false

    private var convId: String {
        appState.conversationId(with: friendUserId)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages — newest at bottom
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { i, msg in
                            let isMine = msg.senderUsername == appState.client.username
                            HStack {
                                if isMine { Spacer() }
                                Text(msg.content)
                                    .padding(10)
                                    .background(isMine ? Color.blue.opacity(0.2) : Color.gray.opacity(0.15))
                                    .cornerRadius(12)
                                if !isMine { Spacer() }
                            }
                            .padding(.horizontal, 12)
                            .id(i)
                        }

                        // Typing bubble (animated three dots)
                        if friendIsTyping {
                            HStack {
                                TypingBubble()
                                    .padding(.horizontal, 12)
                                Spacer()
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.count) { _ in
                    if !messages.isEmpty {
                        withAnimation { proxy.scrollTo(messages.count - 1, anchor: .bottom) }
                    }
                }
            }
            .task {
                // Filtered observation — canonical conversation ID
                let query = appState.messages
                    .where { "conversationId" == convId }
                let observation = query.observe()
                for await updated in observation.values {
                    messages = updated.reversed()
                }
            }
            .task {
                // Typing indicator observation
                for await who in appState.messages.observeTyping(conversationId: convId).values {
                    friendIsTyping = !who.isEmpty
                }
            }

            Divider()

            // Compose
            HStack(spacing: 8) {
                TextField("Message", text: $messageText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: messageText) { newValue in
                        if !newValue.isEmpty {
                            Task { await appState.messages.typing(conversationId: convId) }
                        }
                    }

                Button("Send") {
                    let text = messageText
                    messageText = ""
                    Task { await appState.messages.stopTyping(conversationId: convId) }
                    Task { await appState.sendMessage(to: friendUserId, text) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(messageText.isEmpty)
            }
            .padding(12)
        }
        .navigationTitle(friendUsername)
    }
}

// MARK: - Stories Tab (GSet, ephemeral)

struct StoriesTab: View {
    @EnvironmentObject var appState: AppState
    @State private var storyText = ""
    @State private var storyEntries: [Story] = []

    var body: some View {
        List {
            Section("Post Story") {
                HStack {
                    TextField("What's happening?", text: $storyText)
                    Button("Post") {
                        let text = storyText
                        storyText = ""
                        Task { await appState.postStory(text) }
                    }
                    .disabled(storyText.isEmpty)
                }
            }

            Section("Feed") {
                if storyEntries.isEmpty {
                    Text("No stories yet")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(storyEntries, id: \.content) { story in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(story.authorUsername).font(.caption).bold()
                            Text(story.content)
                        }
                    }
                }
            }
        }
        .task {
            for await updated in appState.stories.observe().values {
                storyEntries = updated
            }
        }
    }
}

// MARK: - Profile Tab (LWWMap, .friends scope)

struct ProfileTab: View {
    @EnvironmentObject var appState: AppState
    @State private var displayName = ""
    @State private var bio = ""
    @State private var loaded = false

    var body: some View {
        List {
            Section("Edit Profile") {
                TextField("Display Name", text: $displayName)
                TextField("Bio", text: $bio)
                Button("Save") {
                    Task {
                        await appState.updateProfile(displayName: displayName, bio: bio.isEmpty ? nil : bio)
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Section("Friend Profiles") {
                // Shows profiles synced from friends
                FriendProfilesList()
            }
        }
        .task {
            guard !loaded else { return }
            // Load own profile
            if let userId = appState.client.userId {
                let entry = await appState.profiles.find("\(userId)_profile")
                if let p = entry {
                    displayName = p.value.displayName
                    bio = p.value.bio ?? ""
                }
            }
            loaded = true
        }
    }
}

struct FriendProfilesList: View {
    @EnvironmentObject var appState: AppState
    @State private var friendProfiles: [Profile] = []

    var body: some View {
        Group {
            if friendProfiles.isEmpty {
                Text("No profiles synced yet").foregroundColor(.secondary)
            } else {
                ForEach(friendProfiles, id: \.displayName) { profile in
                    VStack(alignment: .leading) {
                        Text(profile.displayName).bold()
                        if let bio = profile.bio {
                            Text(bio).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .task {
            for await updated in appState.profiles.observe().values {
                friendProfiles = updated
            }
        }
    }
}

// MARK: - Settings Tab (LWWMap, .ownDevices — private)

struct SettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var darkMode = false
    @State private var notificationsEnabled = true
    @State private var loaded = false

    var body: some View {
        List {
            Section("Preferences") {
                Toggle("Dark Mode", isOn: $darkMode)
                    .onChange(of: darkMode) { _ in saveSettings() }
                Toggle("Notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _ in saveSettings() }
            }

            Section("Account") {
                if let userId = appState.client.userId {
                    LabeledContent("User ID", value: String(userId.prefix(12)) + "...")
                }
                if let username = appState.client.username {
                    LabeledContent("Username", value: username)
                }
                if let deviceId = appState.client.deviceId {
                    LabeledContent("Device", value: String(deviceId.prefix(12)) + "...")
                }
            }

            Section {
                Button("Logout", role: .destructive) {
                    Task { await appState.logout() }
                }
            }
        }
        .task {
            guard !loaded else { return }
            if let userId = appState.client.userId {
                let entry = await appState.settings.find("\(userId)_settings")
                if let s = entry {
                    darkMode = s.value.theme == "dark"
                    notificationsEnabled = s.value.notificationsEnabled
                }
            }
            loaded = true
        }
    }

    private func saveSettings() {
        guard let userId = appState.client.userId else { return }
        Task {
            try? await appState.settings.upsert("\(userId)_settings",
                AppSettings(theme: darkMode ? "dark" : "light", notificationsEnabled: notificationsEnabled))
        }
    }
}

// MARK: - Typing Bubble (animated three dots)

struct TypingBubble: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.gray)
                    .frame(width: 8, height: 8)
                    .opacity(dotOpacity(for: index))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.15))
        .cornerRadius(12)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func dotOpacity(for index: Int) -> Double {
        let delay = Double(index) * 0.33
        let t = (phase + delay).truncatingRemainder(dividingBy: 1.0)
        return 0.3 + 0.7 * abs(sin(t * .pi))
    }
}
