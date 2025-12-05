(** HTTPレスポンス生成の純粋関数モジュール

    このモジュールはHTTPレスポンス生成ロジックを純粋関数として提供します。
    すべての関数は副作用を持たず、ユニットテストが可能です。
*)

open Piaf
open Blossom_core

(** レスポンスの種類を表すバリアント型 *)
type response_kind =
  | Success_blob of { data: string; mime_type: string; size: int }
    (** Blobデータの取得成功（メモリ上のデータ） *)
  | Success_blob_stream of { body: Body.t; mime_type: string; size: int }
    (** Blobデータの取得成功（ストリーミング） *)
  | Success_metadata of { mime_type: string; size: int }
    (** Blobメタデータの取得成功（HEADリクエスト用） *)
  | Success_upload of Domain.blob_descriptor
    (** Blobアップロード成功 *)
  | Cors_preflight
    (** CORSプリフライトレスポンス *)
  | Error_not_found of string
    (** 404 Not Found *)
  | Error_unauthorized of string
    (** 401 Unauthorized *)
  | Error_bad_request of string
    (** 400 Bad Request *)
  | Error_internal of string
    (** 500 Internal Server Error *)

(** CORSヘッダーのリスト

    @koa/cors 相当の全面適用:
    - Access-Control-Allow-Origin: *
    - Access-Control-Allow-Methods: * (全メソッド許可)
    - Access-Control-Allow-Headers: Authorization, Content-Type, Content-Length, *
    - Access-Control-Expose-Headers: * (全ヘッダー公開)
    - Access-Control-Max-Age: 86400 (プリフライトキャッシュ24時間)
*)
let cors_headers = [
  ("access-control-allow-origin", "*");
  ("access-control-allow-methods", "*");
  ("access-control-allow-headers", "Authorization, Content-Type, Content-Length, *");
  ("access-control-expose-headers", "*");
  ("access-control-max-age", "86400");
]

(** blob descriptorをJSON文字列に変換する純粋関数 *)
let descriptor_to_json descriptor =
  `Assoc [
    ("url", `String descriptor.Domain.url);
    ("sha256", `String descriptor.sha256);
    ("size", `Int descriptor.size);
    ("type", `String descriptor.mime_type);
    ("uploaded", `Int (Int64.to_int descriptor.uploaded));
  ]
  |> Yojson.Basic.to_string

(** レスポンスの種類から実際のHTTPレスポンスを生成する純粋関数

    この関数はパターンマッチを使用してすべてのresponse_kindを網羅的に処理します。
    新しいレスポンス種別を追加した場合、コンパイラが未処理のケースを警告します。
    全レスポンスにCORSヘッダーが自動的に付与されます。
*)
let create = function
  | Success_blob { data; mime_type; size } ->
      let headers = Headers.of_list (cors_headers @ [
        ("content-type", mime_type);
        ("content-length", string_of_int size);
      ]) in
      Response.create ~headers ~body:(Body.of_string data) `OK

  | Success_blob_stream { body; mime_type; size } ->
      let headers = Headers.of_list (cors_headers @ [
        ("content-type", mime_type);
        ("content-length", string_of_int size);
      ]) in
      Response.create ~headers ~body `OK

  | Success_metadata { mime_type; size } ->
      let headers = Headers.of_list (cors_headers @ [
        ("content-type", mime_type);
        ("content-length", string_of_int size);
      ]) in
      Response.create ~headers `OK

  | Success_upload descriptor ->
      let json = descriptor_to_json descriptor in
      let headers = Headers.of_list cors_headers in
      Response.create ~headers ~body:(Body.of_string json) `OK

  | Cors_preflight ->
      let headers = Headers.of_list cors_headers in
      Response.create ~headers `No_content

  | Error_not_found message ->
      let headers = Headers.of_list (cors_headers @ [("x-reason", message)]) in
      Response.create ~headers ~body:(Body.of_string message) `Not_found

  | Error_unauthorized message ->
      let headers = Headers.of_list (cors_headers @ [("x-reason", message)]) in
      Response.create ~headers ~body:(Body.of_string message) `Unauthorized

  | Error_bad_request message ->
      let headers = Headers.of_list (cors_headers @ [("x-reason", message)]) in
      Response.create ~headers ~body:(Body.of_string message) `Bad_request

  | Error_internal message ->
      let headers = Headers.of_list (cors_headers @ [("x-reason", message)]) in
      Response.create ~headers ~body:(Body.of_string message) `Internal_server_error
