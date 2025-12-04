(** MIME type detection using magic bytes (conan library) *)

(** Build a combined tree from various conan-database modules *)
let combined_tree =
  let trees = [
    Conan_images.tree;
    Conan_jpeg.tree;
    Conan_audio.tree;
    Conan_archive.tree;
    Conan_compress.tree;
    Conan_animation.tree;
    Conan_zip.tree;
    Conan_riff.tree;  (* WEBP, AVI, WAV など *)
  ] in
  List.fold_left Conan.Tree.merge Conan.Tree.empty trees

(** Pre-compiled database for efficient lookups *)
let database = Conan.Process.database ~tree:combined_tree

(** Detect MIME type from bytes content using magic bytes analysis.
    Returns [Some mime_type] if detected, [None] otherwise. *)
let detect_from_bytes (content : string) : string option =
  match Conan_string.run ~database content with
  | Ok metadata -> Conan.Metadata.mime metadata
  | Error _ -> None
