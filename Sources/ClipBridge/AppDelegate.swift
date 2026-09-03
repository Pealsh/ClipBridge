import AppKit
import Carbon.HIToolbox
import ApplicationServices
import CoreGraphics

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
                      onPause: { [weak self] in self?.togglePause() })

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

    /// ⌥C — 自分のクリップボードを接続中の相手へ送る
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
