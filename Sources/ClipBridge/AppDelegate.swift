import AppKit
import Carbon.HIToolbox
import ApplicationServices
import CoreGraphics
import ObjectiveC
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let manager = PeerManager()
    private let hotKeys = HotKeyManager()
    private var statusItem: NSStatusItem!

    private var hotKeyConfig = HotKeyConfig.load()
    private var statusText = "起動中…"
    private var isPaused = false

    // MARK: - 起動

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        NotificationCenter.default.addObserver(
            forName: .clipBridgeToast, object: nil, queue: .main) { note in
                let body = note.userInfo?["body"] as? String ?? ""
                HUD.shared.show(body)
            }

        setUpMainMenu()
        setUpStatusItem()

        manager.delegate = self
        manager.start()

        applyHotKeys()

        Log.info("起動しました deviceID=\(Identity.shared.deviceID) name=\(Identity.shared.deviceName)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stop()
        hotKeys.unregisterAll()
    }

    // MARK: - ホットキー

    private func applyHotKeys() {
        hotKeys.apply(config: hotKeyConfig,
                      onSend: { [weak self] in self?.sendClipboard() },
                      onPause: { [weak self] in self?.togglePause() },
                      onMessage: { [weak self] in self?.showMessageDialog() })

        if !hotKeys.failures.isEmpty {
            let list = hotKeys.failures.joined(separator: ", ")
            HUD.shared.show("ホットキー \(list) は他アプリが使用中です")
        }
        rebuildMenu()
    }

    /// 通信の一時停止/再開を切り替え
    private func togglePause() {
        isPaused.toggle()
        updateStatusIcon()
        rebuildMenu()
        if isPaused {
            HUD.shared.show("通信を一時停止しました")
        } else {
            HUD.shared.show("通信を再開しました")
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let iconName = isPaused ? "doc.on.clipboard.fill" : "doc.on.clipboard"
        button.image = NSImage(systemSymbolName: iconName,
                               accessibilityDescription: "ClipBridge")
        button.image?.isTemplate = true
    }

    /// ⌥⌘C — 自分のクリップボードを接続中の相手へ送る
    private func sendClipboard() {
        if isPaused {
            HUD.shared.show("通信は一時停止中です（\(hotKeyConfig.pauseDescription) で再開）")
            return
        }
        guard let content = ClipboardService.read() else {
            HUD.shared.show("クリップボードが空です")
            return
        }
        guard content.byteCount <= Const.maxMessageBytes else {
            HUD.shared.show("内容が大きすぎます（上限 100MB）")
            return
        }
        let n = manager.broadcast(content)
        if n == 0 {
            HUD.shared.show("接続中の端末がありません")
        } else {
            HUD.shared.show("\(n) 台に送信しました")
        }
    }

    /// 選択中の画像データ（メッセージダイアログ用）
    private var selectedImageData: Data?

    /// ⌥⌘S — メッセージ入力ダイアログを表示して送信（リキッドグラスUI）
    private func showMessageDialog() {
        let peers = manager.readyPeers
        if peers.isEmpty {
            HUD.shared.show("接続中の端末がありません")
            return
        }

        selectedImageData = nil
        NSApp.activate(ignoringOtherApps: true)

        let panelWidth: CGFloat = 420
        let panelHeight: CGFloat = 160

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false

        // リキッドグラス背景
        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        // タイトル
        let titleLabel = NSTextField(labelWithString: "メッセージを送信")
        titleLabel.frame = NSRect(x: 20, y: panelHeight - 35, width: panelWidth - 40, height: 20)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        blur.addSubview(titleLabel)

        // テキストフィールド（角丸、半透明背景）
        let fieldContainer = NSView(frame: NSRect(x: 20, y: 65, width: panelWidth - 130, height: 32))
        fieldContainer.wantsLayer = true
        fieldContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        fieldContainer.layer?.cornerRadius = 8
        blur.addSubview(fieldContainer)

        let field = NSTextField(frame: NSRect(x: 8, y: 4, width: fieldContainer.bounds.width - 16, height: 24))
        field.placeholderString = "メッセージを入力…"
        field.isBordered = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        fieldContainer.addSubview(field)

        // 画像挿入ボタン
        let imageButton = NSButton(frame: NSRect(x: panelWidth - 100, y: 67, width: 28, height: 28))
        imageButton.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: "画像を追加")
        imageButton.bezelStyle = .regularSquare
        imageButton.isBordered = false
        imageButton.wantsLayer = true
        imageButton.layer?.cornerRadius = 6
        imageButton.target = self
        imageButton.action = #selector(messageDialogSelectImage(_:))
        blur.addSubview(imageButton)

        // 送信ボタン
        let sendButton = NSButton(frame: NSRect(x: panelWidth - 65, y: 65, width: 50, height: 32))
        sendButton.title = "送信"
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.wantsLayer = true
        blur.addSubview(sendButton)

        // 画像プレビュー（非表示、画像選択時に表示）
        let imagePreview = NSImageView(frame: NSRect(x: 20, y: 35, width: 60, height: 45))
        imagePreview.imageScaling = .scaleProportionallyUpOrDown
        imagePreview.wantsLayer = true
        imagePreview.layer?.cornerRadius = 6
        imagePreview.layer?.masksToBounds = true
        imagePreview.layer?.borderWidth = 1
        imagePreview.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        imagePreview.isHidden = true
        imagePreview.tag = 100
        blur.addSubview(imagePreview)

        // 画像削除ボタン
        let removeImageButton = NSButton(frame: NSRect(x: 70, y: 55, width: 20, height: 20))
        removeImageButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "画像を削除")
        removeImageButton.bezelStyle = .regularSquare
        removeImageButton.isBordered = false
        removeImageButton.isHidden = true
        removeImageButton.tag = 101
        removeImageButton.target = self
        removeImageButton.action = #selector(messageDialogRemoveImage(_:))
        blur.addSubview(removeImageButton)

        // 送信先情報
        let infoLabel = NSTextField(labelWithString: "\(peers.count) 台に送信されます")
        infoLabel.frame = NSRect(x: 20, y: 12, width: panelWidth - 40, height: 16)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = .systemFont(ofSize: 11)
        blur.addSubview(infoLabel)

        panel.contentView = blur

        sendButton.target = self
        sendButton.action = #selector(messageDialogSend(_:))

        // フィールドとプレビューをパネルに紐づけ
        objc_setAssociatedObject(panel, "textField", field, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(panel, "imagePreview", imagePreview, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(panel, "removeButton", removeImageButton, .OBJC_ASSOCIATION_RETAIN)

        if let screen = NSScreen.main {
            let origin = NSPoint(x: screen.frame.midX - panelWidth / 2, y: screen.frame.midY)
            panel.setFrameOrigin(origin)
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    @objc private func messageDialogSelectImage(_ sender: NSButton) {
        guard let panel = sender.window as? NSPanel else { return }

        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.message = "送信する画像を選択"

        openPanel.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            guard let imageData = try? Data(contentsOf: url),
                  let image = NSImage(data: imageData) else {
                HUD.shared.show("画像を読み込めませんでした")
                return
            }

            // 画像サイズを制限（2MB以下にリサイズ）
            var finalData = imageData
            if imageData.count > 2 * 1024 * 1024 {
                if let resized = self?.resizeImage(image, maxBytes: 2 * 1024 * 1024) {
                    finalData = resized
                }
            }

            self?.selectedImageData = finalData

            // プレビュー表示
            if let preview = objc_getAssociatedObject(panel, "imagePreview") as? NSImageView,
               let removeBtn = objc_getAssociatedObject(panel, "removeButton") as? NSButton {
                preview.image = NSImage(data: finalData)
                preview.isHidden = false
                removeBtn.isHidden = false
            }
        }
    }

    @objc private func messageDialogRemoveImage(_ sender: NSButton) {
        guard let panel = sender.window as? NSPanel else { return }
        selectedImageData = nil

        if let preview = objc_getAssociatedObject(panel, "imagePreview") as? NSImageView,
           let removeBtn = objc_getAssociatedObject(panel, "removeButton") as? NSButton {
            preview.image = nil
            preview.isHidden = true
            removeBtn.isHidden = true
        }
    }

    private func resizeImage(_ image: NSImage, maxBytes: Int) -> Data? {
        var scale: CGFloat = 1.0
        var data: Data?

        while scale > 0.1 {
            let newSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let newImage = NSImage(size: newSize)
            newImage.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: newSize),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy, fraction: 1.0)
            newImage.unlockFocus()

            if let tiffData = newImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                if pngData.count <= maxBytes {
                    data = pngData
                    break
                }
            }
            scale -= 0.1
        }
        return data
    }

    @objc private func messageDialogSend(_ sender: NSButton) {
        guard let panel = sender.window as? NSPanel,
              let field = objc_getAssociatedObject(panel, "textField") as? NSTextField
        else { return }

        let message = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageData = selectedImageData
        panel.close()
        selectedImageData = nil

        // メッセージか画像のどちらかがあれば送信
        guard !message.isEmpty || imageData != nil else { return }

        let n = manager.broadcastNotify(message, image: imageData)
        if n > 0 {
            if imageData != nil {
                HUD.shared.show("\(n) 台にメッセージと画像を送信しました")
            } else {
                HUD.shared.show("\(n) 台にメッセージを送信しました")
            }
        }
    }

    // MARK: - メニューバー

    /// ダイアログ内のテキストフィールドで ⌘C/⌘V/⌘A を効かせるための最小メニュー
    private func setUpMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "ClipBridge を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                   accessibilityDescription: "ClipBridge")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let peers = manager.readyPeers

        let header = NSMenuItem(
            title: peers.isEmpty ? "接続中の端末なし（\(statusText)）"
                                 : "接続中: \(peers.count) 台",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for p in peers {
            let item = NSMenuItem(title: "  ● \(p.name)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let sendItem = NSMenuItem(title: "クリップボードを送信（\(hotKeyConfig.sendDescription)）", action: #selector(menuSend), keyEquivalent: "")
        sendItem.target = self
        sendItem.isEnabled = !isPaused
        menu.addItem(sendItem)

        let messageItem = NSMenuItem(title: "メッセージを送信（\(hotKeyConfig.messageDescription)）", action: #selector(menuMessage), keyEquivalent: "")
        messageItem.target = self
        menu.addItem(messageItem)

        let pauseTitle = isPaused ? "通信を再開（\(hotKeyConfig.pauseDescription)）" : "通信を一時停止（\(hotKeyConfig.pauseDescription)）"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(menuTogglePause), keyEquivalent: "")
        pauseItem.target = self
        if isPaused { pauseItem.state = .on }
        menu.addItem(pauseItem)

        let openInbox = NSMenuItem(title: "受信ファイルのフォルダを開く", action: #selector(menuOpenInbox), keyEquivalent: "")
        openInbox.target = self
        menu.addItem(openInbox)

        menu.addItem(.separator())

        let rename = NSMenuItem(title: "この Mac の名前を変更…", action: #selector(menuRename), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)

        // ペアリング済み端末
        let trusted = TrustStore.shared.all
        let trustMenu = NSMenu()
        if trusted.isEmpty {
            let none = NSMenuItem(title: "（なし）", action: nil, keyEquivalent: "")
            none.isEnabled = false
            trustMenu.addItem(none)
        } else {
            for p in trusted {
                let item = NSMenuItem(title: "\(p.name) を解除", action: #selector(menuForget(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p.deviceID
                trustMenu.addItem(item)
            }
            trustMenu.addItem(.separator())
            let all = NSMenuItem(title: "すべて解除", action: #selector(menuForgetAll), keyEquivalent: "")
            all.target = self
            trustMenu.addItem(all)
        }
        let trustRoot = NSMenuItem(title: "ペアリング済み端末（\(trusted.count)）", action: nil, keyEquivalent: "")
        menu.addItem(trustRoot)
        menu.setSubmenu(trustMenu, for: trustRoot)

        menu.addItem(.separator())

        let idItem = NSMenuItem(title: "この Mac: \(Identity.shared.deviceName) · \(Identity.shared.deviceID.prefix(8))",
                                action: nil, keyEquivalent: "")
        idItem.isEnabled = false
        menu.addItem(idItem)

        let restart = NSMenuItem(title: "ネットワークを再接続", action: #selector(menuRestart), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "ClipBridge を終了", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - メニュー操作

    @objc private func menuSend() { sendClipboard() }
    @objc private func menuMessage() { showMessageDialog() }
    @objc private func menuTogglePause() { togglePause() }

    @objc private func menuOpenInbox() {
        let dir = Const.inboxDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func menuRename() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "この Mac の表示名"
        alert.informativeText = "相手のメニューにこの名前で表示されます。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = Identity.shared.deviceName
        alert.accessoryView = field
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                Identity.shared.deviceName = String(name.prefix(60))
                manager.restart()      // Bonjour の広告名を作り直す
                rebuildMenu()
            }
        }
    }

    @objc private func menuForget(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        TrustStore.shared.forget(deviceID: id)
        manager.disconnect(deviceID: id)
        rebuildMenu()
    }

    @objc private func menuForgetAll() {
        TrustStore.shared.forgetAll()
        manager.restart()
        rebuildMenu()
    }

    @objc private func menuRestart() {
        statusText = "再接続中…"
        manager.restart()
        rebuildMenu()
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }
}

// MARK: - PeerManagerDelegate

extension AppDelegate: PeerManagerDelegate {

    func peerManagerDidChangePeers(_ m: PeerManager) {
        rebuildMenu()
    }

    func peerManager(_ m: PeerManager, didReceive content: ClipContent, from name: String) {
        // 一時停止中は無視
        if isPaused { return }
        // 受信したらすぐにクリップボードに反映
        let note = ClipboardService.write(content)
        HUD.shared.show("\(name) から受信: \(note)")
    }

    func peerManager(_ m: PeerManager, didReceiveNotify message: String, image: Data?, from name: String) {
        // メッセージは一時停止中でも強制的に表示（読み上げ付き）
        HUD.shared.showCenter(message, image: image, from: name)
    }

    func peerManager(_ m: PeerManager,
                     requiresPairing sas: String,
                     peerName: String,
                     completion: @escaping (Bool) -> Void) {
        PairingPrompt.present(sas: sas, peerName: peerName, completion: completion)
    }

    func peerManagerClipboardForPull(_ m: PeerManager) -> ClipContent? {
        ClipboardService.read()
    }

    func peerManager(_ m: PeerManager, statusDidChange text: String) {
        statusText = text
        rebuildMenu()
    }
}
