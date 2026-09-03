import AppKit

/// ペアリング確認ダイアログ。
///
/// 両方の Mac に同じ 6 桁が出る。数字が一致していれば、その接続に
/// 中間者はいない（偽装するには 100 万分の 1 を当てる必要がある）。
enum PairingPrompt {

    private static var isShowing = false
    private static var queueOfRequests: [(String, String, (Bool) -> Void)] = []

    static func present(sas: String, peerName: String, completion: @escaping (Bool) -> Void) {
        assert(Thread.isMainThread)

        guard !isShowing else {
            queueOfRequests.append((sas, peerName, completion))
            return
        }
        isShowing = true

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "「\(peerName)」とペアリングしますか？"
        alert.informativeText = """
        両方の Mac に表示されている 6 桁の番号が同じであることを確認してください。
        違う番号が出ている場合は「拒否」を押してください。

        \tペアリングコード:  \(formatted(sas))

        一度承認すると、次回からは自動で接続します。
        """
        alert.addButton(withTitle: "番号が一致 → 承認")
        alert.addButton(withTitle: "拒否")

        // 誤って承認しないよう、既定ボタンは「拒否」にしておく
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"

        let response = alert.runModal()
        let approved = (response == .alertFirstButtonReturn)

        isShowing = false
        completion(approved)

        if !queueOfRequests.isEmpty {
            let next = queueOfRequests.removeFirst()
            DispatchQueue.main.async {
                present(sas: next.0, peerName: next.1, completion: next.2)
            }
        }
    }

    private static func formatted(_ sas: String) -> String {
        guard sas.count == 6 else { return sas }
        let i = sas.index(sas.startIndex, offsetBy: 3)
        return "\(sas[sas.startIndex..<i]) - \(sas[i...])"
    }
}
