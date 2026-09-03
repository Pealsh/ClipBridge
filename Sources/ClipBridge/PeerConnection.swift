import Foundation
import Network
import CryptoKit

protocol PeerConnectionDelegate: AnyObject {
    /// 未ペアリングの相手。SAS を表示してユーザーに照合してもらう。
    func peerConnection(_ c: PeerConnection,
                        requiresPairing sas: String,
                        peerName: String,
                        completion: @escaping (Bool) -> Void)
    func peerConnectionDidBecomeReady(_ c: PeerConnection)
    func peerConnection(_ c: PeerConnection, didReceive content: ClipContent)
    func peerConnection(_ c: PeerConnection, didReceiveNotify message: String, image: Data?)
    /// 相手から pull 要求。今のローカルクリップボードを返す（nil なら空）。
    func peerConnectionClipboardForPull(_ c: PeerConnection) -> ClipContent?
    func peerConnection(_ c: PeerConnection, didCloseWith error: Error?)
}

/// 1 台の相手との暗号化済み接続。
final class PeerConnection {

    enum State { case handshaking, pairing, ready, closed }

    weak var delegate: PeerConnectionDelegate?

    let isInitiator: Bool

    /// 発信時に Bonjour から分かっている相手の ID（ハンドシェイク前の再試行制御に使う）
    let expectedPeerID: String?

    // state / peerID / peerName は別スレッドからも読まれるのでロックで守る
    private let stateLock = NSLock()
    private var _state: State = .handshaking
    private var _peerID = ""
    private var _peerName = "unknown"

