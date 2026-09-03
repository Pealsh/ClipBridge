import AppKit
import Carbon.HIToolbox
import ApplicationServices
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let manager = PeerManager()
    private let hotKeys = HotKeyManager()
    private var statusItem: NSStatusItem!

    /// 相手から届いて、まだ貼り付けていない内容
    private var inbox: (content: ClipContent, from: String, at: Date)?

    private var hotKeyConfig = HotKeyConfig.load()
    private var statusText = "起動中…"

    private var autoPaste: Bool {
        get { UserDefaults.standard.bool(forKey: "autoPaste") }
        set { UserDefaults.standard.set(newValue, forKey: "autoPaste") }
    }

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
                      onReceive: { [weak self] in self?.receiveClipboard() })

        if !hotKeys.failures.isEmpty {
            let list = hotKeys.failures.joined(separator: ", ")
            HUD.shared.show("ホットキー \(list) は他アプリが使用中です")
        }
        rebuildMenu()
    }

    /// ⌥V — 自分のクリップボードを接続中の相手へ送る
    private func sendClipboard() {
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
            HUD.shared.show("送信 → \(n) 台   \(content.summary)")
        }
    }

    /// ⌥C — 届いている内容をクリップボードに載せる。
    /// 何も届いていなければ、相手の今のクリップボードを取りに行く。
    private func receiveClipboard() {
        if let inbox {
            let note = ClipboardService.write(inbox.content)
            self.inbox = nil
            rebuildMenu()
            HUD.shared.show("貼り付け可能: \(note)")
            if autoPaste { performPaste() }
            return
        }

        let n = manager.requestPullFromAll()
        if n == 0 {
            HUD.shared.show("接続中の端末がありません")
        } else {
            HUD.shared.show("相手のクリップボードを取得中…")
        }
    }

    /// ⌘V を合成して前面アプリに貼り付ける（アクセシビリティ権限が必要）
    private func performPaste() {
        guard AXIsProcessTrusted() else {
            HUD.shared.show("自動貼り付けにはアクセシビリティ権限が必要です")
            return
        }
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        // ⌥C を押した指がまだ Option を離していない可能性があるので少し待つ
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
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

        if let inbox {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let item = NSMenuItem(
                title: "受信済み: \(inbox.content.summary)（\(inbox.from) \(f.string(from: inbox.at))）",
                action: #selector(menuReceive), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        let sendItem = NSMenuItem(title: "クリップボードを送信", action: #selector(menuSend), keyEquivalent: "")
        sendItem.target = self
        sendItem.toolTip = hotKeyConfig.sendDescription
        menu.addItem(sendItem)

        let recvItem = NSMenuItem(title: "受信した内容を取り込む", action: #selector(menuReceive), keyEquivalent: "")
        recvItem.target = self
        recvItem.toolTip = hotKeyConfig.receiveDescription
        menu.addItem(recvItem)

        let keys = NSMenuItem(
            title: "ショートカット: 送信 \(hotKeyConfig.sendDescription) / 受信 \(hotKeyConfig.receiveDescription)",
            action: nil, keyEquivalent: "")
        keys.isEnabled = false
        menu.addItem(keys)

        menu.addItem(.separator())

        let auto = NSMenuItem(title: "受信後に自動で ⌘V を送る", action: #selector(toggleAutoPaste), keyEquivalent: "")
        auto.target = self
        auto.state = autoPaste ? .on : .off
        menu.addItem(auto)

        let openInbox = NSMenuItem(title: "受信ファイルのフォルダを開く", action: #selector(menuOpenInbox), keyEquivalent: "")
        openInbox.target = self
        menu.addItem(openInbox)

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

    @objc private func menuSend()    { sendClipboard() }
    @objc private func menuReceive() { receiveClipboard() }

    @objc private func toggleAutoPaste() {
        autoPaste = !autoPaste
        if autoPaste && !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        }
        rebuildMenu()
    }

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
        inbox = (content: content, from: name, at: Date())
        rebuildMenu()
        HUD.shared.show("\(name) から受信: \(content.summary)　\(hotKeyConfig.receiveDescription) で取り込み")
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
