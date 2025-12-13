(** データベース操作の抽象インターフェース *)

open Blossom_core

(** メタデータDB操作のシグネチャ *)
module type S = sig
  (** DB接続/プールの型 *)
  type t

  (** Blobメタデータを保存する *)
  val save :
    t ->
    sha256:string ->
    size:int ->
    mime_type:string ->
    uploader:string ->
    (unit, Domain.error) result

  (** Blobメタデータを取得する *)
  val get :
    t ->
    sha256:string ->
    (Domain.blob_descriptor, Domain.error) result
end
