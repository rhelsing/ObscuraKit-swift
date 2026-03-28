import Foundation
import GRDB

/// Bridges GRDB ValueObservation to Swift AsyncSequence.
/// Views subscribe once — GRDB pushes changes on every write.
///
/// Usage in SwiftUI:
/// ```swift
/// struct FriendListView: View {
///     let client: ObscuraClient
///     @State private var friends: [Friend] = []
///
///     var body: some View {
///         List(friends, id: \.userId) { friend in
///             Text(friend.username)
///         }
///         .task {
///             for await updated in client.friends.observeAccepted().values {
///                 friends = updated
///             }
///         }
///     }
/// }
/// ```
public struct AsyncValueObservation<T: Sendable> {
    private let observation: ValueObservation<ValueReducers.Fetch<T>>
    private let db: DatabaseQueue

    init(observation: ValueObservation<ValueReducers.Fetch<T>>, in db: DatabaseQueue) {
        self.observation = observation
        self.db = db
    }

    /// AsyncSequence of observed values. Emits initial value immediately,
    /// then emits again on every database change affecting the query.
    public var values: AsyncStream<T> {
        AsyncStream { continuation in
            let cancellable = observation.start(in: db, onError: { error in
                // Log but don't crash — observation continues
                print("[Observation] error: \(error)")
            }, onChange: { value in
                continuation.yield(value)
            })

            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }
}
