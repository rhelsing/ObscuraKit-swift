import SwiftUI
import ObscuraKit

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
    @State private var friendCodeInput = ""
    @State private var selectedFriend: Friend?
    @State private var codeCopied = false

    private var myCode: String? {
        guard let userId = appState.client.userId,
              let username = appState.client.username else { return nil }
        return FriendCode.encode(userId: userId, username: username)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // My friend code — tap to copy
            if let code = myCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("My Friend Code")
                        .font(.caption)
                        .bold()
                    Text(code)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(6)
                        .onTapGesture {
                            UIPasteboard.general.string = code
                            codeCopied = true
                            appState.statusText = "Friend code copied!"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { codeCopied = false }
                        }
                    Text(codeCopied ? "Copied!" : "Tap to copy")
                        .font(.caption2)
                        .foregroundColor(codeCopied ? .green : .secondary)
                }
            }

            Divider()

            // Add friend by code
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Friend")
                    .font(.caption)
                    .bold()
                HStack(spacing: 4) {
                    TextField("Paste friend code", text: $friendCodeInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Add") {
                        let code = friendCodeInput
                        friendCodeInput = ""
                        Task { await appState.addFriendByCode(code) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(friendCodeInput.isEmpty)
                }
            }

            // Sent requests (pending outgoing)
            if !appState.pendingSent.isEmpty {
                Text("Sent (\(appState.pendingSent.count)):")
                    .font(.caption)
                    .bold()
                    .foregroundColor(.orange)
                ForEach(appState.pendingSent, id: \.userId) { req in
                    HStack {
                        Text(req.username.isEmpty ? req.userId.prefix(8) + "..." : req.username)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("pending")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }

            // Incoming requests (pending received)
            if !appState.pendingRequests.isEmpty {
                Text("Requests (\(appState.pendingRequests.count)):")
                    .font(.caption)
                    .bold()
                    .foregroundColor(.blue)
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
