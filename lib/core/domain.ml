type blob_descriptor = {
  url : string;
  sha256 : string;
  size : int;
  mime_type : string;
  uploaded : int64;
}

type error =
  | Invalid_hash of string
  | Invalid_size of int
  | Blob_not_found of string
  | Storage_error of string
