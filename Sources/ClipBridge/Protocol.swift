import Foundation

// MARK: - ワイヤーフォーマット
//
//  TCP ストリーム上は「4 バイトのビッグエンディアン長 + 本体」の繰り返し。
//
//  1. 接続直後、両者が平文の Hello フレームを 1 つずつ送る
//  2. 以降のフレームはすべて ChaChaPoly で暗号化された Envelope
//
//  Envelope（復号後の中身）:
//     [4 バイト BE ヘッダ長][JSON ヘッダ][バイナリ本体]

enum Frame {
    /// 本体に 4 バイトの長さを前置する
    static func encode(_ body: Data) -> Data {
        var out = Data(capacity: body.count + 4)
        var be = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    /// バッファの先頭から 1 フレーム取り出す。足りなければ nil。
    /// 取り出したぶんはバッファから削除する。
    static func decode(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let lengthBytes = buffer.prefix(4)
        let length = lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // 暗号化で 28 バイト（nonce 12 + tag 16）+ JSON ヘッダぶん増えるので余裕を持たせる
        guard length <= UInt32(Const.maxMessageBytes + 64 * 1024) else { throw ProtocolError.tooLarge }
        guard buffer.count >= 4 + Int(length) else { return nil }
        let body = buffer.subdata(in: 4 ..< (4 + Int(length)))
        buffer.removeSubrange(0 ..< (4 + Int(length)))
        return body
    }
}

enum ProtocolError: LocalizedError {
    case tooLarge
    case badHandshake(String)
    case untrustedPeer
    case malformed

    var errorDescription: String? {
        switch self {
        case .tooLarge:            return "メッセージが大きすぎます（上限 100MB）"
        case .badHandshake(let s): return "ハンドシェイク失敗: \(s)"
        case .untrustedPeer:       return "未ペアリングの端末です"
        case .malformed:           return "壊れたメッセージを受信しました"
        }
    }
}

// MARK: - ハンドシェイク

struct Hello: Codable {
    let version: Int
    let deviceID: String
    let deviceName: String
    let publicKey: String   // base64
    let nonce: String       // base64
}

// MARK: - アプリケーションメッセージ

struct FileEntry: Codable {
    let name: String
    let size: Int
}

struct MessageHeader: Codable {
    /// "clip" | "pull" | "pairack" | "ack" | "ping" | "notify"
    let type: String
    var kind: String?        = nil   // clip のとき: "text" | "image" | "files"
    var text: String?        = nil   // kind == "text"
    var imageFormat: String? = nil   // kind == "image" -> "png"
    var files: [FileEntry]?  = nil   // kind == "files"
    var ok: Bool?            = nil   // ack / pairack
    var note: String?        = nil   // ack / エラー説明
    var message: String?     = nil   // notify のとき: 表示するメッセージ
}

struct Envelope {
    let header: MessageHeader
    let body: Data

    func serialize() throws -> Data {
        let headerData = try JSONEncoder().encode(header)
        var out = Data(capacity: headerData.count + body.count + 4)
        var be = UInt32(headerData.count).bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(headerData)
        out.append(body)
        return out
    }

    static func parse(_ data: Data) throws -> Envelope {
        guard data.count >= 4 else { throw ProtocolError.malformed }
        let len = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard data.count >= 4 + Int(len) else { throw ProtocolError.malformed }
        let headerData = data.subdata(in: 4 ..< (4 + Int(len)))
        let body = data.subdata(in: (4 + Int(len)) ..< data.count)
        let header = try JSONDecoder().decode(MessageHeader.self, from: headerData)
        return Envelope(header: header, body: body)
    }
}

// MARK: - クリップボードの中身

enum ClipContent {
    case text(String)
    case image(Data)                 // PNG
    case files([(name: String, data: Data)])

    var summary: String {
        switch self {
        case .text(let s):
            let oneLine = s.replacingOccurrences(of: "\n", with: " ")
            return oneLine.count > 40 ? String(oneLine.prefix(40)) + "…" : oneLine
        case .image(let d):
            return "画像 (\(ByteCountFormatter.string(fromByteCount: Int64(d.count), countStyle: .file)))"
        case .files(let fs):
            return fs.count == 1 ? fs[0].name : "\(fs.count) 個のファイル"
        }
    }

    var byteCount: Int {
        switch self {
        case .text(let s):  return s.utf8.count
        case .image(let d): return d.count
        case .files(let f): return f.reduce(0) { $0 + $1.data.count }
        }
    }

    func toEnvelope() -> Envelope {
        switch self {
        case .text(let s):
            var h = MessageHeader(type: "clip")
            h.kind = "text"; h.text = s
            return Envelope(header: h, body: Data())

        case .image(let png):
            var h = MessageHeader(type: "clip")
            h.kind = "image"; h.imageFormat = "png"
            return Envelope(header: h, body: png)

        case .files(let items):
            var h = MessageHeader(type: "clip")
            h.kind = "files"
            h.files = items.map { FileEntry(name: $0.name, size: $0.data.count) }
            var body = Data()
            for item in items { body.append(item.data) }
            return Envelope(header: h, body: body)
        }
    }

    static func from(_ env: Envelope) throws -> ClipContent {
        switch env.header.kind {
        case "text":
            guard let t = env.header.text else { throw ProtocolError.malformed }
            return .text(t)

        case "image":
            return .image(env.body)

        case "files":
            guard let entries = env.header.files else { throw ProtocolError.malformed }
            var offset = 0
            var out: [(name: String, data: Data)] = []
            for e in entries {
                guard offset + e.size <= env.body.count else { throw ProtocolError.malformed }
                let chunk = env.body.subdata(in: offset ..< (offset + e.size))
                out.append((name: sanitize(e.name), data: chunk))
                offset += e.size
            }
            return .files(out)

        default:
            throw ProtocolError.malformed
        }
    }

    /// 相手が送ってきたファイル名をそのまま使わない（パス脱出を防ぐ）
    private static func sanitize(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "/", with: "_")
                          .replacingOccurrences(of: "\0", with: "_")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "clipbridge-file" }
        return String(cleaned.prefix(200))
    }
}
