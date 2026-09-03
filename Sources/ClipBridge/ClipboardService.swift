import Foundation
import AppKit
import UniformTypeIdentifiers

/// NSPasteboard の読み書き。テキスト・画像・ファイルに対応する。
enum ClipboardService {

    // MARK: - 読み取り

    /// 今のクリップボードの中身を ClipContent に変換する。空なら nil。
    ///
    /// 優先順位: ファイル > 画像 > テキスト
    static func read() -> ClipContent? {
        let pb = NSPasteboard.general

        // 1. ファイル
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {

            var files: [(name: String, data: Data)] = []
            var total = 0
            for url in urls {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      !isDir.boolValue else { continue }   // フォルダは対象外
                guard let data = try? Data(contentsOf: url) else { continue }
                total += data.count
                if total > Const.maxMessageBytes {
                    Notifier.show(title: "ClipBridge",
                                  body: "ファイルが大きすぎます（上限 100MB）")
                    return nil
                }
                files.append((name: url.lastPathComponent, data: data))
            }
            if !files.isEmpty { return .files(files) }
        }

        // 2. 画像
        if let png = readImagePNG(from: pb) {
            return .image(png)
        }

        // 3. テキスト
        if let s = pb.string(forType: .string), !s.isEmpty {
            return .text(s)
        }

        return nil
    }

    private static func readImagePNG(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }

        guard let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              let image = images.first else { return nil }
        return pngData(from: image)
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - 書き込み

    /// 受け取った内容をローカルのクリップボードに載せる。
    /// 成功したら、ユーザーに見せる短い説明を返す。
    @discardableResult
    static func write(_ content: ClipContent) -> String {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch content {
        case .text(let s):
            pb.setString(s, forType: .string)
            return content.summary

        case .image(let png):
            if let image = NSImage(data: png) {
                // NSImage を書くと TIFF/PNG 両方の表現が入り、貼り付け先を選ばない
                pb.writeObjects([image])
            }
            pb.setData(png, forType: .png)
            return content.summary

        case .files(let items):
            let dir = Const.inboxDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            var urls: [NSURL] = []
            for item in items {
                let url = uniqueURL(in: dir, preferredName: item.name)
                do {
                    try item.data.write(to: url, options: .atomic)
                    urls.append(url as NSURL)
                } catch {
                    Log.error("ファイル保存失敗:", item.name, error)
                }
            }
            if urls.isEmpty { return "ファイルを保存できませんでした" }
            pb.writeObjects(urls)
            return items.count == 1
                ? "\(items[0].name) を \(dir.lastPathComponent) に保存"
                : "\(items.count) 個のファイルを \(dir.lastPathComponent) に保存"
        }
    }

    /// 同名ファイルがあれば "name-2.ext" のように避ける
    private static func uniqueURL(in dir: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(preferredName)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var n = 2
        repeat {
            let name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            candidate = dir.appendingPathComponent(name)
            n += 1
        } while fm.fileExists(atPath: candidate.path) && n < 1000
        return candidate
    }
}

// MARK: - 通知

enum Notifier {
    /// メニューバーアプリなので、控えめな通知だけ出す。
    /// 未署名アプリでは UNUserNotificationCenter が使えないことがあるため、
    /// 失敗してもアプリが止まらないようにしている。
    static func show(title: String, body: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .clipBridgeToast,
                object: nil,
                userInfo: ["title": title, "body": body])
        }
    }
}

extension Notification.Name {
    static let clipBridgeToast = Notification.Name("ClipBridgeToast")
}
