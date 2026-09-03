# ClipBridge

同じ Wi-Fi につながった Mac 同士で、クリップボードを直接やりとりするメニューバーアプリ。

- **⌥V** — 自分のクリップボードを相手に送る
- **⌥C** — 届いた内容を自分のクリップボードに取り込む（あとは ⌘V で貼るだけ）

テキスト・画像・ファイルに対応。サーバーもアカウントも不要で、通信は LAN 内で完結します。

---

## しくみ

| 役割 | 使っている技術 |
|---|---|
| 端末の自動検出 | Bonjour / mDNS（`NWBrowser` + `NWListener`） |
| 通信 | TCP（Network.framework）、長さ前置フレーミング |
| 暗号化 | Curve25519 ECDH → HKDF-SHA256 → ChaCha20-Poly1305 |
| 認証 | 6 桁の照合コード（SAS）で初回ペアリング、以後は公開鍵を記憶 |
| クリップボード | `NSPasteboard`（テキスト / PNG / ファイル URL） |
| ホットキー | Carbon `RegisterEventHotKey`（アクセシビリティ権限は不要） |

同じ LAN 上にいる第三者は、Bonjour の広告こそ見えますが、
**やりとりの中身は復号できません**。ペアリング済みでない端末からの
接続は、ユーザーが承認するまでクリップボードに触れません。

### ペアリングの流れ

1. 2 台とも ClipBridge を起動する（同じ Wi-Fi）
2. 自動で相手を見つけ、両方の画面に **同じ 6 桁の番号** が出る
3. 番号が一致していれば両方で「承認」を押す
4. 以降は自動接続（メニューから解除できます）

番号が違う場合は、間に誰かが割り込んでいる可能性があります。拒否してください。

---

## 動作環境

- macOS 13 Ventura 以降
- Xcode Command Line Tools（ビルドする場合）

---

## インストール

### A. リリース版を使う

1. [Releases](../../releases) から `ClipBridge.zip` をダウンロードして展開
2. `ClipBridge.app` を `/Applications` に入れる
3. **初回だけ**、アプリを右クリック →「開く」→ もう一度「開く」
   （Apple の公証を受けていないため。ダブルクリックだと開けません）

macOS 15 Sequoia 以降では、初回起動時に
「ローカルネットワーク上のデバイスの検出を許可しますか？」と聞かれます。**許可**してください。
拒否すると相手を見つけられません（後から
システム設定 →「プライバシーとセキュリティ」→「ローカルネットワーク」で変更できます）。

### B. 自分でビルドする

```bash
git clone https://github.com/<あなた>/ClipBridge.git
cd ClipBridge
make install      # ビルドして /Applications に入れる
```

その他のターゲット:

```bash
make app      # dist/ClipBridge.app を作る
make run      # ビルドして起動
make zip      # dist/ClipBridge.zip（配布用）
make clean
```

Apple Developer 証明書がある場合:

```bash
CODESIGN_ID="Developer ID Application: Your Name (TEAMID)" make app
```

---

## 使い方

1. 2 台の Mac で ClipBridge を起動（メニューバーにクリップボードのアイコンが出ます）
2. 初回はペアリング（上記）
3. 送りたい側で普通に **⌘C** でコピー → **⌥V** で送信
4. 受け取る側で **⌥C** → **⌘V** で貼り付け

画面下に短いトーストが出るので、送受信できたかはそれで分かります。

### メニューからできること

- 接続中の端末の確認
- 受信ファイルのフォルダ（`~/Downloads/ClipBridge`）を開く
- この Mac の表示名を変更
- ペアリング済み端末の解除
- 受信後に自動で ⌘V を送る（アクセシビリティ権限が必要 / 既定はオフ）
- ネットワークの再接続

### ⌥C を押したとき、まだ何も届いていなかったら

相手に「今のクリップボードをください」と要求します。
つまり **相手が ⌥V を押し忘れていても、受け取る側から引っ張れます**。

