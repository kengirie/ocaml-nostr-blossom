# OCaml Blossom Server アーキテクチャ設計書

## 1. 概要
本プロジェクトは、Nostrのエコシステムで使用されるBlossom (Blobs stored simply on mediaservers) 仕様に準拠したサーバーをOCamlで実装することを目的とします。
HTTPサーバーライブラリとして **Piaf** を使用し、並行処理ライブラリとして **Eio** (OCaml 5) を採用します。
設計方針として「Functional Core, Imperative Shell」を採用し、テスタビリティと堅牢性を高めます。

## 2. アーキテクチャ方針: Functional Core, Imperative Shell

システムを「副作用のない純粋なコア（Functional Core）」と「副作用を扱うシェル（Imperative Shell）」に明確に分離します。

### 2.1. Functional Core (純粋関数群)
ビジネスロジック、バリデーション、データ変換を担当します。ここにはI/O操作（ファイル読み書き、ネットワーク通信、現在時刻の取得など）を含めません。

*   **モジュール名**: `Blossom_core` (または `Blossom_lib`)
*   **責務**:
    *   **Nostrイベント検証**: 署名の検証、Kindのチェック、タグの解析。
    *   **Blossom仕様のロジック**:
        *   アップロード可否の判定（ファイルサイズ、MIMEタイプ、ハッシュ値の整合性）。
        *   Authorizationヘッダーの解析と検証 (BUD-01, BUD-02)。
    *   **データモデル定義**: `BlobDescriptor` などの型定義。
*   **テスト**:
    *   外部依存がないため、高速かつ決定論的なユニットテストが可能。
    *   Alcotestなどを利用。

### 2.2. Imperative Shell (副作用層)
Functional Coreを呼び出し、実際のI/O操作を行います。PiafとEioがここで活躍します。

*   **モジュール名**: `Blossom_server`, `Blossom_store`
*   **責務**:
    *   **HTTPサーバー (Piaf)**: リクエストの受信、レスポンスの送信、ルーティング。
    *   **ファイルストレージ (Eio)**: Blobデータのディスクへの保存、読み出し。
    *   **並行処理 (Eio)**: 複数リクエストの同時処理。
    *   **DB/インデックス**: メタデータ（アップロード者、時刻など）の管理。

## 3. 並行処理・並列処理設計 (Eio & OCaml 5)

PiafはEioベースで構築されており、HTTPリクエストの多重化はPiafが自動的にEioのファイバー（軽量スレッド）を用いて処理します。

### 3.1. I/Oバウンド処理 (Concurrency)
*   **Fiber (Eio)**: HTTPリクエスト処理やファイルI/Oは、EioのFiber（軽量スレッド）を用いて並行処理します。
*   **Piafの役割**: Piafは内部でEioを使用しており、各リクエストを個別のFiberで処理することで、多数の同時接続を効率的にさばきます。
*   **メインドメイン**: 基本的なリクエスト処理（GET, HEAD, PUT /upload）は、メインのドメイン上のFiberで実行し、ドメイン間通信のオーバーヘッドを回避します。

### 3.2. CPUバウンド処理 (Parallelism)
*   **Domain (Eio)**: ハッシュ計算やメディア処理など、CPUリソースを大量に消費する処理は、EioのDomain（OSスレッド）を用いて並列化します。
*   **Worker Pool**: `Eio.Executor_pool` を使用してWorker Poolを構築し、重いタスクをオフロードします。
    *   **対象**: SHA256ハッシュ計算（大容量ファイル）、画像処理（BUD-05）、大量の署名検証など。
    *   **粒度**: 数ミリ秒（2-5ms）以上かかる処理をプールに投げます。

### 3.3. 状態管理と安全性
*   **Immutable Data**: 可能な限り不変データ構造を使用します。
*   **同期プリミティブ**: 共有リソース（DB接続など）へのアクセスは `Eio.Mutex` 等で保護します。

## 4. モジュール構成案

```
lib/
├── core/                # [Core] 純粋なロジック
│   ├── domain.ml        # 型定義 (BlobDescriptorなど)
│   ├── integrity.ml     # 整合性チェック (Hash検証など)
│   ├── policy.ml        # ポリシーチェック (MIME, Size)
│   └── auth.ml          # 認証ロジック (NIP-98)
├── shell/               # [Shell] 副作用層
│   ├── local_storage.ml # ファイルシステム操作 (Eio)
│   └── http_server.ml   # Piafサーバー設定、ルーティング
bin/
└── main.ml              # [Shell] エントリーポイント (Eio_main.run)
test/
├── test_core.ml         # Coreのユニットテスト
└── test_integration.ml  # サーバーの統合テスト
```

