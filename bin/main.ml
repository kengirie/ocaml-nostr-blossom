let () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let port = 8082 in
      Printf.printf "Starting Blossom server on port %d\n%!" port;
      Blossom_shell.Http_server.start ~sw ~env ~port;
      (* Keep the server running *)
      Eio.Fiber.await_cancel ()
    )
  )