---

## 設定

### ホットキーを変える

`~/Library/Application Support/ClipBridge/hotkeys.json` を作って、アプリを再起動します。

```json
{
  "sendKeyCode": 9,
  "sendModifiers": 2048,
  "receiveKeyCode": 8,
  "receiveModifiers": 2048
}
```

- キーコードは Carbon の仮想キーコード（`V` = 9, `C` = 8, `X` = 7, `S` = 1 …）
- 修飾キーは足し算で指定: `⌥ = 2048`, `⌘ = 256`, `⇧ = 512`, `⌃ = 4096`
  - 例: `⌃⌥V` なら `2048 + 4096 = 6144`

### 既定が ⌥V / ⌥C であることの注意

macOS では `⌥V` で「√」、`⌥C` で「ç」が入力できます。
ClipBridge を起動している間、**この 2 つの文字は入力できなくなります**。
記号をよく使う場合は、上の設定で `⌃⌥V` / `⌃⌥C` などに変更してください。

---

## うまく動かないとき

| 症状 | 原因と対処 |
|---|---|
| 相手が見つからない | 同じ Wi-Fi か確認。カフェ・大学・ホテルの Wi-Fi は「クライアント分離」で端末同士が通信できないことがあります。iPhone のテザリングや自宅の Wi-Fi で試してください |
| 「ローカルネットワーク」の許可を間違って拒否した | システム設定 →「プライバシーとセキュリティ」→「ローカルネットワーク」で ClipBridge をオン |
| ⌥V を押しても反応しない | 他のアプリが同じキーを先に取っています。起動時にトーストで警告が出ます。上記の設定で変更してください |
| ペアリングの番号が食い違う | **承認しないでください。** ネットワーク上に割り込みがある可能性があります |
| macOS が「壊れているため開けません」と言う | 未署名アプリの Gatekeeper です。右クリック →「開く」。それでもダメなら `xattr -dr com.apple.quarantine /Applications/ClipBridge.app` |
| 3 台以上つないだ | 全台に同時送信されます（⌥V はブロードキャスト） |

---

## 制限・分かっていること

- 同じ Wi-Fi（同一サブネット）でのみ動作します。インターネット越しには使えません
- 1 回に送れるのは 100 MB まで
- クリップボードの履歴は持ちません。⌥C で取り込むのは「最後に届いた 1 件」だけです
- 前方秘匿性（forward secrecy）はありません。恒久鍵が漏れると、記録された過去の通信を復号できます
- フォルダの送信には未対応（中のファイルを直接選んでください）
- Universal Binary（Apple Silicon + Intel）でビルドされます

---

## セキュリティについて

- 端末の秘密鍵は Keychain に保存されます
- ペアリング済みの公開鍵は `~/Library/Application Support/ClipBridge/trusted.json`
- 相手が送ってきたファイル名はサニタイズされ、`~/Downloads/ClipBridge` の外には書き込みません
- 端末 ID は公開鍵のハッシュなので、ID だけ偽装しても接続は成立しません

このアプリは監査を受けていない個人プロジェクトです。
業務上の機密を扱う用途には、そのつもりでお使いください。

---

## GitHub に公開する手順

```bash
cd ClipBridge
git init
git add .
git commit -m "ClipBridge: LAN クリップボード共有アプリ"

gh repo create ClipBridge --public --source=. --push
# gh がなければ GitHub でリポジトリを作ってから:
#   git remote add origin https://github.com/<あなた>/ClipBridge.git
#   git branch -M main && git push -u origin main
```

リリースを作る:

```bash
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/release.yml` が macOS ランナーでビルドし、
`ClipBridge.zip` を Releases に自動で添付します。

公開前に、`Resources/Info.plist` の `CFBundleIdentifier`
（既定は `com.example.clipbridge`）を自分のものに書き換えてください。

---

## ライセンス

MIT
