open Piaf
open Blossom_core

let request_handler ~storage_dir { Server.Handler.request; _ } =
  Printf.printf "Request: %s %s\n%!" (Method.to_string request.meth) request.target;
  match request.meth, request.target with
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
                Response.of_string ~body:"Not found" `Not_found
            | Error (Domain.Storage_error msg) ->
                Printf.printf "Storage error: %s\n%!" msg;
                Response.of_string ~body:msg `Internal_server_error
            | Error _ -> Response.of_string ~body:"Internal error" `Internal_server_error)
       | _ ->
           Printf.printf "Invalid path or hash\n%!";
           Response.of_string ~body:"Not found" `Not_found)
  | _ -> Response.of_string ~body:"Not found" `Not_found

let start ~sw ~env ~port =
  let storage_dir = Eio.Path.(Eio.Stdenv.cwd env / "data") in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 storage_dir;

  let address = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let config = Server.Config.create address in
  let server = Server.create ~config (request_handler ~storage_dir) in
  let _ = Server.Command.start ~sw env server in
  ()
