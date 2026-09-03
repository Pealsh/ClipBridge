import AppKit

/// 画面中央下に数秒だけ出る、素っ気ないトースト。
/// 通知センターを使わないので権限も署名も要らない。
final class HUD {

    static let shared = HUD()
    private var window: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var centerWindow: NSPanel?
    private var centerHideWork: DispatchWorkItem?
    private let speechSynthesizer = NSSpeechSynthesizer()

    private init() {
        // 日本語の音声があれば使用
        if let japaneseVoice = NSSpeechSynthesizer.availableVoices.first(where: {
            $0.rawValue.contains("ja") || $0.rawValue.contains("Kyoko") || $0.rawValue.contains("Otoya")
        }) {
            speechSynthesizer.setVoice(japaneseVoice)
        }
    }

    func show(_ text: String) {
        assert(Thread.isMainThread)
        hideWork?.cancel()

        let panel = window ?? makePanel()
        window = panel

        guard let label = panel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first
        else { return }
        label.stringValue = text

        // 文字幅に合わせてリサイズ
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
            // 画面上部に表示（メニューバーの少し下）
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

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func dismiss() {
        guard let panel = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    // MARK: - 画面中央に大きく表示（メッセージ通知用）

    func showCenter(_ text: String, image: Data?, from sender: String) {
        assert(Thread.isMainThread)
        centerHideWork?.cancel()

        // 既存のパネルを閉じて新しく作り直す（画像有無でレイアウトが変わるため）
        centerWindow?.orderOut(nil)
        let panel = makeCenterPanel(hasImage: image != nil)
        centerWindow = panel

        guard let container = panel.contentView else { return }

        let senderLabel = container.subviews.compactMap({ $0 as? NSTextField }).first { $0.tag == 1 }
        let messageLabel = container.subviews.compactMap({ $0 as? NSTextField }).first { $0.tag == 2 }
        let imageView = container.subviews.compactMap({ $0 as? NSImageView }).first

        senderLabel?.stringValue = sender
        messageLabel?.stringValue = text

        // 画像を設定
        if let imageData = image, let nsImage = NSImage(data: imageData) {
            imageView?.image = nsImage
        }

        // サイズ計算
        let maxWidth: CGFloat = 500
        let font = messageLabel?.font ?? NSFont.systemFont(ofSize: 24, weight: .medium)
        let textBounds = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: 300),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])

        var w = min(max(ceil(textBounds.width) + 60, 200), maxWidth + 60)
        var h = max(ceil(textBounds.height) + 70, 100)

        // 画像がある場合はサイズを調整
        if let imageData = image, let nsImage = NSImage(data: imageData) {
            let imgSize = nsImage.size
            let maxImgWidth: CGFloat = 400
            let maxImgHeight: CGFloat = 300
            let scale = min(maxImgWidth / imgSize.width, maxImgHeight / imgSize.height, 1.0)
            let imgW = imgSize.width * scale
            let imgH = imgSize.height * scale
            w = max(w, imgW + 60)
            h += imgH + 10
            imageView?.frame = NSRect(x: (w - imgW) / 2, y: 15, width: imgW, height: imgH)
            messageLabel?.frame = NSRect(x: 20, y: imgH + 25, width: w - 40, height: ceil(textBounds.height) + 10)
        } else {
            messageLabel?.frame = NSRect(x: 20, y: 15, width: w - 40, height: h - 55)
        }

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.midX - w / 2, y: frame.midY - h / 2)
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: false)
        }
        senderLabel?.frame = NSRect(x: 20, y: h - 35, width: w - 40, height: 20)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        // メッセージを読み上げ
        if !text.isEmpty {
            speechSynthesizer.stopSpeaking()
            speechSynthesizer.startSpeaking(text)
        }

        // 画像がある場合は長めに表示
        let duration = image != nil ? 6.0 : 4.0
        let work = DispatchWorkItem { [weak self] in self?.dismissCenter() }
        centerHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func dismissCenter() {
        guard let panel = centerWindow else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func makeCenterPanel(hasImage: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .floating
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
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        let senderLabel = NSTextField(labelWithString: "")
        senderLabel.font = .systemFont(ofSize: 12, weight: .regular)
        senderLabel.alignment = .center
        senderLabel.textColor = .secondaryLabelColor
        senderLabel.tag = 1
        blur.addSubview(senderLabel)

        let messageLabel = NSTextField(labelWithString: "")
        messageLabel.font = .systemFont(ofSize: 24, weight: .medium)
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 5
        messageLabel.textColor = .labelColor
        messageLabel.tag = 2
        blur.addSubview(messageLabel)

        if hasImage {
            let imageView = NSImageView(frame: .zero)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 8
            imageView.layer?.masksToBounds = true
            blur.addSubview(imageView)
        }

        panel.contentView = blur
        return panel
    }

    private func makePanel() -> NSPanel {
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
