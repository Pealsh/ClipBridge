import AppKit

// メニューバー常駐アプリのエントリポイント。
// Info.plist の LSUIElement = true により Dock には出ない。

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
