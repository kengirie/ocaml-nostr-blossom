# OCaml Blossom Server 実装計画書

## 1. プロジェクト概要
OCaml 5 (Eio) と Piaf を用いた Nostr Blossom サーバーの実装計画です。
アーキテクチャとして「Functional Core, Imperative Shell」を採用し、並行処理には Eio を活用します。

### Blossom Core
#### [NEW] [bip340.ml](file:///Users/iriekengo/ocaml-nostr-blossom/ocaml-nostr-blossom/lib/core/bip340.ml)
- Implement Schnorr signature verification using Ctypes and libsecp256k1.
- Based on reference implementation from `andunieee/bip340`.
- Use `Digestif` for SHA256 hashing.

#### [NEW] [auth.ml](file:///Users/iriekengo/ocaml-nostr-blossom/ocaml-nostr-blossom/lib/core/auth.ml)
- Implement NIP-98 authentication logic.
- Use `Bip340.verify` for signature verification.
- Parse and validate Authorization header.

#### [MODIFY] [auth.ml](file:///Users/iriekengo/ocaml-nostr-blossom/ocaml-nostr-blossom/lib/core/auth.ml)
- **Spec Compliance:**
    - Update `validate_auth` and `validate_event_structure` to accept optional `blob_sha256`.
    - Implement `x` tag validation: if `blob_sha256` is provided, ensure it exists in `x` tags.
    - Ensure `content` is not empty (basic check for human-readable string).

#### [MODIFY] [dune](file:///Users/iriekengo/ocaml-nostr-blossom/ocaml-nostr-blossom/lib/core/dune)
- Add dependencies: `ctypes`, `ctypes.foreign`, `digestif`, `yojson`, `base64`.

## 2. アーキテクチャ設計
詳細な設計は `architecture_design.md` および `concurrency_design.md` を参照してください。

*   **Core (Functional)**: 純粋なビジネスロジック、バリデーション、型定義。
*   **Shell (Imperative)**: HTTPサーバー (Piaf)、ファイルI/O (Eio)、副作用の管理。

## 3. ディレクトリ構成
```
lib/
├── core/                # [Core] 純粋なロジック
│   ├── domain.ml        # 型定義 (BlobDescriptorなど)
│   ├── integrity.ml     # 整合性チェック
│   ├── policy.ml        # ポリシーチェック
│   └── auth.ml          # 認証ロジック
├── shell/               # [Shell] 副作用層
│   ├── local_storage.ml # ファイルシステム操作 (Eio)
│   └── http_server.ml   # Piafサーバー設定、ルーティング
bin/
└── main.ml              # エントリーポイント
test/
├── test_core.ml         # Coreのユニットテスト
└── test_integration.ml  # 統合テスト
```

## 4. 実装フェーズ

### Phase 1: 基本サーバーとGETエンドポイント (BUD-01)
まずは最小限の構成で、ファイルをハッシュ指定で取得できる機能を実装します。

*   **Core**:
    *   `blob_descriptor` 型の定義 (`domain.ml`)。
    *   SHA256ハッシュ文字列のバリデーションロジック (`integrity.ml`)。
*   **Shell**:
    *   `Local_storage.get`: Eioを用いたファイル読み込み。
    *   `Http_server`: Piafサーバーのセットアップ。
    *   `GET /<sha256>` ハンドラの実装。
*   **検証**:
    *   手動で配置したファイルを `curl` で取得できるか確認。

### Phase 2: アップロード機能 (BUD-02)
Blobのアップロード機能を追加します。

*   **Core**:
    *   ファイルサイズ、MIMEタイプのバリデーション (`policy.ml`)。
    *   アップロード後のハッシュ計算と整合性チェック (`integrity.ml`)。
*   **Shell**:
    *   `PUT /upload` ハンドラの実装。
    *   `Local_storage.save`: ストリームからのファイル保存とハッシュ計算。
        *   *Note*: `Digestif` を用いたインクリメンタルハッシュ計算を実装。
    *   保存後のメタデータ返却。

### Phase 3: 認証と権限 (BUD-01 Auth, BUD-04)
NIP-98 (HTTP Auth) に基づく認証を実装します。

*   **Core**:
    *   Nostrイベント (Kind 24242) の署名検証 (`auth.ml`)。
    *   Authorizationヘッダーの解析 (`auth.ml`)。
    *   アクション (upload, get) に対する権限チェックロジック (`policy.ml` / `auth.ml`)。
*   **Shell**:
    *   `Verifier` モジュールの実装: `Eio.Executor_pool` を使用して署名検証を並列化。
    *   認証ミドルウェアの導入。

### Phase 4: 高度な機能と最適化
*   **Core**:
    *   リスト表示のフィルタリングロジック。
*   **Shell**:
    *   `GET /list/<pubkey>` の実装。
    *   SQLiteの導入 (メタデータ管理用)。
    *   **Worker Poolの本格導入**:
        *   `Media_processor` モジュールの実装。
        *   画像リサイズ・動画トランスコード処理の非同期実行 (`Eio.Process` または `Executor_pool`)。

## 5. テスト計画
*   **Unit Test**: `Core` モジュールに対して Alcotest を用いて網羅的にテストします。
*   **Integration Test**: 実際にサーバーを起動し、Piaf Client からリクエストを投げて動作を検証します。

export DYLD_INSERT_LIBRARIES=/usr/local/lib/libsecp256k1.dylib && eval $(opam env) && dune runtest
