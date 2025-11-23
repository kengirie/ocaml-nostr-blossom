open Piaf
open Blossom_core

let add_cors_headers response =
  let headers = Response.headers response in
  let headers = Headers.add headers "Access-Control-Allow-Origin" "*" in
  Response.create
    ~version:response.version
    ~headers
    ~body:response.body
    response.status

let handle_cors_preflight () =
  let headers = Headers.of_list [
    ("Access-Control-Allow-Origin", "*");
    ("Access-Control-Allow-Methods", "GET, HEAD, PUT, DELETE, OPTIONS");
    ("Access-Control-Allow-Headers", "Authorization, Content-Type, Content-Length, *");
    ("Access-Control-Max-Age", "86400");
  ] in
  Response.create ~headers `No_content

let error_response status message =
  let headers = Headers.of_list [("X-Reason", message)] in
  Response.of_string ~headers ~body:message status

let request_handler ~storage_dir { Server.Handler.request; _ } =
  Printf.printf "Request: %s %s\n%!" (Method.to_string request.meth) request.target;
  let response = match request.meth, request.target with
  | `OPTIONS, _ -> handle_cors_preflight ()
  | `GET, path ->
      let path_parts = String.split_on_char '/' path |> List.filter (fun s -> s <> "") in
      Printf.printf "Path parts: [%s]\n%!" (String.concat "; " path_parts);
      (match path_parts with
       | [hash] when Integrity.validate_hash hash ->
           Printf.printf "Valid hash: %s\n%!" hash;
           (match Local_storage.get ~dir:storage_dir ~sha256:hash with
            | Ok data ->
                Printf.printf "Found blob, size: %d bytes\n%!" (String.length data);
                Response.of_string ~body:data `OK
            | Error (Domain.Blob_not_found _) ->
                Printf.printf "Blob not found\n%!";
                error_response `Not_found "Blob not found"
            | Error (Domain.Storage_error msg) ->
                Printf.printf "Storage error: %s\n%!" msg;
                error_response `Internal_server_error msg
            | Error _ -> error_response `Internal_server_error "Internal error")
       | _ ->
           Printf.printf "Invalid path or hash\n%!";
           error_response `Not_found "Invalid path or hash")
  | `PUT, "/upload" ->
      Printf.printf "Upload request\n%!";
      let content_type = Headers.get request.headers "content-type" |> Option.value ~default:"application/octet-stream" in
      let content_length =
        Headers.get request.headers "content-length"
        |> Option.map int_of_string
        |> Option.value ~default:0
      in

      Printf.printf "Content-Type: %s, Content-Length: %d\n%!" content_type content_length;

      (* ポリシーチェック *)
      let policy = Policy.default_policy in
      (match Policy.check_upload_policy ~policy ~size:content_length ~mime:content_type with
       | Error e ->
           let msg = match e with
             | Domain.Storage_error m -> m
             | Domain.Invalid_size s -> Printf.sprintf "Invalid size: %d" s
             | _ -> "Unknown error"
           in
           Printf.printf "Policy check failed: %s\n%!" msg;
           error_response `Bad_request msg
       | Ok () ->
           (* ストリーミング保存 + ハッシュ計算 *)
           (match Local_storage.save_stream ~dir:storage_dir ~body:request.body with
            | Error e ->
                let msg = match e with
                  | Domain.Storage_error m -> m
                  | _ -> "Unknown error"
                in
                Printf.printf "Save failed: %s\n%!" msg;
                error_response `Internal_server_error msg
            | Ok (hash, size) ->
                Printf.printf "Upload successful: %s (%d bytes)\n%!" hash size;
                let descriptor = {
                  Domain.url = Printf.sprintf "http://localhost:8082/%s" hash;
                  sha256 = hash;
                  size = size;
                  mime_type = content_type;
                  uploaded = Int64.of_float (Unix.time ());
                } in
                let json = Printf.sprintf
                  {|{"url":"%s","sha256":"%s","size":%d,"type":"%s","uploaded":%Ld}|}
                  descriptor.url descriptor.sha256 descriptor.size descriptor.mime_type descriptor.uploaded
                in
                Response.of_string ~body:json `OK))
  | _ -> error_response `Not_found "Not found"
  in
  add_cors_headers response

let start ~sw ~env ~port =
  let storage_dir = Eio.Path.(Eio.Stdenv.cwd env / "data") in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 storage_dir;

  let address = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let config = Server.Config.create address in
  let server = Server.create ~config (request_handler ~storage_dir) in
  let _ = Server.Command.start ~sw env server in
  ()
