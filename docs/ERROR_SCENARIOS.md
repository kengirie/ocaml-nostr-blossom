# Error Scenarios Documentation

OCaml Nostr Blossom サーバーで発生しうるエラーシナリオの網羅的なドキュメント。

---

## 目次

1. [コアエラー型](#1-コアエラー型)
2. [認証・認可エラー](#2-認証認可エラー)
3. [データ検証エラー](#3-データ検証エラー)
4. [ストレージ・ファイルシステムエラー](#4-ストレージファイルシステムエラー)
5. [データベースエラー](#5-データベースエラー)
6. [Blob サービスエラー](#6-blob-サービスエラー)
7. [HTTP レスポンスエラー](#7-http-レスポンスエラー)
8. [HTTP サーバーエラー](#8-http-サーバーエラー)
9. [起動・初期化エラー](#9-起動初期化エラー)
10. [署名検証エラー](#10-署名検証エラー)
11. [エラーハンドリングアーキテクチャ](#11-エラーハンドリングアーキテクチャ)

---

## 1. コアエラー型

**ファイル**: `lib/core/domain.ml`

| エラー型 | 説明 |
|---------|------|
| `Invalid_hash of string` | SHA256 ハッシュ検証失敗 |
| `Invalid_size of int` | ファイルサイズ検証失敗 |
| `Blob_not_found of string` | ストレージ/DB に Blob が見つからない |
| `Storage_error of string` | 汎用ストレージ/データベースエラー |

---

## 2. 認証・認可エラー

**ファイル**: `lib/core/auth.ml`

### 2.1 ヘッダー解析エラー

| エラー | メッセージ | 条件 | 行番号 |
|--------|-----------|------|--------|
| 無効な Authorization ヘッダー形式 | `"Invalid Authorization header format"` | ヘッダーが `"Nostr <base64>"` パターンに一致しない | L50 |
| JSON パースエラー | `"JSON parse error: {msg}"` | Base64 デコード後の JSON パース失敗 | L52 |
| ヘッダー解析失敗（その他） | `"Failed to parse Authorization header"` | 解析中のその他の例外 | L53 |

### 2.2 イベント検証エラー

| エラー | メッセージ | 条件 | 行番号 |
|--------|-----------|------|--------|
| 無効なイベント種別 | `"Invalid event kind, must be 24242"` | Nostr イベント kind が 24242 ではない | L57 |
| 未来の作成時刻 | `"Event created_at is in the future"` | `event.created_at > current_time` | L59 |
| 有効期限タグ欠落 | `"Missing expiration tag"` | イベントに "expiration" タグがない | L62 |
| イベント期限切れ | `"Event has expired"` | `expiration <= current_time` | L67 |
| アクションタグ欠落 | `"Missing t tag"` | イベントに "t" タグがない | L70 |
| 無効なアクション | `"Invalid action, expected {upload\|get\|delete}"` | "t" タグがリクエストアクションと一致しない | L73 |
| 無効な有効期限形式 | `"Invalid expiration timestamp"` | expiration タグを Int64 にパースできない | L76 |

### 2.3 フィールド長検証エラー

| エラー | メッセージ | 条件 | 行番号 |
|--------|-----------|------|--------|
| 無効なイベント ID 長 | `"Invalid event ID length"` | イベント ID が 64 文字ではない | L81 |
| 無効な公開鍵長 | `"Invalid pubkey length"` | 公開鍵が 64 文字ではない | L83 |
| 無効な署名長 | `"Invalid signature length"` | 署名が 128 文字ではない | L85 |

### 2.4 署名検証エラー

| エラー | メッセージ | 条件 | 行番号 |
|--------|-----------|------|--------|
| 署名無効 | `"Invalid signature"` | BIP340 署名がイベントデータと一致しない | L91 |
| 署名検証失敗 | `"Signature verification failed"` | 検証中の例外 | L92 |

---

## 3. データ検証エラー

### 3.1 整合性検証 (`lib/core/integrity.ml`)

| エラー | 条件 | 結果 |
|--------|------|------|
| 無効なハッシュ形式 | SHA256 ハッシュが 64 文字の 16 進数ではない | `false` 返却 |
| 負のファイルサイズ | `size < 0` | `Invalid_size size` |

### 3.2 ポリシー検証 (`lib/core/policy.ml`)

| エラー | メッセージ | 条件 | 行番号 |
|--------|-----------|------|--------|
| 負のファイルサイズ | `Invalid_size size` | `size < 0` | L15 |
| ファイルサイズ超過 | `"File too large: {size} bytes (max: {max_size})"` | `size > policy.max_size`（デフォルト: 100MB） | L17 |
| 空の MIME タイプ | `"Empty MIME type"` | `String.length mime = 0` | L22 |
| 許可されていない MIME タイプ | `"MIME type not allowed: {mime}"` | MIME タイプが許可リストにない | L28 |

---

## 4. ストレージ・ファイルシステムエラー

**ファイル**: `lib/shell/storage_eio.ml`

### 4.1 Eio 例外マッピング

| 元の例外 | 変換後 | 行番号 |
|---------|--------|--------|
| `Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _)` | `Domain.Blob_not_found path` | L20-21, L102-103, L115-116 |
| `Eio.Io (Eio.Fs.E (Eio.Fs.Permission_denied _), _)` | `Domain.Storage_error "Permission denied"` | L22-23, L104-105, L117-118 |
| その他の例外 | `Domain.Storage_error (Printexc.to_string exn)` | L24-25, L106-107, L119-120 |

### 4.2 ストリーム・ファイル操作エラー

| エラー | 条件 | 処理 | 行番号 |
|--------|------|------|--------|
| ストリーム書き込み失敗 | ファイル書き込み中の例外 | 一時ファイル削除 | L48-73 |
| ファイルリネーム失敗 | 一時→最終ファイルリネーム失敗 | 一時ファイル削除 | L71-73 |
| Body Fold エラー | Piaf ストリーム処理失敗 | `Domain.Storage_error (Piaf.Error.to_string e)` | L56-59 |

---

## 5. データベースエラー

**ファイル**: `lib/shell/blossom_db.ml`

### 5.1 Caqti エラー

| エラー | 条件 | 結果 | 行番号 |
|--------|------|------|--------|
| コネクションプール初期化失敗 | DB 接続失敗 | `Domain.Storage_error (Caqti_error.show e)` | L61 |
| テーブル作成失敗 | blobs テーブル/インデックス作成失敗 | `Domain.Storage_error (Caqti_error.show e)` | L72 |
| Blob 保存失敗 | INSERT/UPDATE 失敗 | `Domain.Storage_error (Caqti_error.show e)` | L82 |
| Blob 未検出 | `find_opt` が `Ok None` を返す | `Domain.Blob_not_found sha256` | L99 |
| Blob 取得クエリ失敗 | クエリ実行失敗 | `Domain.Storage_error (Caqti_error.show e)` | L100 |

### 5.2 DB 制約エラー

| 制約 | 説明 |
|------|------|
| 主キー制約違反 | `ON CONFLICT` で処理 |
| Status 制約チェック | `stored\|deleted\|quarantined` のみ許可 |

---

## 6. Blob サービスエラー

**ファイル**: `lib/shell/blob_service.ml`

### 6.1 アップロード/保存フロー

| エラー | 条件 | 結果 | 行番号 |
|--------|------|------|--------|
| ストレージ保存エラー | `Storage.save` 失敗 | エラー伝播 | L44-45 |
| DB 保存エラー（ファイル保存後） | ファイル保存成功後 DB 挿入失敗 | ファイル自動削除、DB エラー返却 | L63-66 |
| MIME タイプ検出失敗 | 検出失敗 | 提供された MIME タイプにフォールバック（非致命的） | L48-57 |

### 6.2 取得/メタデータフロー

| エラー | 条件 | 結果 | 行番号 |
|--------|------|------|--------|
| DB に Blob 未検出 | DB 検索結果なし | `Domain.Blob_not_found sha256` | L80, L101 |
| ファイル存在確認エラー | `Storage.exists` 失敗 | ストレージエラー伝播 | L72-73, L82-83, L107-108 |
| ファイル欠落 | DB にメタデータあり、ファイルなし | `Domain.Blob_not_found sha256` | L74, L84, L109 |
| ファイルサイズ取得エラー | `Storage.stat` 失敗 | ストレージエラー伝播 | L87-88 |
| ストリーム取得エラー | `Storage.get` 失敗 | ストレージエラー伝播 | L77-78, L91-92 |

---

## 7. HTTP レスポンスエラー

**ファイル**: `lib/shell/http_response.ml`

### 7.1 レスポンス種別

| 種別 | HTTP ステータス | 説明 |
|------|----------------|------|
| `Error_not_found of string` | 404 Not Found | リソース未検出 |
| `Error_unauthorized of string` | 401 Unauthorized | 認証失敗 |
| `Error_bad_request of string` | 400 Bad Request | リクエスト不正 |
| `Error_internal of string` | 500 Internal Server Error | 内部エラー |

### 7.2 共通レスポンスヘッダー

すべてのエラーレスポンスに含まれるヘッダー:
- `x-reason`: エラーメッセージ
- `access-control-allow-origin: *`
- `access-control-allow-methods: *`
- `access-control-allow-headers: Authorization, Content-Type, Content-Length, *`
- `access-control-expose-headers: *`

---

## 8. HTTP サーバーエラー

**ファイル**: `lib/shell/http_server.ml`

### 8.1 Domain エラーから HTTP レスポンスへの変換

```ocaml
let error_to_response_kind = function
  | Domain.Blob_not_found _ -> Http_response.Error_not_found "Blob not found"
  | Domain.Storage_error msg -> Http_response.Error_internal msg
  | Domain.Invalid_size s -> Http_response.Error_bad_request (Printf.sprintf "Invalid size: %d" s)
  | Domain.Invalid_hash h -> Http_response.Error_bad_request (Printf.sprintf "Invalid hash: %s" h)
```

### 8.2 GET リクエストエラー

| エラー | メッセージ | ステータス | 条件 | 行番号 |
|--------|-----------|-----------|------|--------|
| 無効なハッシュ形式 | `"Invalid path or hash"` | 404 | `Integrity.validate_hash` 失敗 | L45-46, L63-64 |
| 無効なパス構造 | `"Invalid path"` | 404 | パスセグメント数不正 | L56, L73 |
| Blob 未検出 | `"Blob not found"` | 404 | `BlobService.get` が `Blob_not_found` を返す | L48-55, L66-72 |
| ストレージ/内部エラー | ストレージエラーメッセージ | 500 | `BlobService.get` が `Storage_error` を返す | L55, L72 |

### 8.3 PUT /upload エラー

| エラー | メッセージ | ステータス | 条件 | 行番号 |
|--------|-----------|-----------|------|--------|
| Authorization ヘッダー欠落 | `"Missing Authorization header"` | 401 | ヘッダーなし | L76-77 |
| 認証検証失敗 | `"Authentication failed"` または具体的メッセージ | 401 | `Auth.validate_auth` 失敗 | L80-82 |
| ポリシー違反 | `"File too large: ..."` または `"MIME type not allowed: ..."` | 400 | `Policy.check_upload_policy` 失敗 | L101-102 |
| 保存操作失敗 | ストレージエラーメッセージ | 500 | `BlobService.save` 失敗 | L104-111 |

### 8.4 その他

| エラー | メッセージ | ステータス | 条件 | 行番号 |
|--------|-----------|-----------|------|--------|
| 不明なパス | `"Not found"` | 404 | どのハンドラにも一致しない | L124 |

---

## 9. 起動・初期化エラー

**ファイル**: `bin/main.ml`

| エラー | メッセージ | 処理 | 行番号 |
|--------|-----------|------|--------|
| DB 初期化失敗 | `"Database initialization failed: {error}"` | Exit code 1 で終了 | L28-34 |
| ディレクトリ作成失敗 | （暗黙的） | `Eio.Path.mkdirs ~exists_ok:true` 失敗時 | L24 |

---

## 10. 署名検証エラー

**ファイル**: `lib/core/bip340.ml`

| エラー | 条件 | 結果 | 行番号 |
|--------|------|------|--------|
| 公開鍵パース無効 | `secp256k1_xonly_pubkey_parse` が 0 を返す | `false` | L83-84 |
| 署名検証失敗 | `secp256k1_schnorrsig_verify` が 0 を返す | `false` | L86-89 |
| Hex 変換例外 | 無効な 16 進数文字 | 例外伝播（未キャッチ） | L58-63 |

---

## 11. エラーハンドリングアーキテクチャ

### 11.1 エラー型階層

```
Domain.error (union type)
    ├── Invalid_hash
    ├── Invalid_size
    ├── Blob_not_found
    └── Storage_error (catch-all for system/DB errors)

HTTP Errors (Http_response.response_kind)
    ├── Error_not_found (404)
    ├── Error_unauthorized (401)
    ├── Error_bad_request (400)
    └── Error_internal (500)

External Errors
    ├── Caqti_error.t (database)
    ├── Eio.Io exceptions (filesystem)
    ├── Piaf.Error.t (HTTP streaming)
    └── Yojson.Json_error (JSON parsing)
```

### 11.2 変換フロー

```
1. コアエラー → Domain.error 型
2. 外部エラー → Domain.error（通常 Storage_error）
3. Domain.error → Http_response.response_kind
4. Http_response.response_kind → HTTP レスポンス（ステータスコード付き）
```

---

## 統計サマリー

| 項目 | 数 |
|------|-----|
| 定義済みエラー型 | 4 (Domain.error variants) |
| HTTP エラーレスポンス | 4 (404, 401, 400, 500) |
| 個別エラーシナリオ | 50+ |
| 外部エラーソース | 4 (Caqti, Eio, Piaf, Yojson) |
| エラーテストケース | 14+ |
| エラー処理を含むファイル | 8 core/shell ファイル |
