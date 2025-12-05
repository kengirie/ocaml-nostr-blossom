open Cmdliner

let cert_arg =
  let doc = "Path to SSL certificate" in
  Arg.(value & opt (some string) None & info ["cert"] ~doc)

let key_arg =
  let doc = "Path to SSL private key" in
  Arg.(value & opt (some string) None & info ["key"] ~doc)

let port_arg =
  let doc = "Port to listen on" in
  Arg.(value & opt int 8082 & info ["port"] ~doc)

let base_url_arg =
  let doc = "Base URL for blob URLs in responses (e.g., https://example.com:8082)" in
  Arg.(value & opt (some string) None & info ["base-url"] ~doc)

let run_server cert key port base_url =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let dir = Eio.Path.(Eio.Stdenv.cwd env / "data") in
      Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 dir;

      Eio.traceln "Initializing database...";
      match Blossom_shell.Blossom_db.init ~env ~sw ~dir with
      | Error e ->
          let msg = match e with
            | Blossom_core.Domain.Storage_error msg -> msg
            | _ -> "Unknown error"
          in
          Eio.traceln "Database initialization failed: %s" msg;
          exit 1
      | Ok db ->
              (* Determine base URL: use --base-url if provided, otherwise construct from port *)
          let effective_base_url = match base_url with
            | Some url -> url
            | None ->
                let scheme = if Option.is_some cert then "https" else "http" in
                Printf.sprintf "%s://localhost:%d" scheme port
          in
          Eio.traceln "Starting Blossom server on port %d (base URL: %s)" port effective_base_url;
          Blossom_shell.Http_server.start ~sw ~env ~port ~clock ~dir ~db ~base_url:effective_base_url ?cert ?key ();
          (* Keep the server running *)
          Eio.Fiber.await_cancel ()
    )
  )

let server_cmd =
  let doc = "Blossom Server - A file storage server with Nostr authentication" in
  let info = Cmd.info "ocaml-nostr-blossom" ~version:"0.1.0" ~doc in
  Cmd.v info Term.(const run_server $ cert_arg $ key_arg $ port_arg $ base_url_arg)

let () = exit (Cmd.eval server_cmd)
