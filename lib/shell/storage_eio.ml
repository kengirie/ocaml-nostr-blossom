(** Eioベースのファイルシステム実装 *)

open Blossom_core

(** Eio実装 *)
module Impl : Storage_intf.S with type t = Eio.Fs.dir_ty Eio.Path.t = struct
  type t = Eio.Fs.dir_ty Eio.Path.t

  (** ストリーミング保存時の内部状態 *)
  type stream_state = {
    ctx: Digestif.SHA256.ctx;
    size: int;
    first_chunk: string option;
  }

  (** Eioの例外をドメインエラーに変換するヘルパー *)
  let catch_eio_error ~path f =
    try Ok (f ())
    with
    | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
        Error (Domain.Blob_not_found path)
    | Eio.Io (Eio.Fs.E (Eio.Fs.Permission_denied _), _) ->
        Error (Domain.Storage_error "Permission denied")
    | exn ->
        Error (Domain.Storage_error (Printexc.to_string exn))

  let save dir ~body =
    (* 一時ファイル名を生成 *)
    let temp_id = Printf.sprintf "tmp_%d_%d" (Random.int 1000000) (Random.int 1000000) in
    let temp_path = Eio.Path.(dir / temp_id) in

    (* 一時ファイルに書き込みながらハッシュ計算 *)
    let write_result =
      try
        Ok (Eio.Path.with_open_out ~create:(`Or_truncate 0o644) temp_path (fun file ->
          let init = { ctx = Digestif.SHA256.init (); size = 0; first_chunk = None } in
          Piaf.Body.fold_string body ~init ~f:(fun state chunk ->
            (* ファイルに書き込み *)
            Eio.Flow.copy_string chunk file;
            (* 状態を更新 *)
            {
              ctx = Digestif.SHA256.feed_string state.ctx chunk;
              size = state.size + String.length chunk;
              first_chunk = if Option.is_none state.first_chunk then Some chunk else state.first_chunk;
            }
          )
        ))
      with exn ->
        (* 一時ファイルを削除 *)
        (try Eio.Path.unlink temp_path with _ -> ());
        Error (Domain.Storage_error (Printexc.to_string exn))
    in

    match write_result with
    | Error e -> Error e
    | Ok (Error e) ->
        (* Piaf.Body.fold_string のエラー *)
        (try Eio.Path.unlink temp_path with _ -> ());
        Error (Domain.Storage_error (Piaf.Error.to_string e))
    | Ok (Ok state) ->
        let hash = Digestif.SHA256.(to_hex (get state.ctx)) in
        (* 一時ファイルを最終パスにリネーム *)
        (try
          let final_path = Eio.Path.(dir / hash) in
          Eio.Path.rename temp_path final_path;
          Ok {
            Storage_intf.sha256 = hash;
            size = state.size;
            first_chunk = state.first_chunk;
          }
        with exn ->
          (try Eio.Path.unlink temp_path with _ -> ());
          Error (Domain.Storage_error (Printexc.to_string exn)))

  let get ~sw dir ~path ~size =
    let chunk_size = 16384 in (* 16KB chunks *)
    let full_path = Eio.Path.(dir / path) in
    (* ファイルを開く（エラーを早期に検出） *)
    try
      let file = Eio.Path.open_in ~sw full_path in
      let stream, push = Piaf.Stream.create 2 in
      (* 別ファイバーでファイルを読み込みながらストリームにプッシュ *)
      Eio.Fiber.fork ~sw (fun () ->
        Fun.protect ~finally:(fun () -> Eio.Flow.close file) (fun () ->
          let rec read_loop remaining =
            if remaining <= 0 then
              push None (* ストリーム終了 *)
            else
              let to_read = min chunk_size remaining in
              let buf = Cstruct.create to_read in
              match Eio.Flow.single_read file buf with
              | 0 -> push None
              | n ->
                  push (Some (Cstruct.to_string ~len:n buf));
                  read_loop (remaining - n)
          in
          read_loop size
        )
      );
      Ok (Piaf.Body.of_string_stream ~length:(`Fixed (Int64.of_int size)) stream)
    with
    | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
        Error (Domain.Blob_not_found path)
    | Eio.Io (Eio.Fs.E (Eio.Fs.Permission_denied _), _) ->
        Error (Domain.Storage_error "Permission denied")
    | exn ->
        Error (Domain.Storage_error (Printexc.to_string exn))

  let exists dir ~path =
    let full_path = Eio.Path.(dir / path) in
    try
      let _ = Eio.Path.stat ~follow:true full_path in
      Ok true
    with
    | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
        Ok false
    | Eio.Io (Eio.Fs.E (Eio.Fs.Permission_denied _), _) ->
        Error (Domain.Storage_error "Permission denied")
    | exn ->
        Error (Domain.Storage_error (Printexc.to_string exn))

  let stat dir ~path =
    let full_path = Eio.Path.(dir / path) in
    catch_eio_error ~path (fun () ->
      let s = Eio.Path.stat ~follow:true full_path in
      Optint.Int63.to_int s.size
    )

  let unlink dir ~path =
    let full_path = Eio.Path.(dir / path) in
    Eio.Path.unlink full_path

  let rename dir ~src ~dst =
    let src_path = Eio.Path.(dir / src) in
    let dst_path = Eio.Path.(dir / dst) in
    Eio.Path.rename src_path dst_path
end
