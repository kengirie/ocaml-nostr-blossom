open Domain

let validate_hash hash =
  String.length hash = 64 &&
  String.for_all (function
    | '0'..'9' | 'a'..'f' | 'A'..'F' -> true
    | _ -> false
  ) hash

let validate_size size =
  if size < 0 then Error (Invalid_size size)
  else Ok ()