### 4.1. Coreモジュール詳細設計

#### `Domain` (lib/core/domain.ml)
ドメインモデル（型定義）のみを持ちます。

```ocaml
type blob_descriptor = {
  url : string;
  sha256 : string;
  size : int;
  mime_type : string;
  uploaded : int64;
}

type error =
  | Invalid_hash of string
  | Invalid_size of int
  | Blob_not_found of string
  | Storage_error of string
```

#### `Integrity` (lib/core/integrity.ml)
基本的なデータの整合性を検証します。

```ocaml
(* SHA256ハッシュ文字列の形式検証 *)
val validate_hash : string -> bool
(* ファイルサイズが負でないかなど *)
val validate_size : int -> (unit, error) result
```

#### `Policy` (lib/core/policy.ml)
サーバーの運用ルール（設定）に基づく検証を行います。

```ocaml
(* MIMEタイプが許可されているか、サイズ制限内か *)
val check_upload_policy :
  size:int ->
  mime:string ->
  pubkey:string option ->
  (unit, error) result
```

#### `Auth` (lib/core/auth.ml)
認証ロジックを担当します。

```ocaml
(* NIP-98 Authorizationヘッダーの検証 (Phase 3) *)
val validate_header :
  header:string ->
  method_:string ->
  url:string ->
  (string, error) result (* 成功時はpubkeyを返す *)
```

### 4.2. Shellモジュール詳細設計

#### `Local_storage` (lib/shell/local_storage.ml)
Eioを使用したファイル操作を担当します。

```ocaml
(* Blobの保存 *)
val save :
  dir:Eio.Path.t ->
  data:string ->
  sha256:string ->
  (unit, error) result

(* Blobの取得 *)
val get :
  dir:Eio.Path.t ->
  sha256:string ->
  (string, error) result

(* 存在確認 *)
val exists :
  dir:Eio.Path.t ->
  sha256:string ->
  bool
```

#### `Http_server` (lib/shell/http_server.ml)
Piafサーバーの構築とハンドリングを担当します。

```ocaml
(* サーバーの起動 *)
val start :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  port:int ->
  unit
```

## 5. 実装フェーズ計画

実装は「小さく始めて大きく育てる」方針で行います。

### Phase 1: 基本的なBlob取得 (BUD-01)
*   **Core**: SHA256ハッシュ検証ロジック。
*   **Shell**:
    *   Piafサーバーの立ち上げ。
    *   `GET /<sha256>`: 指定されたハッシュのファイルを返す（ファイルシステムから読み込み）。
    *   `HEAD /<sha256>`: 存在確認。
*   **目的**: Piaf + Eioの基本動作確認と、Core/Shell分離の確立。

### Phase 2: Blobアップロード (BUD-02)
*   **Core**:
    *   `PUT /upload` のリクエスト検証（Content-Lengthなど）。
    *   アップロード後のハッシュ計算と検証ロジック。
*   **Shell**:
    *   `PUT /upload`: ボディを受け取り、ファイルに保存。
    *   保存したファイルのハッシュを計算し、レスポンスを返す。

### Phase 3: 認証と権限管理 (BUD-01, BUD-02 Auth)
*   **Core**:
    *   Nostrイベント（Kind 24242）の署名検証ロジック。
    *   Authorizationヘッダーのパースと検証。
    *   アクション（upload, get, delete）ごとの権限チェック。
*   **Shell**:
    *   各エンドポイントに認証ミドルウェア（またはハンドラ内チェック）を追加。

### Phase 4: リスト表示とその他のBUD (BUD-02 List, etc)
*   **Core**: リストフィルタリングのロジック。
*   **Shell**:
    *   `GET /list/<pubkey>`: 保存されたBlobのメタデータを検索して返す。
    *   SQLiteなどの軽量DB導入を検討（ファイルシステム走査は遅いため）。

## 6. テスト戦略

*   **Unit Test**: `Blossom_core` に対して集中的に行う。エッジケース（不正なハッシュ、期限切れのイベントなど）を網羅する。
*   **Integration Test**: 実際にサーバーを立ち上げ（`Eio_main.run`）、Piaf Clientからリクエストを投げて挙動を確認する。

この設計に基づき、まずはPhase 1の実装から開始します。
