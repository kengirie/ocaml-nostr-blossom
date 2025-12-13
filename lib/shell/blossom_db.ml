open Blossom_core

module Db = struct
  open Caqti_request.Infix
  open Caqti_type.Std

  let create_blobs_table =
    (unit ->. unit)
    @@ {sql|
      CREATE TABLE IF NOT EXISTS blobs (
        sha256 TEXT(64) PRIMARY KEY,
        uploaded_at INTEGER NOT NULL,
        uploader_pubkey TEXT(64),
        status TEXT NOT NULL DEFAULT 'stored' CHECK (status IN ('stored','deleted','quarantined')),
        remote_url TEXT,
        mime_type TEXT,
        size INTEGER
      )
    |sql}

  let create_blobs_uploaded_at_index =
    (unit ->. unit)
    @@ {sql|
      CREATE INDEX IF NOT EXISTS blobs_uploaded_at ON blobs(uploaded_at)
    |sql}

  let create_blobs_uploader_index =
    (unit ->. unit)
    @@ {sql|
      CREATE INDEX IF NOT EXISTS blobs_uploader ON blobs(uploader_pubkey)
    |sql}

  let save_blob =
    (t4 string string (option string) (option int64) ->. unit)
    @@ {sql|
      INSERT INTO blobs (sha256, uploaded_at, uploader_pubkey, mime_type, size)
      VALUES ($1, strftime('%s', 'now'), $2, $3, $4)
      ON CONFLICT(sha256) DO UPDATE SET
        uploaded_at = excluded.uploaded_at,
        uploader_pubkey = excluded.uploader_pubkey,
        mime_type = excluded.mime_type,
        size = excluded.size
    |sql}

  let get_blob =
    (string ->? t4 string int64 (option string) (option int64))
    @@ {sql|
      SELECT sha256, uploaded_at, mime_type, size
      FROM blobs
      WHERE sha256 = $1 AND status = 'stored'
    |sql}
end

type t = (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t

let init ~env ~sw ~dir =
  let db_path = Eio.Path.(dir / "blossom.db") in
  let uri = Uri.of_string ("sqlite3:" ^ (Eio.Path.native_exn db_path)) in

  match Caqti_eio_unix.connect_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) uri with
  | Error e -> Error (Domain.Storage_error (Caqti_error.show e))
  | Ok pool ->
      let init_result =
        Caqti_eio.Pool.use (fun (module C : Caqti_eio.CONNECTION) ->
          Result.bind (C.exec Db.create_blobs_table ()) @@ fun () ->
          Result.bind (C.exec Db.create_blobs_uploaded_at_index ()) @@ fun () ->
          C.exec Db.create_blobs_uploader_index ()
        ) pool
      in
      match init_result with
      | Ok () -> Ok pool
      | Error e -> Error (Domain.Storage_error (Caqti_error.show e))

let save (pool : t) ~sha256 ~size ~mime_type ~uploader =
  let result =
    Caqti_eio.Pool.use (fun (module C : Caqti_eio.CONNECTION) ->
      C.exec Db.save_blob (sha256, uploader, Some mime_type, Some (Int64.of_int size))
    ) pool
  in
  match result with
  | Ok () -> Ok ()
  | Error e -> Error (Domain.Storage_error (Caqti_error.show e))

let get (pool : t) ~sha256 =
  let result =
    Caqti_eio.Pool.use (fun (module C : Caqti_eio.CONNECTION) ->
      C.find_opt Db.get_blob sha256
    ) pool
  in
  match result with
  | Ok (Some (sha, uploaded_at, mime, size)) ->
      Ok {
        Domain.sha256 = sha;
        size = Option.value ~default:0 (Option.map Int64.to_int size);
        mime_type = Option.value ~default:"application/octet-stream" mime;
        uploaded = uploaded_at;
        url = "/"; (* URL construction is handled by Http_server *)
      }
  | Ok None -> Error (Domain.Blob_not_found sha256)
  | Error e -> Error (Domain.Storage_error (Caqti_error.show e))

(** Db_intf.S を満たすモジュール *)
module Impl : Db_intf.S with type t = t = struct
  type nonrec t = t
  let save = save
  let get = get
end
