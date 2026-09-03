import AppKit
import UniformTypeIdentifiers

/// 画面上部のトーストと、画面中央のメッセージ通知を表示
final class HUD {

    static let shared = HUD()
    private var window: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var centerWindow: NSPanel?
    private let speechSynthesizer = NSSpeechSynthesizer()

    // 現在表示中のコンテンツ（コピー/保存用）
    private var currentMessage: String = ""
    private var currentImage: Data?
    private var currentFiles: [(name: String, data: Data)] = []

    private init() {
        if let japaneseVoice = NSSpeechSynthesizer.availableVoices.first(where: {
            $0.rawValue.contains("ja") || $0.rawValue.contains("Kyoko") || $0.rawValue.contains("Otoya")
        }) {
            speechSynthesizer.setVoice(japaneseVoice)
        }
    }

    // MARK: - 画面上部のトースト

    func show(_ text: String) {
        assert(Thread.isMainThread)
        hideWork?.cancel()

        let panel = window ?? makeToastPanel()
        window = panel

        guard let label = panel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first else { return }
        label.stringValue = text

        let maxWidth: CGFloat = 500
        let font = label.font ?? NSFont.systemFont(ofSize: 14, weight: .medium)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: 100),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font])
        let w = min(max(ceil(bounds.width) + 48, 180), maxWidth + 48)
        let h: CGFloat = 48

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.midX - w / 2, y: frame.maxY - h - 60)
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: false)
        }
        label.frame = NSRect(x: 24, y: 14, width: w - 48, height: 20)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.dismissToast() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func dismissToast() {
        guard let panel = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    // MARK: - 画面中央のメッセージ通知

    func showCenter(_ text: String, attachment: NotifyAttachment, from sender: String) {
        assert(Thread.isMainThread)

        centerWindow?.orderOut(nil)
        centerWindow = nil

        currentMessage = text
        currentImage = attachment.image
        currentFiles = attachment.files

        let hasImage = attachment.image != nil
        let hasFiles = !attachment.files.isEmpty
        let hasText = !text.isEmpty

        // 画面サイズ
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let maxW = screen.width - 80
        let maxH = screen.height - 80

        // パネル作成
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        centerWindow = panel

        // コンテンツサイズ計算
        let padding: CGFloat = 24
        let spacing: CGFloat = 16

        // メッセージサイズ
        let msgFont = NSFont.systemFont(ofSize: 32, weight: .medium)
        let msgBounds = hasText ? (text as NSString).boundingRect(
            with: NSSize(width: maxW - padding * 2, height: 300),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: msgFont]) : .zero

        // 画像サイズ
        var imgW: CGFloat = 0, imgH: CGFloat = 0
        if hasImage, let data = attachment.image, let img = NSImage(data: data) {
            let availH = maxH - 140 - (hasText ? ceil(msgBounds.height) + spacing : 0)
            let scale = min((maxW - padding * 2) / img.size.width, availH / img.size.height, 1.0)
            imgW = img.size.width * scale
            imgH = img.size.height * scale
        }

        // パネルサイズ
        var panelW = max(imgW + padding * 2, ceil(msgBounds.width) + padding * 2, 300)
        var panelH = padding + 32 // ヘッダー

        if hasText { panelH += ceil(msgBounds.height) + spacing }
        if hasImage { panelH += imgH + spacing }
        if hasFiles { panelH += CGFloat(min(attachment.files.count, 4)) * 32 + spacing }
        panelH += 56 // アクションバー

        panelW = min(panelW, maxW)
        panelH = min(panelH, maxH)

        // パネル配置
        let origin = NSPoint(x: screen.midX - panelW / 2, y: screen.midY - panelH / 2)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: panelW, height: panelH)), display: false)

        // 背景
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        bg.material = .fullScreenUI
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 20
        bg.layer?.masksToBounds = true

        var y = panelH - padding

        // ヘッダー: 送信者 + 閉じるボタン
        let header = NSView(frame: NSRect(x: 0, y: y - 28, width: panelW, height: 28))

        let senderLbl = NSTextField(labelWithString: "From: \(sender)")
        senderLbl.frame = NSRect(x: padding, y: 4, width: panelW - 80, height: 20)
        senderLbl.font = .systemFont(ofSize: 13, weight: .regular)
        senderLbl.textColor = .secondaryLabelColor
        header.addSubview(senderLbl)

        let closeBtn = NSButton(frame: NSRect(x: panelW - padding - 28, y: 0, width: 28, height: 28))
        closeBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "閉じる")
        closeBtn.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        closeBtn.bezelStyle = .regularSquare
        closeBtn.isBordered = false
        closeBtn.contentTintColor = .secondaryLabelColor
        closeBtn.target = self
        closeBtn.action = #selector(closeCenterPanel)
        header.addSubview(closeBtn)

        bg.addSubview(header)
        y -= 32

        // メッセージ
        if hasText {
            let msgLbl = NSTextField(labelWithString: text)
            let h = ceil(msgBounds.height) + 8
            msgLbl.frame = NSRect(x: padding, y: y - h, width: panelW - padding * 2, height: h)
            msgLbl.font = msgFont
            msgLbl.alignment = .center
            msgLbl.lineBreakMode = .byWordWrapping
            msgLbl.maximumNumberOfLines = 8
            msgLbl.textColor = .labelColor
            msgLbl.isSelectable = true
            bg.addSubview(msgLbl)
            y -= h + spacing
        }

        // 画像
        if hasImage, let data = attachment.image, let img = NSImage(data: data) {
            let imgView = NSImageView(frame: NSRect(x: (panelW - imgW) / 2, y: y - imgH, width: imgW, height: imgH))
            imgView.image = img
            imgView.imageScaling = .scaleProportionallyUpOrDown
            imgView.wantsLayer = true
            imgView.layer?.cornerRadius = 12
            imgView.layer?.masksToBounds = true
            bg.addSubview(imgView)
            y -= imgH + spacing
        }

        // ファイル一覧（最大4件表示）
        if hasFiles {
            let maxShow = min(attachment.files.count, 4)
            for i in 0..<maxShow {
                let file = attachment.files[i]
                let row = NSView(frame: NSRect(x: padding, y: y - 28, width: panelW - padding * 2, height: 28))
                row.wantsLayer = true
                row.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
                row.layer?.cornerRadius = 8

                let icon = NSImageView(frame: NSRect(x: 8, y: 6, width: 16, height: 16))
                if let ct = UTType(filenameExtension: (file.name as NSString).pathExtension) {
                    icon.image = NSWorkspace.shared.icon(for: ct)
                } else {
                    icon.image = NSWorkspace.shared.icon(for: .data)
                }
                row.addSubview(icon)

                let name = NSTextField(labelWithString: file.name)
                name.frame = NSRect(x: 32, y: 6, width: row.bounds.width - 100, height: 16)
                name.font = .systemFont(ofSize: 12)
                name.textColor = .labelColor
                name.lineBreakMode = .byTruncatingMiddle
                row.addSubview(name)

                let size = NSTextField(labelWithString: ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                size.frame = NSRect(x: row.bounds.width - 60, y: 6, width: 52, height: 16)
                size.font = .systemFont(ofSize: 11)
                size.textColor = .tertiaryLabelColor
                size.alignment = .right
                row.addSubview(size)

                bg.addSubview(row)
                y -= 32
            }
            if attachment.files.count > 4 {
                let more = NSTextField(labelWithString: "+\(attachment.files.count - 4) more")
                more.frame = NSRect(x: padding, y: y - 20, width: panelW - padding * 2, height: 16)
                more.font = .systemFont(ofSize: 11)
                more.textColor = .tertiaryLabelColor
                more.alignment = .center
                bg.addSubview(more)
            }
        }

        // アクションバー（アイコンボタン）
        let actionY: CGFloat = 16
        let btnSize: CGFloat = 40
        var buttons: [(icon: String, action: Selector)] = []

        if hasText { buttons.append(("doc.on.doc", #selector(copyMessage))) }
        if hasImage {
            buttons.append(("photo.on.rectangle", #selector(copyImage)))
            buttons.append(("square.and.arrow.down", #selector(saveImage)))
        }
        if hasFiles { buttons.append(("folder.badge.plus", #selector(saveFiles))) }

        let totalW = CGFloat(buttons.count) * btnSize + CGFloat(buttons.count - 1) * 12
        var btnX = (panelW - totalW) / 2

        for (icon, action) in buttons {
            let btn = NSButton(frame: NSRect(x: btnX, y: actionY, width: btnSize, height: btnSize))
            btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            btn.symbolConfiguration = .init(pointSize: 18, weight: .medium)
            btn.bezelStyle = .regularSquare
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = btnSize / 2
            btn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
            btn.contentTintColor = .labelColor
            btn.target = self
            btn.action = action
            bg.addSubview(btn)
            btnX += btnSize + 12
        }

        panel.contentView = bg

        // アニメーション
        panel.alphaValue = 0
        panel.setFrame(NSRect(origin: NSPoint(x: origin.x, y: origin.y - 20),
                              size: NSSize(width: panelW, height: panelH)), display: false)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(NSRect(origin: origin, size: NSSize(width: panelW, height: panelH)), display: true)
        }

        // 読み上げ
        if hasText {
            speechSynthesizer.stopSpeaking()
            speechSynthesizer.startSpeaking(text)
        }
    }

    @objc private func closeCenterPanel() {
        speechSynthesizer.stopSpeaking()
        guard let panel = centerWindow else { return }
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(NSRect(origin: NSPoint(x: frame.origin.x, y: frame.origin.y - 20),
                                             size: frame.size), display: true)
        }, completionHandler: {
            panel.orderOut(nil)
            self.centerWindow = nil
        })
    }

    @objc private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentMessage, forType: .string)
        show("コピーしました")
    }

    @objc private func copyImage() {
        guard let data = currentImage, let img = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        show("画像をコピーしました")
    }

    @objc private func saveImage() {
        guard let data = currentImage else { return }
        let dir = Const.inboxDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "image-\(Int(Date().timeIntervalSince1970)).png"
            try data.write(to: dir.appendingPathComponent(name))
            show("保存しました")
            NSWorkspace.shared.open(dir)
        } catch {
            show("保存に失敗しました")
        }
    }

    @objc private func saveFiles() {
        guard !currentFiles.isEmpty else { return }
        let dir = Const.inboxDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in currentFiles {
                var dest = dir.appendingPathComponent(file.name)
                var i = 1
                while FileManager.default.fileExists(atPath: dest.path) {
                    let n = (file.name as NSString).deletingPathExtension
                    let e = (file.name as NSString).pathExtension
                    dest = dir.appendingPathComponent("\(n)-\(i).\(e)")
                    i += 1
                }
                try file.data.write(to: dest)
            }
            show("\(currentFiles.count)件を保存しました")
            NSWorkspace.shared.open(dir)
        } catch {
            show("保存に失敗しました")
        }
    }

    // MARK: - トーストパネル

    private func makeToastPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 48),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSVisualEffectView(frame: panel.contentLayoutRect)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 24
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        bg.addSubview(label)

        panel.contentView = bg
        return panel
    }
}
