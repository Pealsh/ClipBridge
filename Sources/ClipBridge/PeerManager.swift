import Foundation
import Network

protocol PeerManagerDelegate: AnyObject {
    func peerManagerDidChangePeers(_ m: PeerManager)
    func peerManager(_ m: PeerManager, didReceive content: ClipContent, from name: String)
    func peerManager(_ m: PeerManager, didReceiveNotify message: String, attachment: NotifyAttachment, from name: String)
    func peerManager(_ m: PeerManager,
                     requiresPairing sas: String,
                     peerName: String,
                     completion: @escaping (Bool) -> Void)
    func peerManagerClipboardForPull(_ m: PeerManager) -> ClipContent?
    func peerManager(_ m: PeerManager, statusDidChange text: String)
}

/// Bonjour で同じ Wi-Fi 上の ClipBridge を探し、接続を張り、暗号化して送受信する。
///
/// 二重接続を避けるため「端末IDが小さい側からだけ発信する」という単純な規則を使う。
final class PeerManager {

    weak var delegate: PeerManagerDelegate?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "clipbridge.manager")

    /// deviceID -> 確立済みの接続
    private var connections: [String: PeerConnection] = [:]
    /// ハンドシェイク中の接続。ここで保持しないと即座に解放されてしまう。
    /// 追加は同期的に行う必要があるので、専用ロックで守る。
    private var pending: [PeerConnection] = []
    private let pendingLock = NSLock()

    private func addPending(_ c: PeerConnection) {
        pendingLock.lock(); pending.append(c); pendingLock.unlock()
    }
    private func removePending(_ c: PeerConnection) {
        pendingLock.lock(); pending.removeAll { $0 === c }; pendingLock.unlock()
    }
    private func drainPending() -> [PeerConnection] {
        pendingLock.lock(); defer { pendingLock.unlock() }
        let all = pending; pending.removeAll(); return all
    }
    /// 発見済みだがまだ接続していない相手 deviceID -> endpoint
    private var discovered: [String: (endpoint: NWEndpoint, name: String)] = [:]
    /// 発信中で結果待ちの deviceID
    private var dialing: Set<String> = []

    private var retryTimer: Timer?

    /// メインスレッドから呼ぶ想定（内部辞書は専用キューで保護する）
    var readyPeers: [(id: String, name: String)] {
        queue.sync {
            connections.values
                .filter { $0.state == .ready }
                .map { (id: $0.peerID, name: $0.peerName) }
                .sorted { $0.name < $1.name }
        }
    }

    var isRunning: Bool { listener != nil }

    // MARK: - 開始 / 停止

    func start() {
        startListener()
        startBrowser()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.queue.async { self?.dialPendingPeers() }
        }
    }

    func stop() {
        retryTimer?.invalidate(); retryTimer = nil
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        for c in drainPending() { c.close() }
        queue.async {
            for c in self.connections.values { c.close() }
            self.connections.removeAll()
            self.discovered.removeAll()
            self.dialing.removeAll()
        }
        notifyPeersChanged()
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
    }

    // MARK: - Listener（相手からの接続を受ける）

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let l = try NWListener(using: params)

            var txt = NWTXTRecord()
            txt["id"] = Identity.shared.deviceID
            txt["name"] = Identity.shared.deviceName
            txt["v"] = String(Const.protocolVersion)

            // サービス名は Bonjour 上で一意である必要がある
            let serviceName = "\(Identity.shared.deviceName)-\(Identity.shared.deviceID.prefix(6))"
            l.service = NWListener.Service(
                name: String(serviceName.prefix(60)),
                type: Const.serviceType,
                domain: nil,
                txtRecord: txt)

            l.newConnectionHandler = { [weak self] nwConn in
                let conn = PeerConnection(connection: nwConn, isInitiator: false)
                self?.attach(conn)
            }

            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    self?.report("待受中")
                case .failed(let e):
                    Log.error("listener failed:", e)
                    self?.report("待受エラー: \(e.localizedDescription)")
                    // ポート衝突などは作り直しで復帰することが多い
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.restartListenerOnly() }
                default:
                    break
                }
            }

            l.start(queue: queue)
            listener = l
        } catch {
            Log.error("listener 作成失敗:", error)
            report("待受を開始できません: \(error.localizedDescription)")
        }
    }

    private func restartListenerOnly() {
        listener?.cancel(); listener = nil
        startListener()
    }

    // MARK: - Browser（相手を探す）

    private func startBrowser() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let b = NWBrowser(
            for: .bonjourWithTXTRecord(type: Const.serviceType, domain: Const.serviceDomain),
            using: params)

        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.queue.async { self?.handle(results: results) }
        }
        b.stateUpdateHandler = { st in
            if case .failed(let e) = st { Log.error("browser failed:", e) }
        }
        b.start(queue: queue)
        browser = b
    }

    private func handle(results: Set<NWBrowser.Result>) {
        var found: [String: (endpoint: NWEndpoint, name: String)] = [:]

        for r in results {
            guard case .bonjour(let txt) = r.metadata else { continue }
            guard let id = txt["id"], id != Identity.shared.deviceID else { continue }
            let name = txt["name"] ?? "Mac"
            found[id] = (endpoint: r.endpoint, name: name)
        }

        discovered = found
        dialPendingPeers()
        notifyPeersChanged()
    }

    /// 未接続かつ「自分のIDのほうが小さい」相手にだけ発信する
    private func dialPendingPeers() {
        for (id, info) in discovered {
            guard connections[id] == nil, !dialing.contains(id) else { continue }
            guard Identity.shared.deviceID < id else { continue }   // 同時接続の防止
            dialing.insert(id)
            let conn = PeerConnection(to: info.endpoint, expectedPeerID: id)
            attach(conn)
        }
    }

    // MARK: - 接続管理

    private func attach(_ conn: PeerConnection) {
        conn.delegate = self
        addPending(conn)        // 確立まで強参照で保持する（先に入れてから start）
        conn.start()
    }

    private func register(_ conn: PeerConnection) {
        queue.async {
            self.removePending(conn)
            self.dialing.remove(conn.peerID)
            if let expected = conn.expectedPeerID { self.dialing.remove(expected) }
            if let existing = self.connections[conn.peerID], existing !== conn {
                // すでに接続がある場合は古いほうを閉じる
                existing.close()
            }
            self.connections[conn.peerID] = conn
            self.notifyPeersChanged()
        }
    }

    private func unregister(_ conn: PeerConnection) {
        queue.async {
            self.removePending(conn)
            // ハンドシェイク前に落ちた場合 peerID は空なので、発信時に分かっていた
            // ID も消しておかないと二度と再試行されなくなる
            if !conn.peerID.isEmpty { self.dialing.remove(conn.peerID) }
            if let expected = conn.expectedPeerID { self.dialing.remove(expected) }

            if !conn.peerID.isEmpty,
               let c = self.connections[conn.peerID], c === conn {
                self.connections.removeValue(forKey: conn.peerID)
            }
            self.notifyPeersChanged()
        }
    }

    // MARK: - 送受信 API

    /// 接続中の全端末に送る
    @discardableResult
    func broadcast(_ content: ClipContent) -> Int {
        let targets = queue.sync { connections.values.filter { $0.state == .ready } }
        for c in targets { c.send(content) }
        return targets.count
    }

    /// 接続中の全端末に「今のクリップボードをくれ」と要求する
    @discardableResult
    func requestPullFromAll() -> Int {
        let targets = queue.sync { connections.values.filter { $0.state == .ready } }
        for c in targets { c.requestPull() }
        return targets.count
    }

    /// 接続中の全端末にメッセージを送る
    @discardableResult
    func broadcastNotify(_ message: String, image: Data? = nil, files: [(name: String, data: Data)] = []) -> Int {
        let targets = queue.sync { connections.values.filter { $0.state == .ready } }
        for c in targets { c.sendNotify(message, image: image, files: files) }
        return targets.count
    }

    func disconnect(deviceID: String) {
        queue.async { self.connections[deviceID]?.close() }
    }

    private func notifyPeersChanged() {
        DispatchQueue.main.async { self.delegate?.peerManagerDidChangePeers(self) }
    }

    private func report(_ text: String) {
        DispatchQueue.main.async { self.delegate?.peerManager(self, statusDidChange: text) }
    }
}

// MARK: - PeerConnectionDelegate

extension PeerManager: PeerConnectionDelegate {

    func peerConnection(_ c: PeerConnection,
                        requiresPairing sas: String,
                        peerName: String,
                        completion: @escaping (Bool) -> Void) {
        delegate?.peerManager(self, requiresPairing: sas, peerName: peerName, completion: completion)
    }

    func peerConnectionDidBecomeReady(_ c: PeerConnection) {
        Log.info("接続完了:", c.peerName)
        register(c)
    }

    func peerConnection(_ c: PeerConnection, didReceive content: ClipContent) {
        delegate?.peerManager(self, didReceive: content, from: c.peerName)
    }

    func peerConnection(_ c: PeerConnection, didReceiveNotify message: String, attachment: NotifyAttachment) {
        delegate?.peerManager(self, didReceiveNotify: message, attachment: attachment, from: c.peerName)
    }

    func peerConnectionClipboardForPull(_ c: PeerConnection) -> ClipContent? {
        delegate?.peerManagerClipboardForPull(self)
    }

    func peerConnection(_ c: PeerConnection, didCloseWith error: Error?) {
        if let error { Log.info("切断:", c.peerName, error.localizedDescription) }
        unregister(c)
    }
}
