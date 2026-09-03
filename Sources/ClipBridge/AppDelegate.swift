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

    /// 選択中の添付データ（メッセージダイアログ用）
    private var selectedImageData: Data?
    private var selectedFiles: [(name: String, data: Data)] = []

    /// ⌥⌘S — メッセージ入力ダイアログを表示して送信（リキッドグラスUI）
    private func showMessageDialog() {
        let peers = manager.readyPeers
        if peers.isEmpty {
            HUD.shared.show("接続中の端末がありません")
            return
        }

        selectedImageData = nil
        selectedFiles = []
        NSApp.activate(ignoringOtherApps: true)

        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = 220

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                            styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.title = "メッセージを送信"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel  // 最前面に表示
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false  // 他のところをクリックしても隠れない
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 背景ビュー（ドラッグ&ドロップ対応）
        let bgView = DropTargetView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        bgView.material = .hudWindow
        bgView.blendingMode = .behindWindow
        bgView.state = .active
        bgView.autoresizingMask = [.width, .height]
        bgView.onDrop = { [weak self, weak panel] urls, image in
            guard let self, let panel else { return }
            self.handleDroppedItems(urls: urls, image: image, panel: panel)
        }

        // メッセージ入力フィールド
        let fieldBg = NSView(frame: NSRect(x: 20, y: 135, width: panelWidth - 40, height: 36))
        fieldBg.wantsLayer = true
        fieldBg.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        fieldBg.layer?.cornerRadius = 10
        fieldBg.layer?.borderWidth = 1
        fieldBg.layer?.borderColor = NSColor.separatorColor.cgColor
        bgView.addSubview(fieldBg)

        let field = NSTextField(frame: NSRect(x: 12, y: 6, width: fieldBg.bounds.width - 24, height: 24))
        field.placeholderString = "メッセージを入力…"
        field.isBordered = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        fieldBg.addSubview(field)

        // 添付ボタン行
        let buttonY: CGFloat = 95

        // 画像添付ボタン
        let imageBtn = NSButton(frame: NSRect(x: 20, y: buttonY, width: 80, height: 28))
        imageBtn.title = "画像"
        imageBtn.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "画像")
        imageBtn.imagePosition = .imageLeading
        imageBtn.bezelStyle = .rounded
        imageBtn.font = .systemFont(ofSize: 12)
        imageBtn.target = self
        imageBtn.action = #selector(messageDialogSelectImage(_:))
        bgView.addSubview(imageBtn)

        // ファイル添付ボタン（複数選択可能）
        let fileBtn = NSButton(frame: NSRect(x: 105, y: buttonY, width: 90, height: 28))
        fileBtn.title = "ファイル"
        fileBtn.image = NSImage(systemSymbolName: "doc", accessibilityDescription: "ファイル")
        fileBtn.imagePosition = .imageLeading
        fileBtn.bezelStyle = .rounded
        fileBtn.font = .systemFont(ofSize: 12)
        fileBtn.target = self
        fileBtn.action = #selector(messageDialogSelectFiles(_:))
        bgView.addSubview(fileBtn)

        // ペーストボタン
        let pasteBtn = NSButton(frame: NSRect(x: 200, y: buttonY, width: 80, height: 28))
        pasteBtn.title = "貼付"
        pasteBtn.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "貼付")
        pasteBtn.imagePosition = .imageLeading
        pasteBtn.bezelStyle = .rounded
        pasteBtn.font = .systemFont(ofSize: 12)
        pasteBtn.target = self
        pasteBtn.action = #selector(messageDialogPaste(_:))
        bgView.addSubview(pasteBtn)

        // クリアボタン
        let clearBtn = NSButton(frame: NSRect(x: 285, y: buttonY, width: 28, height: 28))
        clearBtn.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "クリア")
        clearBtn.bezelStyle = .rounded
        clearBtn.target = self
        clearBtn.action = #selector(messageDialogClear(_:))
        bgView.addSubview(clearBtn)

        // ドロップエリアのヒント
        let dropHint = NSTextField(labelWithString: "画像・ファイルをドラッグ＆ドロップ")
        dropHint.frame = NSRect(x: 20, y: 65, width: panelWidth - 40, height: 20)
        dropHint.font = .systemFont(ofSize: 11)
        dropHint.textColor = .tertiaryLabelColor
        dropHint.alignment = .center
        bgView.addSubview(dropHint)

        // 添付プレビューラベル
        let attachLabel = NSTextField(labelWithString: "")
        attachLabel.frame = NSRect(x: 20, y: 45, width: panelWidth - 40, height: 16)
        attachLabel.font = .systemFont(ofSize: 12, weight: .medium)
        attachLabel.textColor = .secondaryLabelColor
        attachLabel.alignment = .center
        attachLabel.lineBreakMode = .byTruncatingTail
        attachLabel.tag = 200
        bgView.addSubview(attachLabel)

        // 送信先情報
        let infoLabel = NSTextField(labelWithString: "\(peers.count) 台に送信されます")
        infoLabel.frame = NSRect(x: 20, y: 15, width: 200, height: 16)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = .systemFont(ofSize: 11)
        bgView.addSubview(infoLabel)

        // 送信ボタン
        let sendBtn = NSButton(frame: NSRect(x: panelWidth - 90, y: 10, width: 70, height: 28))
        sendBtn.title = "送信"
        sendBtn.bezelStyle = .rounded
        sendBtn.keyEquivalent = "\r"
        sendBtn.target = self
        sendBtn.action = #selector(messageDialogSend(_:))
        bgView.addSubview(sendBtn)

        panel.contentView = bgView

        // フィールドとラベルをパネルに紐づけ
        objc_setAssociatedObject(panel, "textField", field, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(panel, "attachLabel", attachLabel, .OBJC_ASSOCIATION_RETAIN)

        if let screen = NSScreen.main {
            let origin = NSPoint(x: screen.frame.midX - panelWidth / 2, y: screen.frame.midY)
            panel.setFrameOrigin(origin)
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// ドロップされたアイテムを処理
    private func handleDroppedItems(urls: [URL], image: NSImage?, panel: NSPanel) {
        // 画像がドロップされた場合
        if let image = image {
            if let tiffData = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                var finalData = pngData
                if pngData.count > 5 * 1024 * 1024 {
                    if let resized = resizeImage(image, maxBytes: 5 * 1024 * 1024) {
                        finalData = resized
                    }
                }
                selectedImageData = finalData
            }
        }

        // ファイルがドロップされた場合
        if !urls.isEmpty {
            var files: [(name: String, data: Data)] = []
            var totalSize = 0
            let maxSize = 50 * 1024 * 1024

            for url in urls {
                // ディレクトリはスキップ
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      !isDir.boolValue else { continue }

                guard let data = try? Data(contentsOf: url) else { continue }

                // 画像ファイルの場合は画像として処理
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) && selectedImageData == nil {
                    var finalData = data
                    if data.count > 5 * 1024 * 1024, let img = NSImage(data: data) {
                        if let resized = resizeImage(img, maxBytes: 5 * 1024 * 1024) {
                            finalData = resized
                        }
                    }
                    selectedImageData = finalData
                    continue
                }

                totalSize += data.count
                if totalSize > maxSize {
                    HUD.shared.show("合計サイズが50MBを超えています")
                    break
                }
                files.append((name: url.lastPathComponent, data: data))
            }

            if !files.isEmpty {
                selectedFiles.append(contentsOf: files)
            }
        }

        updateAttachLabel(in: panel)
    }

    private func updateAttachLabel(in panel: NSPanel) {
        guard let label = objc_getAssociatedObject(panel, "attachLabel") as? NSTextField else { return }
        var parts: [String] = []
        if selectedImageData != nil { parts.append("画像1枚") }
        if !selectedFiles.isEmpty { parts.append("ファイル\(selectedFiles.count)個") }
        label.stringValue = parts.isEmpty ? "" : parts.joined(separator: " + ")
    }

    @objc private func messageDialogSelectImage(_ sender: NSButton) {
        guard let panel = sender.window as? NSPanel else { return }

        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .image]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.message = "送信する画像を選択"

        openPanel.beginSheetModal(for: panel) { [weak self] response in
            guard let self, response == .OK, let url = openPanel.url else { return }
            guard let imageData = try? Data(contentsOf: url),
                  let image = NSImage(data: imageData) else {
                HUD.shared.show("画像を読み込めませんでした")
                return
            }

            // 画像サイズを制限（5MB以下にリサイズ）
            var finalData = imageData
            if imageData.count > 5 * 1024 * 1024 {
                if let resized = self.resizeImage(image, maxBytes: 5 * 1024 * 1024) {
                    finalData = resized
                }
            }

            self.selectedImageData = finalData
            self.updateAttachLabel(in: panel)
        }
    }

    @objc private func messageDialogSelectFiles(_ sender: NSButton) {
        guard let panel = sender.window as? NSPanel else { return }

        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.message = "送信するファイルを選択（複数可）"

        openPanel.beginSheetModal(for: panel) { [weak self] response in
            guard let self, response == .OK else { return }

            var files: [(name: String, data: Data)] = []
            var totalSize = 0
            let maxSize = 50 * 1024 * 1024

            for fileURL in openPanel.urls {
                guard let data = try? Data(contentsOf: fileURL) else { continue }

                totalSize += data.count
                if totalSize > maxSize {
                    HUD.shared.show("合計サイズが50MBを超えています（一部のファイルのみ追加）")
                    break
                }
                files.append((name: fileURL.lastPathComponent, data: data))
            }

            if files.isEmpty {
                HUD.shared.show("ファイルを読み込めませんでした")
                return
            }

            self.selectedFiles.append(contentsOf: files)
            self.updateAttachLabel(in: panel)
        }
    }

    @objc private func messageDialogPaste(_ sender: NSButton) {
        guard let panel = sender.window as? NSPanel else { return }

        let pasteboard = NSPasteboard.general

        // 画像をペースト
        if let imageData = pasteboard.data(forType: .png) {
            selectedImageData = imageData
            updateAttachLabel(in: panel)
            return
        }

        if let imageData = pasteboard.data(forType: .tiff),
           let image = NSImage(data: imageData),
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            var finalData = pngData
            if pngData.count > 5 * 1024 * 1024 {
                if let resized = resizeImage(image, maxBytes: 5 * 1024 * 1024) {
                    finalData = resized
                }
            }
            selectedImageData = finalData
            updateAttachLabel(in: panel)
            return
        }

        // ファイルURLをペースト
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            handleDroppedItems(urls: urls, image: nil, panel: panel)
            return
        }

        HUD.shared.show("クリップボードに画像がありません")
    }

    @objc private func messageDialogClear(_ sender: NSButton) {
        guard let panel = sender.window as? NSPanel else { return }
        selectedImageData = nil
        selectedFiles = []
        updateAttachLabel(in: panel)
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
        let files = selectedFiles
        panel.close()
        selectedImageData = nil
        selectedFiles = []

        // メッセージ、画像、ファイルのいずれかがあれば送信
        guard !message.isEmpty || imageData != nil || !files.isEmpty else { return }

        let n = manager.broadcastNotify(message, image: imageData, files: files)
        if n > 0 {
            var what: [String] = []
            if !message.isEmpty { what.append("メッセージ") }
            if imageData != nil { what.append("画像") }
            if !files.isEmpty { what.append("ファイル\(files.count)個") }
            HUD.shared.show("\(n) 台に\(what.joined(separator: "と"))を送信しました")
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

        // 保存場所サブメニュー
        let saveLocMenu = NSMenu()
        for loc in SaveLocation.allCases {
            let item = NSMenuItem(title: loc.displayName, action: #selector(menuChangeSaveLocation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = loc
            if SaveLocationManager.shared.currentLocation == loc {
                item.state = .on
            }
            saveLocMenu.addItem(item)
        }
        let saveLocRoot = NSMenuItem(title: "保存場所: \(SaveLocationManager.shared.currentLocation.displayName)", action: nil, keyEquivalent: "")
        menu.addItem(saveLocRoot)
        menu.setSubmenu(saveLocMenu, for: saveLocRoot)

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

    @objc private func menuChangeSaveLocation(_ sender: NSMenuItem) {
        guard let loc = sender.representedObject as? SaveLocation else { return }

        if loc == .custom {
            // カスタムフォルダを選択
            let openPanel = NSOpenPanel()
            openPanel.canChooseDirectories = true
            openPanel.canChooseFiles = false
            openPanel.allowsMultipleSelection = false
            openPanel.message = "保存先フォルダを選択してください"
            openPanel.prompt = "選択"

            NSApp.activate(ignoringOtherApps: true)
            if openPanel.runModal() == .OK, let url = openPanel.url {
                SaveLocationManager.shared.customPath = url
                SaveLocationManager.shared.currentLocation = .custom
                HUD.shared.show("保存先を変更しました: \(url.lastPathComponent)/ClipBridge")
            }
        } else {
            SaveLocationManager.shared.currentLocation = loc
            HUD.shared.show("保存先を変更しました: \(loc.displayName)/ClipBridge")
        }
        rebuildMenu()
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

    func peerManager(_ m: PeerManager, didReceiveNotify message: String, attachment: NotifyAttachment, from name: String) {
        // メッセージは一時停止中でも強制的に表示（読み上げ付き）
        HUD.shared.showCenter(message, attachment: attachment, from: name)
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

// MARK: - ドラッグ＆ドロップ対応ビュー

final class DropTargetView: NSVisualEffectView {

    var onDrop: (([URL], NSImage?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.canReadObject(forClasses: [NSURL.self, NSImage.self], options: nil) {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        var urls: [URL] = []
        var image: NSImage?

        // ファイルURLを取得
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            urls = fileURLs
        }

        // 画像を取得
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let img = images.first {
            image = img
        }

        if !urls.isEmpty || image != nil {
            onDrop?(urls, image)
            return true
        }

        return false
    }
}
