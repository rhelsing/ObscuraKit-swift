import SwiftUI
import ObscuraKit

/// Root view — shows RegisterScreen when logged out, ConnectedScreen when authenticated.
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Auth: \(appState.isAuthenticated ? "authenticated" : "logged_out")")
                .font(.caption)
            Text(appState.statusText)
                .font(.caption2)
                .foregroundColor(.secondary)

            Divider()

            if !appState.isAuthenticated {
                RegisterScreen()
            } else {
                ConnectedScreen()
            }
        }
        .padding()
    }
}

// MARK: - Register / Login

struct RegisterScreen: View {
    @EnvironmentObject var appState: AppState
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Register / Login")
                .font(.headline)

            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            SecureField("Password (12+ chars)", text: $password)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
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
    }
}

// MARK: - Connected Screen

struct ConnectedScreen: View {
    @EnvironmentObject var appState: AppState
    @State private var targetUserId = ""
    @State private var selectedFriend: Friend?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // User info — tap to copy userId
            Text("User: \(appState.client.username ?? "") (\(appState.client.userId ?? ""))")
                .font(.subheadline)
                .onTapGesture {
                    if let id = appState.client.userId {
                        UIPasteboard.general.string = id
                        appState.statusText = "userId copied"
                    }
                }

            // Befriend
            HStack(spacing: 4) {
                TextField("Friend userId", text: $targetUserId)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button("Add") {
                    Task {
                        await appState.befriend(targetUserId)
                        targetUserId = ""
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            // Pending requests
            if !appState.pendingRequests.isEmpty {
                Text("Pending (\(appState.pendingRequests.count)):")
                    .font(.caption)
                    .bold()
                ForEach(appState.pendingRequests, id: \.userId) { req in
                    HStack {
                        Text(req.username)
                        Spacer()
                        Button("Accept") {
                            Task { await appState.acceptFriend(req.userId) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            // Friends list
            Text("Friends (\(appState.friends.count)):")
                .font(.caption)
                .bold()
            ForEach(appState.friends, id: \.userId) { friend in
                Button {
                    selectedFriend = friend
                } label: {
                    Text(selectedFriend?.userId == friend.userId ? "> \(friend.username)" : friend.username)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            // Chat with selected friend
            if let friend = selectedFriend {
                Divider()
                ChatView(friend: friend)
            }

            Spacer()

            // Logout
            Button("Logout") {
                Task { await appState.logout() }
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
        }
    }
}

// MARK: - Chat View

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    let friend: Friend
    @State private var messageText = ""
    @State private var messages: [Message] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Chat: \(friend.username)")
                .font(.subheadline)
                .bold()

            // Messages — GRDB reactive observation
            List(messages, id: \.messageId) { msg in
                HStack {
                    if msg.isSent {
                        Spacer()
                        Text(msg.content)
                            .padding(8)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(8)
                    } else {
                        Text(msg.content)
                            .padding(8)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                        Spacer()
                    }
                }
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .task {
                for await updated in appState.client.messages.observeMessages(friend.userId).values {
                    messages = updated
                }
            }

            // Send message
            HStack(spacing: 4) {
                TextField("Message", text: $messageText)
                    .textFieldStyle(.roundedBorder)

                Button("Send") {
                    let text = messageText
                    messageText = ""
                    Task { await appState.send(to: friend.userId, text) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
