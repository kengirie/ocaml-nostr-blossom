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
let save_stream ~dir ~db ~body ~mime_type ~uploader =
  (* Digestif を使ってストリーミングでハッシュ計算 *)
  let ctx = ref (Digestif.SHA256.init ()) in
  let buffer = Buffer.create 4096 in

  (* ストリームからデータを読み込みながらハッシュ計算 *)
  let result = Piaf.Body.iter_string
    ~f:(fun chunk ->
      ctx := Digestif.SHA256.feed_string !ctx chunk;
      Buffer.add_string buffer chunk
    )
    body
  in

  match result with
  | Error e -> Error (Domain.Storage_error (Piaf.Error.to_string e))
  | Ok () ->
      let hash = Digestif.SHA256.(to_hex (get !ctx)) in
      let data = Buffer.contents buffer in
      let size = String.length data in
      let path = Eio.Path.(dir / hash) in

      (* MIME type がデフォルト値の場合、magic bytes 検出を試みる *)
      let final_mime_type =
        if mime_type = "application/octet-stream" then
          match Mime_detect.detect_from_bytes data with
          | Some detected -> detected
          | None -> mime_type
        else
          mime_type
      in

      (try
        Eio.Path.save ~create:(`Or_truncate 0o644) path data;
        (* DBにメタデータを保存 *)
        match Blossom_db.save db ~sha256:hash ~size ~mime_type:final_mime_type ~uploader with
        | Ok () -> Ok (hash, size, final_mime_type)
        | Error e -> Error e
      with exn ->
        Error (Domain.Storage_error (Printexc.to_string exn)))

let get ~dir ~db ~sha256 =
  (* まずDBからメタデータを取得 *)
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
      (* DBになくてもファイルがあれば返す（後方互換性のため、あるいは復旧用）
         ただし、MIMEタイプは不明になる *)
      let path = Eio.Path.(dir / sha256) in
      (try
        let data = Eio.Path.load path in
        Ok (data, {
          Domain.sha256 = sha256;
          size = String.length data;
          mime_type = "application/octet-stream";
          uploaded = 0L; (* Unknown *)
          url = "/";
        })
      with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
          Error (Domain.Blob_not_found sha256)
      | exn ->
          Error (Domain.Storage_error (Printexc.to_string exn)))
  | Error e -> Error e

let exists ~dir ~sha256 =
  let path = Eio.Path.(dir / sha256) in
  try
    let _ = Eio.Path.load path in
    true
  with _ -> false
