import Foundation

// MARK: - Auth

public struct AuthResponse: Decodable {
    public let token: String
    public let refreshToken: String?
    public let expiresAt: Double?
    public let deviceId: String?
}

// MARK: - Devices

public struct DeviceResponse: Decodable {
    public let deviceId: String
    public let name: String
    public let createdAt: String?
}

public struct SignedPreKeyUpload: Encodable {
    public let keyId: Int
    public let publicKey: String
    public let signature: String
}

public struct PreKeyUpload: Encodable {
    public let keyId: Int
    public let publicKey: String
}

// MARK: - PreKey Bundles

public struct PreKeyBundleResponse: Decodable {
    public let deviceId: String
    public let registrationId: Int
    public let identityKey: String
    public let signedPreKey: SignedPreKeyData
    public let oneTimePreKey: PreKeyData?

    public struct SignedPreKeyData: Decodable {
        public let keyId: Int
        public let publicKey: String
        public let signature: String
    }

    public struct PreKeyData: Decodable {
        public let keyId: Int
        public let publicKey: String
    }
}

// MARK: - Attachments

public struct AttachmentResponse: Decodable {
    public let id: String
    public let expiresAt: Double?
}

// MARK: - Gateway

public struct GatewayTicketResponse: Decodable {
    public let ticket: String
}
