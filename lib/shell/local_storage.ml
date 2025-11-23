open Blossom_core

let save ~dir ~data ~sha256 =
  let path = Eio.Path.(dir / sha256) in
  try
    Eio.Path.save ~create:(`Or_truncate 0o644) path data;
    Ok ()
  with exn ->
    Error (Domain.Storage_error (Printexc.to_string exn))

let get ~dir ~sha256 =
  let path = Eio.Path.(dir / sha256) in
  try
    let data = Eio.Path.load path in
    Ok data
  with
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
      Error (Domain.Blob_not_found sha256)
  | exn ->
      Error (Domain.Storage_error (Printexc.to_string exn))

let exists ~dir ~sha256 =
  let path = Eio.Path.(dir / sha256) in
  try
    let _ = Eio.Path.load path in
    true
  with _ -> false
