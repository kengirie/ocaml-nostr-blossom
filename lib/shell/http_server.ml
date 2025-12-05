open Piaf
open Blossom_core

(** ログ出力（副作用） *)
let log_response ~request response =
  let status = Response.status response |> Piaf.Status.to_string in
  let headers =
    response
    |> Response.headers
    |> Headers.to_list
    |> List.map (fun (k, v) -> Printf.sprintf "%s: %s" k v)
    |> String.concat "; "
  in
  Eio.traceln
    "Response: %s %s -> %s [%s]"
    (request |> Request.meth |> Method.to_string)
    (Request.target request)
    status
    headers

(** Domain.errorをHttp_response.response_kindに変換するヘルパー *)
let error_to_response_kind = function
  | Domain.Blob_not_found _ -> Http_response.Error_not_found "Blob not found"
  | Domain.Storage_error msg -> Http_response.Error_internal msg
  | Domain.Invalid_size s -> Http_response.Error_bad_request (Printf.sprintf "Invalid size: %d" s)
  | Domain.Invalid_hash h -> Http_response.Error_bad_request (Printf.sprintf "Invalid hash: %s" h)

let request_handler ~sw ~clock ~dir ~db ~base_url { Server.Handler.request; _ } =
  Eio.traceln "Request: %s %s" (Method.to_string request.meth) request.target;

  (* レスポンス種別を決定 *)
  let response_kind = match request.meth, request.target with
  | `OPTIONS, _ ->
      Http_response.Cors_preflight

  | `GET, path ->
      let path_parts = String.split_on_char '/' path |> List.filter (fun s -> s <> "") in
      Eio.traceln "Path parts: [%s]" (String.concat "; " path_parts);
      (match path_parts with
       | [hash_with_ext] ->
           let hash = try Filename.remove_extension hash_with_ext with _ -> hash_with_ext in
           if not (Integrity.validate_hash hash) then
             Http_response.Error_not_found "Invalid path or hash"
           else
             (match Local_storage.get_stream ~sw ~dir ~db ~sha256:hash with
              | Ok (body, metadata) ->
                  Http_response.Success_blob_stream {
                    body;
                    mime_type = metadata.mime_type;
                    size = metadata.size;
                  }
              | Error e -> error_to_response_kind e)
       | _ -> Http_response.Error_not_found "Invalid path")

  | `HEAD, path ->
      let path_parts = String.split_on_char '/' path |> List.filter (fun s -> s <> "") in
      (match path_parts with
       | [hash_with_ext] ->
           let hash = try Filename.remove_extension hash_with_ext with _ -> hash_with_ext in
           if not (Integrity.validate_hash hash) then
             Http_response.Error_not_found "Invalid path or hash"
           else
             (match Local_storage.get_metadata ~dir ~db ~sha256:hash with
              | Ok metadata ->
                  Http_response.Success_metadata {
                    mime_type = metadata.mime_type;
                    size = metadata.size;
                  }
              | Error e -> error_to_response_kind e)
       | _ -> Http_response.Error_not_found "Invalid path")

  | `PUT, "/upload" ->
      (match Headers.get request.headers "authorization" with
       | None -> Http_response.Error_unauthorized "Missing Authorization header"
       | Some auth_header ->
           let current_time = Int64.of_float (Eio.Time.now clock) in
           match Auth.validate_auth ~header:auth_header ~action:Auth.Upload ~current_time with
           | Error (Domain.Storage_error msg) -> Http_response.Error_unauthorized msg
           | Error _ -> Http_response.Error_unauthorized "Authentication failed"
           | Ok pubkey ->
               (* Content-Type -> X-Content-Type -> default の優先順位で MIME type を取得 *)
               (* 空文字列の場合もデフォルト値にフォールバック *)
               let mime_type =
                 match Headers.get request.headers "content-type" with
                 | Some ct when String.length ct > 0 -> ct
                 | _ ->
                     match Headers.get request.headers "x-content-type" with
                     | Some xct when String.length xct > 0 -> xct
                     | _ -> "application/octet-stream"
               in
               let content_length =
                 Headers.get request.headers "content-length"
                 |> Option.map int_of_string
                 |> Option.value ~default:0
               in

               let policy = Policy.default_policy in
               (match Policy.check_upload_policy ~policy ~size:content_length ~mime:mime_type with
                | Error e -> error_to_response_kind e
                | Ok () ->
                    (match Local_storage.save_stream ~dir ~db ~body:request.body ~mime_type ~uploader:pubkey with
                     | Error e ->
                         let msg = match e with
                           | Domain.Storage_error m -> m
                           | _ -> "Unknown error"
                         in
                         Eio.traceln "Save failed: %s" msg;
                         Http_response.Error_internal msg
                     | Ok (hash, size, detected_mime_type) ->
                         Eio.traceln "Upload successful: %s (%d bytes, %s)" hash size detected_mime_type;
                         let descriptor = {
                           Domain.url = Printf.sprintf "%s/%s" base_url hash;
                           sha256 = hash;
                           size = size;
                           mime_type = detected_mime_type;
                           uploaded = Int64.of_float (Eio.Time.now clock);
                         } in
                         Eio.traceln "Upload response: %s" (Http_response.descriptor_to_json descriptor);
                         Http_response.Success_upload descriptor)))

  | _ -> Http_response.Error_not_found "Not found"
  in

  (* レスポンスを生成（CORSヘッダーは自動的に付与される） *)
  let response = Http_response.create response_kind in
  log_response ~request response;
  response

let start ~sw ~env ~port ~clock ~dir ~db ~base_url ?cert ?key () =
  let address = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in

  let https =
    match cert, key with
    | Some cert_path, Some key_path ->
        Some (Server.Config.HTTPS.create
          ~address
          (Cert.Filepath cert_path, Cert.Filepath key_path))
    | _ -> None
  in

  let config =
    Server.Config.create
      ?https
      ~max_http_version:(if Option.is_some https then Versions.HTTP.HTTP_2 else Versions.HTTP.HTTP_1_1)
      address
  in

  let server = Server.create ~config (request_handler ~sw ~clock ~dir ~db ~base_url) in
  let _ = Server.Command.start ~sw env server in
  ()
