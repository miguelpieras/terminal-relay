import Foundation
import NIOSSH
import Security

enum SSHIdentityStoreError: LocalizedError {
    case randomGenerationFailed(OSStatus)
    case keychain(OSStatus)
    case invalidPrivateKey

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            "Could not generate the SSH key (Security status \(status))."
        case .keychain(let status):
            "Could not access the SSH key in Keychain (Security status \(status))."
        case .invalidPrivateKey:
            "The SSH private key stored in Keychain is invalid."
        }
    }
}

final class SSHIdentityStore {
    private let service = "com.mpieras.TerminalRelay.iOS.ssh-identity"
    private let account = "worker-ed25519-v1"

    func loadOrCreatePrivateKey() throws -> NIOSSHPrivateKey {
        if let material = try loadPrivateMaterial() {
            return try makePrivateKey(from: material)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw SSHIdentityStoreError.randomGenerationFailed(randomStatus)
        }

        let material = Data(bytes)
        let privateKey = try makePrivateKey(from: material)
        do {
            try storePrivateMaterial(material)
            return privateKey
        } catch SSHIdentityStoreError.keychain(errSecDuplicateItem) {
            guard let existing = try loadPrivateMaterial() else {
                throw SSHIdentityStoreError.keychain(errSecItemNotFound)
            }
            return try makePrivateKey(from: existing)
        }
    }

    func publicKeyForAuthorizedKeys() throws -> String {
        let publicKey = try loadOrCreatePrivateKey().publicKey
        return "\(String(openSSHPublicKey: publicKey)) terminal-relay-ios"
    }

    private func makePrivateKey(from material: Data) throws -> NIOSSHPrivateKey {
        do {
            return try NIOSSHPrivateKey(ed25519Key: .init(rawRepresentation: material))
        } catch {
            throw SSHIdentityStoreError.invalidPrivateKey
        }
    }

    private func loadPrivateMaterial() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SSHIdentityStoreError.invalidPrivateKey
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw SSHIdentityStoreError.keychain(status)
        }
    }

    private func storePrivateMaterial(_ material: Data) throws {
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: material,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SSHIdentityStoreError.keychain(status)
        }
    }
}
