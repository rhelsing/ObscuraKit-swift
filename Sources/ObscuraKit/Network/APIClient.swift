import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP API Client for Obscura Server
/// Pure functional — mirrors src/v2/api/client.js
public actor APIClient {
    public let baseURL: String
    private var token: String?

    public init(baseURL: String) {
        precondition(baseURL.hasPrefix("https://"), "API URL must use HTTPS")
        self.baseURL = baseURL
    }

    // MARK: - Token Management

    public func setToken(_ t: String) { token = t }
    public func getToken() -> String? { token }
    public func clearToken() { token = nil }

    /// Decode JWT payload (base64url middle segment)
    /// Nonisolated static helper — works without actor context
    public nonisolated static func decodeJWT(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Instance version that uses current token
    public func decodeToken(_ t: String? = nil) -> [String: Any]? {
        guard let jwt = t ?? token else { return nil }
        return Self.decodeJWT(jwt)
    }

    public nonisolated static func extractUserId(_ jwt: String) -> String? {
        guard let payload = decodeJWT(jwt) else { return nil }
        return (payload["sub"] as? String)
            ?? (payload["user_id"] as? String)
            ?? (payload["userId"] as? String)
            ?? (payload["id"] as? String)
    }

    public nonisolated static func extractDeviceId(_ jwt: String) -> String? {
        guard let payload = decodeJWT(jwt) else { return nil }
        return (payload["device_id"] as? String)
            ?? (payload["deviceId"] as? String)
    }

    public func getUserId(_ t: String? = nil) -> String? {
        guard let jwt = t ?? token else { return nil }
        return Self.extractUserId(jwt)
    }

    public func getDeviceId(_ t: String? = nil) -> String? {
        guard let jwt = t ?? token else { return nil }
        return Self.extractDeviceId(jwt)
    }

    // MARK: - Generic Request

    public struct APIError: LocalizedError {
        public let status: Int
        public let body: String

        public var errorDescription: String? {
            "HTTP \(status): \(body)"
        }
    }

    private func request(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String = "application/json",
        auth: Bool = true,
        extraHeaders: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw APIError(status: 0, body: "Invalid URL: \(baseURL)\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        if auth, let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError(status: 0, body: "Not HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw APIError(status: httpResponse.statusCode, body: bodyStr)
        }

        return (data, httpResponse)
    }

    private func jsonRequest(_ path: String, method: String = "GET", body: Any? = nil, auth: Bool = true) async throws -> Any {
        var bodyData: Data? = nil
        if let body = body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await request(path, method: method, body: bodyData, auth: auth)
        if data.isEmpty { return [:] as [String: Any] }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Auth

    public func registerUser(_ username: String, _ password: String) async throws -> [String: Any] {
        let result = try await jsonRequest("/v1/users", method: "POST", body: [
            "username": username,
            "password": password,
        ], auth: false)
        return result as? [String: Any] ?? [:]
    }

    public func loginWithDevice(_ username: String, _ password: String, deviceId: String? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["username": username, "password": password]
        if let deviceId = deviceId { body["deviceId"] = deviceId }
        let result = try await jsonRequest("/v1/sessions", method: "POST", body: body, auth: false)
        return result as? [String: Any] ?? [:]
    }

    public func refreshSession(_ refreshToken: String) async throws -> [String: Any] {
        let result = try await jsonRequest("/v1/sessions/refresh", method: "POST", body: [
            "refreshToken": refreshToken,
        ], auth: false)
        return result as? [String: Any] ?? [:]
    }

    public func logout(_ refreshToken: String) async throws {
        _ = try await jsonRequest("/v1/sessions", method: "DELETE", body: [
            "refreshToken": refreshToken,
        ])
    }

    // MARK: - Devices

    public func provisionDevice(name: String, identityKey: String, registrationId: Int, signedPreKey: [String: Any], oneTimePreKeys: [[String: Any]]) async throws -> [String: Any] {
        let result = try await jsonRequest("/v1/devices", method: "POST", body: [
            "name": name,
            "identityKey": identityKey,
            "registrationId": registrationId,
            "signedPreKey": signedPreKey,
            "oneTimePreKeys": oneTimePreKeys,
        ])
        return result as? [String: Any] ?? [:]
    }

    public func listDevices() async throws -> Any {
        return try await jsonRequest("/v1/devices")
    }

    public func getDevice(_ deviceId: String) async throws -> [String: Any] {
        let result = try await jsonRequest("/v1/devices/\(deviceId)")
        return result as? [String: Any] ?? [:]
    }

    public func updateDevice(_ deviceId: String, name: String) async throws -> [String: Any] {
        let result = try await jsonRequest("/v1/devices/\(deviceId)", method: "PUT", body: [
            "name": name,
        ])
        return result as? [String: Any] ?? [:]
    }

    public func deleteDevice(_ deviceId: String) async throws {
        _ = try await jsonRequest("/v1/devices/\(deviceId)", method: "DELETE")
    }

    // MARK: - Keys

    public func uploadDeviceKeys(identityKey: String, registrationId: Int, signedPreKey: [String: Any], oneTimePreKeys: [[String: Any]]) async throws {
        _ = try await jsonRequest("/v1/devices/keys", method: "POST", body: [
            "identityKey": identityKey,
            "registrationId": registrationId,
            "signedPreKey": signedPreKey,
            "oneTimePreKeys": oneTimePreKeys,
        ])
    }

    public func fetchPreKeyBundles(_ userId: String) async throws -> [[String: Any]] {
        let result = try await jsonRequest("/v1/users/\(userId)")
        return result as? [[String: Any]] ?? []
    }

    // MARK: - Messaging (Protobuf)

    public func sendMessage(_ protobufData: Data) async throws {
        let idempotencyKey = UUID().uuidString
        _ = try await request("/v1/messages", method: "POST", body: protobufData,
                              contentType: "application/x-protobuf",
                              extraHeaders: ["Idempotency-Key": idempotencyKey])
    }

    // MARK: - Attachments

    public func uploadAttachment(_ blob: Data) async throws -> [String: Any] {
        let (data, _) = try await request("/v1/attachments", method: "POST", body: blob,
                                          contentType: "application/octet-stream")
        let result = try JSONSerialization.jsonObject(with: data)
        return result as? [String: Any] ?? [:]
    }

    public func fetchAttachment(_ id: String) async throws -> Data {
        let (data, _) = try await request("/v1/attachments/\(id)")
        return data
    }

    // MARK: - Gateway

    public func fetchGatewayTicket() async throws -> String {
        let result = try await jsonRequest("/v1/gateway/ticket", method: "POST")
        guard let dict = result as? [String: Any], let ticket = dict["ticket"] as? String else {
            throw APIError(status: 0, body: "No ticket in response")
        }
        return ticket
    }

    public func getGatewayURL(ticket: String) -> URL? {
        let wsBase = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        return URL(string: "\(wsBase)/v1/gateway?ticket=\(ticket)")
    }

    // MARK: - Backup

    public func uploadBackup(_ data: Data, etag: String? = nil) async throws -> String? {
        var headers: [String: String] = [:]
        if let etag = etag {
            headers["If-Match"] = etag
        } else {
            headers["If-None-Match"] = "*"
        }
        let (_, response) = try await request("/v1/backup", method: "POST", body: data,
                                               contentType: "application/octet-stream",
                                               extraHeaders: headers)
        return response.value(forHTTPHeaderField: "ETag")
    }

    public func downloadBackup(etag: String? = nil) async throws -> (data: Data, etag: String?)? {
        var headers: [String: String] = [:]
        if let etag = etag { headers["If-None-Match"] = etag }

        do {
            let (data, response) = try await request("/v1/backup", extraHeaders: headers)
            return (data: data, etag: response.value(forHTTPHeaderField: "ETag"))
        } catch let error as APIError where error.status == 304 || error.status == 404 {
            return nil
        }
    }

    public func checkBackup() async throws -> (exists: Bool, etag: String?, size: Int?) {
        do {
            let (_, response) = try await request("/v1/backup", method: "HEAD")
            let size = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init)
            return (exists: true, etag: response.value(forHTTPHeaderField: "ETag"), size: size)
        } catch let error as APIError where error.status == 404 {
            return (exists: false, etag: nil, size: nil)
        }
    }

    // MARK: - Push

    public func registerPushToken(_ token: String, type: String = "apns") async throws {
        _ = try await jsonRequest("/v1/push-tokens", method: "PUT", body: [
            "token": token,
            "type": type,
        ])
    }
}
