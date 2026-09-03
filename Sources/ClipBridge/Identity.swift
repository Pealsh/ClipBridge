import Foundation
import CryptoKit
import Security

/// この Mac の恒久的な身元。
///
/// Curve25519 の鍵ペアを 1 つだけ生成して Keychain に保管する。
/// 公開鍵の SHA-256 先頭 8 バイトを deviceID として使うので、
/// ID を偽装すると鍵も一致しなくなる（= ID 自体が公開鍵にひも付く）。
final class Identity {

    static let shared = Identity()

    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let publicKeyData: Data
    let deviceID: String
    var deviceName: String {
        get { UserDefaults.standard.string(forKey: "deviceName") ?? Host.current().localizedName ?? "Mac" }
        set { UserDefaults.standard.set(newValue, forKey: "deviceName") }
    }

    private init() {
        if let raw = Keychain.read(account: "identity-key"),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            privateKey = key
        } else {
            let key = Curve25519.KeyAgreement.PrivateKey()
            Keychain.write(account: "identity-key", data: key.rawRepresentation)
            privateKey = key
            Log.info("新しい端末IDを生成しました")
        }
        publicKeyData = privateKey.publicKey.rawRepresentation
        deviceID = Identity.fingerprint(of: publicKeyData)
    }

    /// 公開鍵 → 16 桁の16進 ID
    static func fingerprint(of publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Keychain

enum Keychain {
    static func write(account: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Const.bundleID,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Log.error("Keychain 書き込み失敗 status=\(status)")
        }
    }

    static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Const.bundleID,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

// MARK: - 信頼済み端末

struct TrustedPeer: Codable, Equatable {
    let deviceID: String
    let publicKeyBase64: String
    var name: String
    var pairedAt: Date

    var publicKeyData: Data? { Data(base64Encoded: publicKeyBase64) }
}

/// ペアリング済み端末の一覧。公開鍵を保存し、以後は自動で信頼する（TOFU）。
final class TrustStore {

    static let shared = TrustStore()

    private var peers: [String: TrustedPeer] = [:]
    private let queue = DispatchQueue(label: "clipbridge.truststore")
    private var fileURL: URL { AppPaths.supportDirectory.appendingPathComponent("trusted.json") }

    private init() { load() }

    var all: [TrustedPeer] {
        queue.sync { Array(peers.values).sorted { $0.name < $1.name } }
    }

    func peer(id: String) -> TrustedPeer? {
        queue.sync { peers[id] }
    }

    func isTrusted(deviceID: String, publicKey: Data) -> Bool {
        queue.sync {
            guard let p = peers[deviceID] else { return false }
            return p.publicKeyData == publicKey
        }
    }

    func trust(deviceID: String, publicKey: Data, name: String) {
        queue.sync {
            peers[deviceID] = TrustedPeer(
                deviceID: deviceID,
                publicKeyBase64: publicKey.base64EncodedString(),
                name: name,
                pairedAt: Date())
            persistLocked()
        }
    }

    func forget(deviceID: String) {
        queue.sync {
            peers.removeValue(forKey: deviceID)
            persistLocked()
        }
    }

    func forgetAll() {
        queue.sync {
            peers.removeAll()
            persistLocked()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([TrustedPeer].self, from: data)
        else { return }
        peers = Dictionary(uniqueKeysWithValues: list.map { ($0.deviceID, $0) })
    }

    private func persistLocked() {
        AppPaths.ensureSupportDirectory()
        let list = Array(peers.values)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
