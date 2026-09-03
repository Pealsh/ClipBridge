import Foundation
import Carbon.HIToolbox

/// アプリ全体で使う定数と、ユーザーが変更できる設定。
enum Const {
    static let bundleID       = "com.example.clipbridge"
    static let serviceType    = "_clipbridge._tcp"
    static let serviceDomain  = "local."
    static let protocolVersion = 1

    /// 1 メッセージの最大サイズ（100 MB）
    static let maxMessageBytes = 100 * 1024 * 1024

    /// 受信ファイルの保存先
    static var inboxDirectory: URL {
        let base = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("ClipBridge", isDirectory: true)
    }
}

/// ホットキー設定。既定は 送信 = Option+C。
/// `~/Library/Application Support/ClipBridge/hotkeys.json` で上書きできる。
struct HotKeyConfig: Codable {
    /// 仮想キーコード（kVK_ANSI_C など）
    var sendKeyCode: UInt32
    /// Carbon の修飾キーマスク（optionKey=2048, cmdKey=256, shiftKey=512, controlKey=4096）
    var sendModifiers: UInt32

    static let `default` = HotKeyConfig(
        sendKeyCode: UInt32(kVK_ANSI_C),
        sendModifiers: UInt32(optionKey)
    )

    static var configURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("hotkeys.json")
    }

    static func load() -> HotKeyConfig {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(HotKeyConfig.self, from: data)
        else { return .default }
        return cfg
    }

    func save() {
        AppPaths.ensureSupportDirectory()
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.configURL, options: .atomic)
        }
    }

    var sendDescription: String { Self.describe(key: sendKeyCode, mods: sendModifiers) }

    private static func describe(key: UInt32, mods: UInt32) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey)  != 0 { s += "⌥" }
        if mods & UInt32(shiftKey)   != 0 { s += "⇧" }
        if mods & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + (keyNames[Int(key)] ?? "key\(key)")
    }

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z"
    ]
}

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ClipBridge", isDirectory: true)
    }

    static func ensureSupportDirectory() {
        try? FileManager.default.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true)
    }
}

enum Log {
    static func info(_ items: Any...) {
        let msg = items.map { "\($0)" }.joined(separator: " ")
        FileHandle.standardError.write(Data("[ClipBridge] \(msg)\n".utf8))
    }
    static func error(_ items: Any...) {
        let msg = items.map { "\($0)" }.joined(separator: " ")
        FileHandle.standardError.write(Data("[ClipBridge][ERROR] \(msg)\n".utf8))
    }
}
