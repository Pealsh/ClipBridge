import AppKit

/// 画面中央下に数秒だけ出る、素っ気ないトースト。
/// 通知センターを使わないので権限も署名も要らない。
final class HUD {

    static let shared = HUD()
    private var window: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var centerWindow: NSPanel?
    private var centerHideWork: DispatchWorkItem?

    private init() {}

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

    func showCenter(_ text: String, from sender: String) {
        assert(Thread.isMainThread)
        centerHideWork?.cancel()

        let panel = centerWindow ?? makeCenterPanel()
        centerWindow = panel

        guard let container = panel.contentView,
              let senderLabel = container.subviews.compactMap({ $0 as? NSTextField }).first,
              let messageLabel = container.subviews.compactMap({ $0 as? NSTextField }).last,
              senderLabel !== messageLabel
        else { return }

        senderLabel.stringValue = sender
        messageLabel.stringValue = text

        // サイズ計算
        let maxWidth: CGFloat = 500
        let font = messageLabel.font ?? NSFont.systemFont(ofSize: 24, weight: .medium)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: 300),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let w = min(max(ceil(bounds.width) + 60, 200), maxWidth + 60)
        let h = max(ceil(bounds.height) + 70, 100)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.midX - w / 2, y: frame.midY - h / 2)
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: false)
        }
        senderLabel.frame = NSRect(x: 20, y: h - 35, width: w - 40, height: 20)
        messageLabel.frame = NSRect(x: 20, y: 15, width: w - 40, height: h - 55)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.dismissCenter() }
        centerHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func dismissCenter() {
        guard let panel = centerWindow else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func makeCenterPanel() -> NSPanel {
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
        blur.addSubview(senderLabel)

        let messageLabel = NSTextField(labelWithString: "")
        messageLabel.font = .systemFont(ofSize: 24, weight: .medium)
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 5
        messageLabel.textColor = .labelColor
        blur.addSubview(messageLabel)

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
