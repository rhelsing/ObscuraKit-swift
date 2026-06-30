import SwiftUI
import ObscuraKit
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

@main
struct ObscuraAppMain: App {
    // Bridges APNs/FCM callbacks into the kit. See AppDelegate below.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Push Coordinator
//
// Mirrors the role of Android's ObscuraApp: it owns the bridge between push
// callbacks (which fire on AppDelegate, with no SwiftUI context) and the kit
// client (owned by AppState). It remembers a token that arrives before login and
// runs the silent-push drain + notify path. The kit NEVER posts OS notifications —
// it only hands back ProcessedCounts; PushNotifier turns those into user text.

@MainActor
final class PushCoordinator {
    static let shared = PushCoordinator()
    private init() {}

    /// The live client. AppState keeps this current (replaceClient / saveSession).
    var client: ObscuraClient?
    /// Optional sink into AppState's on-screen debug log.
    var log: ((String) -> Void)?

    /// A token that arrived (possibly before login). Registered once we have a session.
    private var pendingToken: String?

    private func note(_ m: String) {
        log?(m)
        NSLog("[ObscuraApp] %@", m)
    }

    /// A push token (FCM or APNs) arrived. Remember it; register if a session exists.
    func onPushToken(_ token: String) {
        pendingToken = token
        note("push token: \(token.prefix(12))…")
        registerPendingTokenIfReady()
    }

    /// Called after auth (from AppState.saveSession) — registers any earlier token.
    func registerPendingTokenIfReady() {
        guard let token = pendingToken, let client, client.hasSession else { return }
        Task {
            do {
                try await client.registerPushToken(token)
                note("registered push token with server")
            } catch {
                note("registerPushToken failed: \(error)")
            }
        }
    }

    /// Silent push arrived. Wake the kit, drain queued envelopes, post one generic
    /// local notification. Identical path whether triggered by real FCM or a test push.
    func handleSilentPush() async {
        guard let client, client.hasSession else {
            note("silent push but no session — ignoring")
            return
        }
        note("silent push — draining")
        let counts = await client.processPendingMessages(timeout: 10)
        note("drain done: pix=\(counts.pixCount) msg=\(counts.messageCount) other=\(counts.otherCount)")
        PushNotifier.post(counts)
    }
}

// MARK: - Push Notifier
//
// The single place drained counts become user-visible text. Generic by design —
// content is E2E encrypted, so the notification only ever says "N new pix/messages".

enum PushNotifier {
    static func post(_ counts: ProcessedCounts) {
        let total = counts.pixCount + counts.messageCount
        guard total > 0 else { return }

        let text: String
        if counts.pixCount > 0 && counts.messageCount > 0 {
            text = "\(total) new \(plural(total, "item"))"
        } else if counts.pixCount > 0 {
            text = "\(counts.pixCount) new \(plural(counts.pixCount, "pix"))"
        } else {
            text = "\(counts.messageCount) new \(plural(counts.messageCount, "message"))"
        }

        let content = UNMutableNotificationContent()
        content.title = "Obscura"
        content.body = text
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "obscura_messages",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
        NSLog("[ObscuraApp] PushNotifier: posted \"\(text)\"")
    }

    // "pix" is invariant in the plural; pluralize the rest.
    private static func plural(_ n: Int, _ word: String) -> String {
        (word == "pix" || n == 1) ? word : word + "s"
    }
}

// MARK: - App Delegate
//
// Owns the OS push lifecycle. With Firebase present it hands the APNs token to FCM
// and registers the FCM token; without it (e.g. local simctl-push testing) it
// registers the raw APNs token directly. Either way the silent-push handler drains
// via the kit and posts a generic notification.

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if canImport(FirebaseCore)
        FirebaseApp.configure()
        #endif

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, _ in
            NSLog("[ObscuraApp] notification auth granted=\(granted)")
        }

        #if canImport(FirebaseMessaging)
        Messaging.messaging().delegate = self
        #endif

        application.registerForRemoteNotifications()

        #if DEBUG
        // Simulator stand-in for a real silent push. The iOS Simulator does not deliver
        // background/content-available pushes, so this runs the IDENTICAL
        // PushCoordinator.handleSilentPush() path (drain + classify + notify) that real
        // FCM triggers on a device. Mirrors Android's debug TestPushReceiver.
        //   scripts/testpush.sh fire
        if ProcessInfo.processInfo.environment["OBSCURA_TEST_PUSH"] == "1" {
            NSLog("[ObscuraApp] OBSCURA_TEST_PUSH set — simulating silent push wake")
            Task { @MainActor in
                // Give session restore + connect a moment to settle.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await PushCoordinator.shared.handleSilentPush()
            }
        }
        #endif

        return true
    }

    // APNs device token arrived.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        #if canImport(FirebaseMessaging)
        // FCM is canon: feed APNs token to Firebase; the FCM registration token
        // comes back via MessagingDelegate and is what we register with the server.
        Messaging.messaging().apnsToken = deviceToken
        #else
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        NSLog("[ObscuraApp] APNs token: \(hex.prefix(12))…")
        Task { @MainActor in PushCoordinator.shared.onPushToken(hex) }
        #endif
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("[ObscuraApp] remote registration failed: \(error)")
    }

    // Silent / data push — background wake. Drain then report new data.
    // Use the explicit completion-handler selector: UIKit reliably routes silent
    // (content-available) pushes here.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NSLog("[ObscuraApp] didReceiveRemoteNotification (silent push)")
        Task { @MainActor in
            await PushCoordinator.shared.handleSilentPush()
            completionHandler(.newData)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    // Surface our generic banner even in the foreground (handy during testing).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        NSLog("[ObscuraApp] willPresent notification (foreground)")
        return [.banner, .sound]
    }
}

#if canImport(FirebaseMessaging)
extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        NSLog("[ObscuraApp] FCM token: \(fcmToken.prefix(12))…")
        Task { @MainActor in PushCoordinator.shared.onPushToken(fcmToken) }
    }
}
#endif
