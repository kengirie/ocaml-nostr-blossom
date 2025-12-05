open Alcotest
open Blossom_shell
open Blossom_core
open Piaf

(* ヘルパー関数 *)
let get_header response name =
  response |> Response.headers |> fun h -> Headers.get h name

let get_status response =
  Response.status response |> Status.to_code

(* CORSヘッダーの検証ヘルパー *)
let check_cors_headers response =
  check (option string) "CORS origin" (Some "*") (get_header response "access-control-allow-origin");
  check (option string) "CORS methods" (Some "*") (get_header response "access-control-allow-methods");
  check (option string) "CORS headers" (Some "Authorization, Content-Type, Content-Length, *") (get_header response "access-control-allow-headers");
  check (option string) "CORS expose-headers" (Some "*") (get_header response "access-control-expose-headers");
  check (option string) "CORS max-age" (Some "86400") (get_header response "access-control-max-age")

(* Success_blob レスポンステスト *)
let test_success_blob () =
  let response = Http_response.create (Success_blob {
    data = "test data";
    mime_type = "text/plain";
    size = 9;
  }) in
  check (option string) "Content-Type header" (Some "text/plain") (get_header response "content-type");
  check (option string) "Content-Length header" (Some "9") (get_header response "content-length");
  check int "Status code" 200 (get_status response);
  check_cors_headers response

(* Success_metadata レスポンステスト *)
let test_success_metadata () =
  let response = Http_response.create (Success_metadata {
    mime_type = "image/png";
    size = 1024;
  }) in
  check (option string) "Content-Type header" (Some "image/png") (get_header response "content-type");
  check (option string) "Content-Length header" (Some "1024") (get_header response "content-length");
  check int "Status code" 200 (get_status response);
  check_cors_headers response

(* Success_upload レスポンステスト *)
let test_success_upload () =
  let descriptor = {
    Domain.url = "http://localhost:8082/abc123";
    sha256 = "abc123";
    size = 500;
    mime_type = "application/octet-stream";
    uploaded = 1234567890L;
  } in
  let response = Http_response.create (Success_upload descriptor) in
  check int "Status code" 200 (get_status response);
  check_cors_headers response

(* Cors_preflight レスポンステスト *)
let test_cors_preflight () =
  let response = Http_response.create Cors_preflight in
  check int "Status code" 204 (get_status response);
  check_cors_headers response

(* Error_not_found レスポンステスト *)
let test_error_not_found () =
  let response = Http_response.create (Error_not_found "Resource not found") in
  check int "Status code" 404 (get_status response);
  check (option string) "X-Reason header" (Some "Resource not found") (get_header response "x-reason");
  check_cors_headers response

(* Error_unauthorized レスポンステスト *)
let test_error_unauthorized () =
  let response = Http_response.create (Error_unauthorized "Missing credentials") in
  check int "Status code" 401 (get_status response);
  check (option string) "X-Reason header" (Some "Missing credentials") (get_header response "x-reason");
  check_cors_headers response

(* Error_bad_request レスポンステスト *)
let test_error_bad_request () =
  let response = Http_response.create (Error_bad_request "Invalid input") in
  check int "Status code" 400 (get_status response);
  check (option string) "X-Reason header" (Some "Invalid input") (get_header response "x-reason");
  check_cors_headers response

(* Error_internal レスポンステスト *)
let test_error_internal () =
  let response = Http_response.create (Error_internal "Database error") in
  check int "Status code" 500 (get_status response);
  check (option string) "X-Reason header" (Some "Database error") (get_header response "x-reason");
  check_cors_headers response

(* descriptor_to_json テスト *)
let test_descriptor_to_json () =
  let descriptor = {
    Domain.url = "http://example.com/hash";
    sha256 = "abc123def456";
    size = 2048;
    mime_type = "image/jpeg";
    uploaded = 9876543210L;
  } in
  let json_str = Http_response.descriptor_to_json descriptor in
  let json = Yojson.Basic.from_string json_str in
  let open Yojson.Basic.Util in
  check string "URL" "http://example.com/hash" (json |> member "url" |> to_string);
  check string "SHA256" "abc123def456" (json |> member "sha256" |> to_string);
  check int "Size" 2048 (json |> member "size" |> to_int);
  check string "Type" "image/jpeg" (json |> member "type" |> to_string);
  check int "Uploaded" 9876543210 (json |> member "uploaded" |> to_int)

let tests = [
  test_case "Success_blob response" `Quick test_success_blob;
  test_case "Success_metadata response" `Quick test_success_metadata;
  test_case "Success_upload response" `Quick test_success_upload;
  test_case "Cors_preflight response" `Quick test_cors_preflight;
  test_case "Error_not_found response" `Quick test_error_not_found;
  test_case "Error_unauthorized response" `Quick test_error_unauthorized;
  test_case "Error_bad_request response" `Quick test_error_bad_request;
  test_case "Error_internal response" `Quick test_error_internal;
  test_case "descriptor_to_json function" `Quick test_descriptor_to_json;
]
