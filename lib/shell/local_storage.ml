open Blossom_core

(* Phase 1: Simple save (already exists) *)
let save ~dir ~data ~sha256 =
  let path = Eio.Path.(dir / sha256) in
  try
    Eio.Path.save ~create:(`Or_truncate 0o644) path data;
    Ok ()
  with exn ->
    Error (Domain.Storage_error (Printexc.to_string exn))

(* Phase 2: Streaming save with SHA256 calculation *)
type stream_state = {
  ctx: Digestif.SHA256.ctx;
  size: int;
  first_chunk: string option;
}

let save_stream ~dir ~db ~body ~mime_type ~uploader =
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
      let final_path = Eio.Path.(dir / hash) in

      (* MIME type がデフォルト値の場合、先頭チャンクから検出を試みる *)
      let final_mime_type =
        if mime_type = "application/octet-stream" then
          match state.first_chunk with
          | Some chunk ->
              (match Mime_detect.detect_from_bytes chunk with
               | Some detected -> detected
               | None -> mime_type)
          | None -> mime_type
        else
          mime_type
      in

      (* 一時ファイルを最終パスにリネーム *)
      (try
        Eio.Path.rename temp_path final_path;
        (* DBにメタデータを保存 *)
        match Blossom_db.save db ~sha256:hash ~size:state.size ~mime_type:final_mime_type ~uploader with
        | Ok () -> Ok (hash, state.size, final_mime_type)
        | Error e ->
            (* DB保存失敗時はファイルも削除 *)
            (try Eio.Path.unlink final_path with _ -> ());
            Error e
      with exn ->
        (try Eio.Path.unlink temp_path with _ -> ());
        Error (Domain.Storage_error (Printexc.to_string exn)))

(* ファイル全体をメモリに読み込む（小さいファイル向け、後方互換性のため残す） *)
let get ~dir ~db ~sha256 =
  match Blossom_db.get db ~sha256 with
  | Ok metadata ->
      let path = Eio.Path.(dir / sha256) in
      (try
        let data = Eio.Path.load path in
        Ok (data, metadata)
      with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
          Error (Domain.Blob_not_found sha256)
      | exn ->
          Error (Domain.Storage_error (Printexc.to_string exn)))
  | Error (Domain.Blob_not_found _) ->
      (* DBになくてもファイルがあれば返す（後方互換性のため、あるいは復旧用） *)
      let path = Eio.Path.(dir / sha256) in
      (try
        let data = Eio.Path.load path in
        Ok (data, {
          Domain.sha256 = sha256;
          size = String.length data;
          mime_type = "application/octet-stream";
          uploaded = 0L;
          url = "/";
        })
      with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
          Error (Domain.Blob_not_found sha256)
      | exn ->
          Error (Domain.Storage_error (Printexc.to_string exn)))
  | Error e -> Error e

(* ストリーミングでファイルを取得（Eio + Piaf.Body.of_string_stream を使用） *)
let get_stream ~sw ~dir ~db ~sha256 =
  let chunk_size = 16384 in (* 16KB chunks *)

  let create_stream_body path size =
    let stream, push = Piaf.Stream.create 2 in
    (* 別ファイバーでファイルを読み込みながらストリームにプッシュ *)
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Path.with_open_in path (fun file ->
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
    Piaf.Body.of_string_stream ~length:(`Fixed (Int64.of_int size)) stream
  in

  match Blossom_db.get db ~sha256 with
  | Ok metadata ->
      let path = Eio.Path.(dir / sha256) in
      (try
        let body = create_stream_body path metadata.size in
        Ok (body, metadata)
      with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
          Error (Domain.Blob_not_found sha256)
      | exn ->
          Error (Domain.Storage_error (Printexc.to_string exn)))
  | Error (Domain.Blob_not_found _) ->
      (* DBにない場合もファイルがあればストリーミングで返す *)
      let path = Eio.Path.(dir / sha256) in
      (try
        let stat = Eio.Path.stat ~follow:true path in
        let size = Optint.Int63.to_int stat.size in
        let body = create_stream_body path size in
        Ok (body, {
          Domain.sha256 = sha256;
          size;
          mime_type = "application/octet-stream";
          uploaded = 0L;
          url = "/";
        })
      with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
          Error (Domain.Blob_not_found sha256)
      | exn ->
          Error (Domain.Storage_error (Printexc.to_string exn)))
  | Error e -> Error e

(* メタデータのみ取得（HEADリクエスト用） *)
let get_metadata ~dir ~db ~sha256 =
  match Blossom_db.get db ~sha256 with
  | Ok metadata ->
      (* ファイルの存在確認のみ（読み込まない） *)
      let path = Eio.Path.(dir / sha256) in
      (try
        let _ = Eio.Path.stat ~follow:true path in
        Ok metadata
      with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
          Error (Domain.Blob_not_found sha256)
      | exn ->
          Error (Domain.Storage_error (Printexc.to_string exn)))
  | Error e -> Error e

let exists ~dir ~sha256 =
  let path = Eio.Path.(dir / sha256) in
  try
    let _ = Eio.Path.stat ~follow:true path in
    true
  with _ -> false
