import Foundation
import CryptoKit
import Security

/// 1 本の接続に対する暗号状態。
///
/// - 鍵交換: 双方の恒久 Curve25519 公開鍵で ECDH
/// - 鍵導出: HKDF-SHA256（salt = 双方のランダム nonce, info = 方向つき）
/// - 暗号化: ChaCha20-Poly1305（AEAD）
///
/// 方向ごとに別鍵を使うので、送信側・受信側でカウンタ nonce が衝突しない。
/// セッション鍵は接続ごとの nonce に依存するため、同じ 2 台でも毎回異なる。
final class CryptoBox {

    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private let lock = NSLock()

    /// 目視照合用の 6 桁コード（Short Authentication String）
    let sas: String

    /// - Parameters:
    ///   - localPrivate: 自分の恒久秘密鍵
    ///   - remotePublic: 相手の恒久公開鍵
    ///   - localNonce:  自分が送ったランダム 32 バイト
    ///   - remoteNonce: 相手から受け取ったランダム 32 バイト
    ///   - localIsInitiator: 接続を開始した側かどうか（方向鍵の割り当てに使う）
    init(localPrivate: Curve25519.KeyAgreement.PrivateKey,
         remotePublic: Curve25519.KeyAgreement.PublicKey,
         localNonce: Data,
         remoteNonce: Data,
         localIsInitiator: Bool) throws {

        let shared = try localPrivate.sharedSecretFromKeyAgreement(with: remotePublic)

        // salt は双方が同じ順序で並べる必要があるので、バイト列としてソートする
        let salts = [localNonce, remoteNonce].sorted { $0.lexicographicallyPrecedes($1) }
        let salt = salts[0] + salts[1]

        let keyItoR = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt,
            sharedInfo: Data("clipbridge/v1/initiator->responder".utf8),
            outputByteCount: 32)
        let keyRtoI = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt,
            sharedInfo: Data("clipbridge/v1/responder->initiator".utf8),
            outputByteCount: 32)

        if localIsInitiator {
            sendKey = keyItoR
            recvKey = keyRtoI
        } else {
            sendKey = keyRtoI
            recvKey = keyItoR
        }

        // SAS: 公開鍵と nonce の両方を混ぜる。中間者は 100 万分の 1 でしか一致させられない。
        let pubs = [localPrivate.publicKey.rawRepresentation, remotePublic.rawRepresentation]
            .sorted { $0.lexicographicallyPrecedes($1) }
        var sasInput = Data("clipbridge/v1/sas".utf8)
        sasInput += pubs[0]; sasInput += pubs[1]
        sasInput += salt
        let digest = Array(SHA256.hash(data: sasInput))
        let n = (UInt32(digest[0]) << 24) | (UInt32(digest[1]) << 16)
              | (UInt32(digest[2]) << 8)  |  UInt32(digest[3])
        sas = String(format: "%06u", n % 1_000_000)
    }

    func seal(_ plaintext: Data) throws -> Data {
        lock.lock()
        let counter = sendCounter
        sendCounter &+= 1
        lock.unlock()

        let nonce = try ChaChaPoly.Nonce(data: Self.nonceBytes(counter))
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce)
        // カウンタを前置して送る（受信側の順序ずれに強くするため）
        return Self.nonceBytes(counter) + box.ciphertext + box.tag
    }

    func open(_ wire: Data) throws -> Data {
        guard wire.count > 12 + 16 else { throw CryptoError.malformed }
        let nonceData = wire.prefix(12)
        let rest = wire.dropFirst(12)
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let ciphertext = rest.dropLast(16)
        let tag = rest.suffix(16)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try ChaChaPoly.open(box, using: recvKey)
    }

    private static func nonceBytes(_ counter: UInt64) -> Data {
        var d = Data(repeating: 0, count: 4)   // 上位 4 バイトは 0 固定
        var be = counter.bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        return d                                // 合計 12 バイト
    }

    enum CryptoError: Error { case malformed }

    static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}
