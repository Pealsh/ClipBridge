import AppKit

/// 画面中央下に数秒だけ出る、素っ気ないトースト。
/// 通知センターを使わないので権限も署名も要らない。
final class HUD {

    static let shared = HUD()
    private var window: NSPanel?
    private var hideWork: DispatchWorkItem?

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