    private(set) var state: State {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _state }
        set { stateLock.lock(); _state = newValue; stateLock.unlock() }
    }
    private(set) var peerID: String {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _peerID }
        set { stateLock.lock(); _peerID = newValue; stateLock.unlock() }
    }
    private(set) var peerName: String {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _peerName }
        set { stateLock.lock(); _peerName = newValue; stateLock.unlock() }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "clipbridge.conn")
    private var buffer = Data()
    private var crypto: CryptoBox?
    private let localNonce = CryptoBox.randomNonce()

    /// ペアリング時、双方の OK が揃うまで信頼を確定しない
    private var localPairApproved = false
    private var remotePairApproved = false
    private var pendingPeerPublicKey: Data?

    private var idleTimer: DispatchSourceTimer?

    init(connection: NWConnection, isInitiator: Bool, expectedPeerID: String? = nil) {
        self.connection = connection
        self.isInitiator = isInitiator
        self.expectedPeerID = expectedPeerID
    }

    convenience init(to endpoint: NWEndpoint, expectedPeerID: String) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        self.init(connection: NWConnection(to: endpoint, using: params),
                  isInitiator: true,
                  expectedPeerID: expectedPeerID)
    }

    // MARK: - ライフサイクル

    func start() {
        connection.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.sendHello()
                self.receiveLoop()
            case .failed(let err):
                self.close(error: err)
            case .cancelled:
                self.close(error: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        startHandshakeTimeout()
    }

    func close(error: Error? = nil) {
        queue.async { [weak self] in
            guard let self, self.state != .closed else { return }
            self.state = .closed
            self.idleTimer?.cancel(); self.idleTimer = nil
            self.connection.cancel()
            DispatchQueue.main.async {
                self.delegate?.peerConnection(self, didCloseWith: error)
            }
        }
    }

    private func startHandshakeTimeout() {
        queue.async { [weak self] in
            guard let self else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            // ペアリングのダイアログを人が読む時間も含めて余裕を持たせる
            t.schedule(deadline: .now() + 180)
            t.setEventHandler { [weak self] in
                guard let self, self.state != .ready, self.state != .closed else { return }
                self.close(error: ProtocolError.badHandshake("タイムアウト"))
            }
            t.resume()
            self.idleTimer = t
        }
    }

    // MARK: - 送信

    /// クリップボードの内容を相手に送る
    func send(_ content: ClipContent) {
        guard state == .ready else { return }
        do {
            try sendEncrypted(content.toEnvelope())
        } catch {
            Log.error("送信失敗:", error)
        }
    }

    /// 相手の今のクリップボードを要求する
    func requestPull() {
        guard state == .ready else { return }
        try? sendEncrypted(Envelope(header: MessageHeader(type: "pull"), body: Data()))
    }

    /// 相手にメッセージを送る（画面中央に表示される）
    func sendNotify(_ message: String, image: Data? = nil) {
        guard state == .ready else { return }
        var h = MessageHeader(type: "notify")
        h.message = message
        if let image = image {
            h.hasImage = true
            h.imageFormat = "png"
            try? sendEncrypted(Envelope(header: h, body: image))
        } else {
            try? sendEncrypted(Envelope(header: h, body: Data()))
        }
    }

    private func sendEncrypted(_ env: Envelope) throws {
        guard let crypto else { throw ProtocolError.badHandshake("鍵未確立") }
        let plain = try env.serialize()
        guard plain.count <= Const.maxMessageBytes else { throw ProtocolError.tooLarge }
        let sealed = try crypto.seal(plain)
        rawSend(Frame.encode(sealed))
    }

    private func rawSend(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] err in
            if let err { self?.close(error: err) }
        })
    }

    private func sendHello() {
        let hello = Hello(
            version: Const.protocolVersion,
            deviceID: Identity.shared.deviceID,
            deviceName: Identity.shared.deviceName,
            publicKey: Identity.shared.publicKeyData.base64EncodedString(),
            nonce: localNonce.base64EncodedString())
        guard let data = try? JSONEncoder().encode(hello) else { return }
        rawSend(Frame.encode(data))
    }

    // MARK: - 受信

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error { self.close(error: error); return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                do {
                    while let frame = try Frame.decode(from: &self.buffer) {
                        try self.handle(frame: frame)
                    }
                } catch {
                    self.close(error: error); return
                }
            }

            if isComplete { self.close(error: nil); return }
            guard self.state != .closed else { return }
            self.receiveLoop()
        }
    }

    private func handle(frame: Data) throws {
        if crypto == nil {
            try handleHello(frame)
            return
        }
        let plain = try crypto!.open(frame)
        let env = try Envelope.parse(plain)
        try handle(envelope: env)
    }

    private func handleHello(_ frame: Data) throws {
        let hello = try JSONDecoder().decode(Hello.self, from: frame)

        guard hello.version == Const.protocolVersion else {
            throw ProtocolError.badHandshake("バージョン不一致 (相手: \(hello.version))")
        }
        guard let pubData = Data(base64Encoded: hello.publicKey),
              let remoteNonce = Data(base64Encoded: hello.nonce),
              remoteNonce.count == 32,
              let remotePub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubData)
        else {
            throw ProtocolError.badHandshake("鍵の形式が不正")
        }
        // deviceID は公開鍵から決まる。食い違うなら詐称。
        guard Identity.fingerprint(of: pubData) == hello.deviceID else {
            throw ProtocolError.badHandshake("端末IDと公開鍵が一致しません")
        }
        guard hello.deviceID != Identity.shared.deviceID else {
            throw ProtocolError.badHandshake("自分自身への接続")
        }
        if let expected = expectedPeerID, expected != hello.deviceID {
            throw ProtocolError.badHandshake("接続先の端末IDが想定と違います")
        }

        peerID = hello.deviceID
        peerName = hello.deviceName.isEmpty ? "Mac" : String(hello.deviceName.prefix(64))
        pendingPeerPublicKey = pubData

        crypto = try CryptoBox(
            localPrivate: Identity.shared.privateKey,
            remotePublic: remotePub,
            localNonce: localNonce,
            remoteNonce: remoteNonce,
            localIsInitiator: isInitiator)

        if TrustStore.shared.isTrusted(deviceID: peerID, publicKey: pubData) {
            becomeReady()
        } else {
            state = .pairing
            let sas = crypto!.sas
            let name = peerName
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.peerConnection(self, requiresPairing: sas, peerName: name) { approved in
                    self.queue.async { self.finishLocalPairing(approved: approved) }
                }
            }
        }
    }

    private func finishLocalPairing(approved: Bool) {
        guard state == .pairing else { return }
        guard approved else {
            var h = MessageHeader(type: "pairack"); h.ok = false
            try? sendEncrypted(Envelope(header: h, body: Data()))
            close(error: ProtocolError.untrustedPeer)
            return
        }
        localPairApproved = true
        var h = MessageHeader(type: "pairack"); h.ok = true
        try? sendEncrypted(Envelope(header: h, body: Data()))
        maybeCompletePairing()
    }

    private func maybeCompletePairing() {
        guard state == .pairing, localPairApproved, remotePairApproved,
              let pub = pendingPeerPublicKey else { return }
        TrustStore.shared.trust(deviceID: peerID, publicKey: pub, name: peerName)
        Log.info("ペアリング完了:", peerName, peerID)
        becomeReady()
    }

    private func becomeReady() {
        state = .ready
        idleTimer?.cancel(); idleTimer = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.peerConnectionDidBecomeReady(self)
        }
    }

    private func handle(envelope env: Envelope) throws {
        switch env.header.type {

        case "pairack":
            guard state == .pairing else { return }
            if env.header.ok == true {
                remotePairApproved = true
                maybeCompletePairing()
            } else {
                close(error: ProtocolError.untrustedPeer)
            }

        case "clip":
            guard state == .ready else { throw ProtocolError.untrustedPeer }
            let content = try ClipContent.from(env)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.peerConnection(self, didReceive: content)
            }

        case "pull":
            guard state == .ready else { throw ProtocolError.untrustedPeer }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let content = self.delegate?.peerConnectionClipboardForPull(self) {
                    self.queue.async { try? self.sendEncrypted(content.toEnvelope()) }
                } else {
                    var h = MessageHeader(type: "ack")
                    h.ok = false; h.note = "相手のクリップボードは空です"
                    self.queue.async { try? self.sendEncrypted(Envelope(header: h, body: Data())) }
                }
            }

        case "ack":
            if env.header.ok == false, let note = env.header.note {
                Log.info("相手からの通知:", note)
                Notifier.show(title: "ClipBridge", body: note)
            }

        case "notify":
            guard state == .ready else { throw ProtocolError.untrustedPeer }
            let message = env.header.message ?? ""
            let imageData: Data? = (env.header.hasImage == true && !env.body.isEmpty) ? env.body : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.peerConnection(self, didReceiveNotify: message, image: imageData)
            }

        case "ping":
            break

        default:
            break
        }
    }
}
