# ClipBridge — Claude Code 向けプロジェクトメモ

同じ LAN 上の Mac 同士でクリップボード（テキスト / 画像 / ファイル）を
やりとりする、メニューバー常駐アプリ。macOS 13+ / Swift / SwiftPM。

## 最重要: 現在の状態

**このコードはまだ一度もコンパイルされていません。**
クラウド環境（Linux）で書かれたため AppKit / CryptoKit / Network が無く、
型チェックが通っていない。最初にやるべきことは:

```bash
swift build -c debug 2>&1 | head -50
```

型エラーが数個出る前提で、まずそれを潰すこと。
特に怪しいと自覚している箇所は下の「未検証な箇所」を参照。

## ビルドと実行

```bash
make app       # dist/ClipBridge.app を組み立てる
make run       # ビルドして起動
make install   # /Applications に入れる
make zip       # 配布用 zip
make clean
swift build -c debug        # 型チェックだけしたいとき
```

`.app` バンドルは Makefile が手で組み立てている（Xcode プロジェクトは無い）。
Info.plist は `Resources/Info.plist`。

**動作確認には Mac が 2 台必要**。1 台では相手が見つからないので、
自分自身への接続は `handleHello` で明示的に弾いている。
1 台で試したい場合は `Identity` を 2 系統持てるようにするデバッグフラグが要る。

## アーキテクチャ

```
main.swift          NSApplication のエントリポイント（top-level code）
AppDelegate.swift   メニューバー UI、ホットキー配線、inbox 管理
  ├ PeerManager     Bonjour 発見 + 接続レジストリ
  │   └ PeerConnection   1 接続ぶんのハンドシェイク / 暗号化 I/O
  │         └ CryptoBox  ECDH → HKDF → ChaChaPoly、SAS 生成
  ├ ClipboardService NSPasteboard 読み書き
  ├ HotKeyManager    Carbon RegisterEventHotKey
  ├ HUD              画面下のトースト（NSPanel）
  └ PairingPrompt    SAS 照合ダイアログ（NSAlert）

Identity.swift      端末鍵（Keychain）+ TrustStore（trusted.json）
Protocol.swift      フレーミング、Hello、MessageHeader、ClipContent
Config.swift        定数、HotKeyConfig、パス、ログ
```

### ワイヤープロトコル

TCP 上に `[4 バイト BE 長][本体]` の繰り返し。

1. 接続直後、双方が **平文の Hello** を 1 フレームずつ送る
   （version / deviceID / deviceName / 公開鍵 / 32 バイト nonce）
2. 以降は全フレームが ChaChaPoly で暗号化された Envelope
   復号後は `[4 バイト BE ヘッダ長][JSON ヘッダ][バイナリ本体]`

メッセージ種別: `clip` / `pull` / `pairack` / `ack` / `ping`

### 設計上の決めごと（変更する前に読むこと）

- **deviceID = 公開鍵 SHA-256 の先頭 8 バイト。** ID だけ偽装しても
  `handleHello` の突き合わせで落ちる。ここは崩さない。
- **方向ごとに別の対称鍵**（initiator→responder / responder→initiator）。
  カウンタ nonce を両方向で使い回さないため。
- **ペアリングは双方の承認が揃うまで確定しない。** `localPairApproved` と
  `remotePairApproved` の両方が true になって初めて TrustStore に書く。
- **二重接続の回避は「自分の deviceID が小さいときだけ発信する」**という
  単純な規則（`dialPendingPeers`）。対称な発信を許すと接続が 2 本張られる。
- **ハンドシェイク中の PeerConnection は `PeerManager.pending` が強参照で保持**
  している。これを外すと接続確立前に解放されて無言で失敗する（実際に踏んだ）。
  `pending` は `queue` ではなく `pendingLock` で守る（append を同期的に行うため）。
- **ホットキーは Carbon**。CGEventTap ではないのでアクセシビリティ権限が要らない。
  権限が要るのは「受信後の自動 ⌘V」だけで、既定はオフ。

### スレッド

- `PeerManager.connections` / `discovered` / `dialing` → `queue`（直列）
- `PeerManager.pending` → `pendingLock`
- `PeerConnection` の I/O → 各接続の `queue`
- `state` / `peerID` / `peerName` → `stateLock`（他スレッドから読まれる）
- delegate 呼び出しは必ず main へホップしてから

## 未検証な箇所（優先的に疑う）

1. `HotKeyManager` の `EventHandlerUPP` クロージャ。`@convention(c)` として
   通るか、`GetEventParameter` の引数の型が合っているか
2. `NWTXTRecord` の subscript setter、`NWListener.Service(name:type:domain:txtRecord:)`、
   `.bonjourWithTXTRecord` の可用性
3. `SharedSecret.hkdfDerivedSymmetricKey(using:salt:sharedInfo:outputByteCount:)` の
   ジェネリック推論
4. `private(set) var state: State { get { } set { } }` の書き方（計算プロパティに
   private(set) を付けている）
5. `ChaChaPoly.SealedBox(nonce:ciphertext:tag:)` に Data のスライスを渡している箇所
6. HUD の `NSPanel` レイアウト（実際に見ないと位置とサイズは分からない）

## 手を付けやすい改善候補

- 1 台でテストするためのデバッグモード（環境変数で Identity を分ける）
- 送信履歴（現状は inbox が最後の 1 件だけ）
- フォルダ送信（現状は個別ファイルのみ）
- 前方秘匿性（ephemeral 鍵 + Ed25519 署名。今は恒久鍵 ECDH のみ）
- 大きいファイルのストリーミング（現状は全部メモリに載せる、上限 100MB）
- ペアリング済み端末が見つからないときの UI フィードバック

## やらないこと

- インターネット越しの中継（LAN 限定という前提を崩さない）
- クリップボードの自動同期（明示的な ⌥V / ⌥C のままにする。事故が起きにくい）
