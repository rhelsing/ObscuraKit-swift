import Foundation

/// Protocol for session persistence. Kit calls this internally —
/// the app provides the implementation (UserDefaults, Keychain, etc.)
public protocol SessionStorage: AnyObject {
    func save(_ data: [String: Any])
    func load() -> [String: Any]?
    func clear()
}

/// Default implementation using UserDefaults.
public class UserDefaultsSessionStorage: SessionStorage {
    private let key: String
    private let defaults: UserDefaults

    public init(key: String = "ObscuraSession", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    public func save(_ data: [String: Any]) {
        defaults.set(data, forKey: key)
    }

    public func load() -> [String: Any]? {
        defaults.dictionary(forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
