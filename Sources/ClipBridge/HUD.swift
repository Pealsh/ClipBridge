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
        // 日本語の音声があれば使用
        if let japaneseVoice = NSSpeechSynthesizer.availableVoices.first(where: {
            $0.rawValue.contains("ja") || $0.rawValue.contains("Kyoko") || $0.rawValue.contains("Otoya")
        }) {
            speechSynthesizer.setVoice(japaneseVoice)
        }
    }

    // MARK: - 画面上部のトースト（自動で消える）

    func show(_ text: String) {
        assert(Thread.isMainThread)
        hideWork?.cancel()

        let panel = window ?? makeToastPanel()
        window = panel

        guard let label = panel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first
        else { return }
        label.stringValue = text

        let maxWidth: CGFloat = 460
        let font = label.font ?? NSFont.systemFont(ofSize: 13, weight: .medium)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let w = min(max(ceil(bounds.width) + 40, 160), maxWidth + 40)
        let h = max(ceil(bounds.height) + 26, 44)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.midX - w / 2, y: frame.maxY - h - 50)
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: false)
        }
        label.frame = NSRect(x: 20, y: 13, width: w - 40, height: h - 26)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.dismissToast() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func dismissToast() {
        guard let panel = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    // MARK: - 画面中央のメッセージ通知（×ボタンで閉じる）

    func showCenter(_ text: String, attachment: NotifyAttachment, from sender: String) {
        assert(Thread.isMainThread)

        // 現在のパネルを閉じる
        centerWindow?.orderOut(nil)
        centerWindow = nil

        // コンテンツを保存
        currentMessage = text
        currentImage = attachment.image
        currentFiles = attachment.files

        let hasImage = attachment.image != nil
        let hasFiles = !attachment.files.isEmpty

        // パネルを作成
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false  // インタラクティブ
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        centerWindow = panel

        // リキッドグラス背景
        let blur = NSVisualEffectView(frame: panel.contentLayoutRect)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        // レイアウト計算
        let maxWidth: CGFloat = 700
        let padding: CGFloat = 28
        let buttonHeight: CGFloat = 36
        let buttonSpacing: CGFloat = 10

        // メッセージサイズ計算（大きめのフォント）
        let font = NSFont.systemFont(ofSize: 28, weight: .medium)
        let textBounds = text.isEmpty ? CGRect.zero : (text as NSString).boundingRect(
            with: NSSize(width: maxWidth - padding * 2, height: 300),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])

        var contentHeight: CGFloat = 0
        var panelWidth: CGFloat = max(ceil(textBounds.width) + padding * 2, 400)

        // 送信者ラベル + 閉じるボタンの高さ
        let headerHeight: CGFloat = 40
        contentHeight += headerHeight

        // メッセージ高さ
        if !text.isEmpty {
            contentHeight += ceil(textBounds.height) + 20
        }

        // 画像サイズ（大きめに表示）
        var imageRect = CGRect.zero
        if hasImage, let imageData = attachment.image, let nsImage = NSImage(data: imageData) {
            let imgSize = nsImage.size
            let maxImgW: CGFloat = 600
            let maxImgH: CGFloat = 450
            let scale = min(maxImgW / imgSize.width, maxImgH / imgSize.height, 1.0)
            let imgW = imgSize.width * scale
            let imgH = imgSize.height * scale
            imageRect = CGRect(x: 0, y: 0, width: imgW, height: imgH)
            panelWidth = max(panelWidth, imgW + padding * 2)
            contentHeight += imgH + 16
        }

        // ファイル一覧の高さ
        if hasFiles {
            contentHeight += CGFloat(attachment.files.count) * 28 + 8
        }

        // ボタン行の高さ
        contentHeight += buttonHeight + padding

        let panelHeight = contentHeight + padding
        panelWidth = min(panelWidth, maxWidth + padding * 2)

        // パネルサイズ設定
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.midX - panelWidth / 2, y: frame.midY - panelHeight / 2)
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight)), display: false)
        }
        blur.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        var yOffset = panelHeight - padding

        // 閉じるボタン（右上）
        let closeButton = NSButton(frame: NSRect(x: panelWidth - 36, y: yOffset - 24, width: 24, height: 24))
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "閉じる")
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeCenterPanel)
        blur.addSubview(closeButton)

        // 送信者ラベル
        let senderLabel = NSTextField(labelWithString: sender)
        senderLabel.frame = NSRect(x: padding, y: yOffset - 20, width: panelWidth - padding * 2 - 30, height: 16)
        senderLabel.font = .systemFont(ofSize: 12, weight: .regular)
        senderLabel.textColor = .secondaryLabelColor
        blur.addSubview(senderLabel)
        yOffset -= headerHeight

        // メッセージ
        if !text.isEmpty {
            let messageLabel = NSTextField(labelWithString: text)
            let msgHeight = ceil(textBounds.height) + 4
            messageLabel.frame = NSRect(x: padding, y: yOffset - msgHeight, width: panelWidth - padding * 2, height: msgHeight)
            messageLabel.font = font
            messageLabel.alignment = .center
            messageLabel.lineBreakMode = .byWordWrapping
            messageLabel.maximumNumberOfLines = 6
            messageLabel.textColor = .labelColor
            messageLabel.isSelectable = true
            blur.addSubview(messageLabel)
            yOffset -= msgHeight + 16
        }

        // 画像（大きく表示、角丸12px）
        if hasImage, let imageData = attachment.image, let nsImage = NSImage(data: imageData) {
            let imgW = imageRect.width
            let imgH = imageRect.height
            let imageView = NSImageView(frame: NSRect(x: (panelWidth - imgW) / 2, y: yOffset - imgH, width: imgW, height: imgH))
            imageView.image = nsImage
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 12
            imageView.layer?.masksToBounds = true
            imageView.layer?.borderWidth = 1
            imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
            blur.addSubview(imageView)
            yOffset -= imgH + 16
        }

        // ファイル一覧
        if hasFiles {
            for file in attachment.files {
                let fileRow = NSView(frame: NSRect(x: padding, y: yOffset - 24, width: panelWidth - padding * 2, height: 24))
                fileRow.wantsLayer = true
                fileRow.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
                fileRow.layer?.cornerRadius = 6

                let icon = NSImageView(frame: NSRect(x: 6, y: 4, width: 16, height: 16))
                if let contentType = UTType(filenameExtension: (file.name as NSString).pathExtension) {
                    icon.image = NSWorkspace.shared.icon(for: contentType)
                } else {
                    icon.image = NSWorkspace.shared.icon(for: .data)
                }
                fileRow.addSubview(icon)

                let nameLabel = NSTextField(labelWithString: file.name)
                nameLabel.frame = NSRect(x: 28, y: 4, width: fileRow.bounds.width - 80, height: 16)
                nameLabel.font = .systemFont(ofSize: 11)
                nameLabel.textColor = .labelColor
                nameLabel.lineBreakMode = .byTruncatingMiddle
                fileRow.addSubview(nameLabel)

                let sizeLabel = NSTextField(labelWithString: ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                sizeLabel.frame = NSRect(x: fileRow.bounds.width - 50, y: 4, width: 44, height: 16)
                sizeLabel.font = .systemFont(ofSize: 10)
                sizeLabel.textColor = .secondaryLabelColor
                sizeLabel.alignment = .right
                fileRow.addSubview(sizeLabel)

                blur.addSubview(fileRow)
                yOffset -= 28
            }
            yOffset -= 8
        }

        // ボタン行
        let buttonY = padding / 2
        var buttonX = padding

        // コピーボタン（メッセージがある場合）
        if !text.isEmpty {
            let copyMsgBtn = makeActionButton(title: "テキストをコピー", icon: "doc.on.doc")
            copyMsgBtn.frame = NSRect(x: buttonX, y: buttonY, width: 130, height: buttonHeight)
            copyMsgBtn.target = self
            copyMsgBtn.action = #selector(copyMessage)
            blur.addSubview(copyMsgBtn)
            buttonX += 130 + buttonSpacing
        }

        // 画像をコピー/保存（画像がある場合）
        if hasImage {
            let copyImgBtn = makeActionButton(title: "画像をコピー", icon: "photo.on.rectangle")
            copyImgBtn.frame = NSRect(x: buttonX, y: buttonY, width: 110, height: buttonHeight)
            copyImgBtn.target = self
            copyImgBtn.action = #selector(copyImage)
            blur.addSubview(copyImgBtn)
            buttonX += 110 + buttonSpacing

            let saveImgBtn = makeActionButton(title: "画像を保存", icon: "square.and.arrow.down")
            saveImgBtn.frame = NSRect(x: buttonX, y: buttonY, width: 100, height: buttonHeight)
            saveImgBtn.target = self
            saveImgBtn.action = #selector(saveImage)
            blur.addSubview(saveImgBtn)
            buttonX += 100 + buttonSpacing
        }

        // ファイルを保存（ファイルがある場合）
        if hasFiles {
            let saveFilesBtn = makeActionButton(title: "ファイルを保存", icon: "folder.badge.plus")
            saveFilesBtn.frame = NSRect(x: buttonX, y: buttonY, width: 120, height: buttonHeight)
            saveFilesBtn.target = self
            saveFilesBtn.action = #selector(saveFiles)
            blur.addSubview(saveFilesBtn)
        }

        panel.contentView = blur

        // アニメーション表示
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }

        // メッセージを読み上げ
        if !text.isEmpty {
            speechSynthesizer.stopSpeaking()
            speechSynthesizer.startSpeaking(text)
        }
    }

    private func makeActionButton(title: String, icon: String) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.title = title
        btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        btn.imagePosition = .imageLeading
        btn.bezelStyle = .rounded
        btn.font = .systemFont(ofSize: 11)
        return btn
    }

    @objc private func closeCenterPanel() {
        speechSynthesizer.stopSpeaking()
        guard let panel = centerWindow else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            self.centerWindow = nil
        })
    }

    @objc private func copyMessage() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(currentMessage, forType: .string)
        show("テキストをコピーしました")
    }

    @objc private func copyImage() {
        guard let imageData = currentImage, let image = NSImage(data: imageData) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        show("画像をコピーしました")
    }

    @objc private func saveImage() {
        guard let imageData = currentImage else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "ClipBridge-\(Int(Date().timeIntervalSince1970)).png"
        savePanel.begin { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try imageData.write(to: url)
                self?.show("画像を保存しました")
            } catch {
                self?.show("保存に失敗しました")
            }
        }
    }

    @objc private func saveFiles() {
        guard !currentFiles.isEmpty else { return }

        // 受信フォルダに保存
        let inboxDir = Const.inboxDirectory
        do {
            try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
            for file in currentFiles {
                var destURL = inboxDir.appendingPathComponent(file.name)
                // 重複回避
                var counter = 1
                while FileManager.default.fileExists(atPath: destURL.path) {
                    let name = (file.name as NSString).deletingPathExtension
                    let ext = (file.name as NSString).pathExtension
                    destURL = inboxDir.appendingPathComponent("\(name)-\(counter).\(ext)")
                    counter += 1
                }
                try file.data.write(to: destURL)
            }
            show("\(currentFiles.count) 個のファイルを保存しました")
            NSWorkspace.shared.open(inboxDir)
        } catch {
            show("保存に失敗しました")
        }
    }

    // MARK: - トーストパネル作成

    private func makeToastPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let blur = NSVisualEffectView(frame: panel.contentLayoutRect)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.textColor = .labelColor
        blur.addSubview(label)

        panel.contentView = blur
        return panel
    }
}
