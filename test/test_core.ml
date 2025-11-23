open Alcotest
open Blossom_core

let test_validate_hash_valid () =
  let hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" in
  check bool "valid hash returns true" true (Integrity.validate_hash hash)

let test_validate_hash_invalid_length () =
  let hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b85" in (* 63 chars *)
  check bool "invalid length returns false" false (Integrity.validate_hash hash)

let test_validate_hash_invalid_char () =
  let hash = "g3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" in (* 'g' is invalid *)
  check bool "invalid char returns false" false (Integrity.validate_hash hash)

let test_validate_size_valid () =
  check bool "positive size is ok" true (Result.is_ok (Integrity.validate_size 100))

let test_validate_size_zero () =
  check bool "zero size is ok" true (Result.is_ok (Integrity.validate_size 0))

let test_validate_size_negative () =
  check bool "negative size is error" true (Result.is_error (Integrity.validate_size (-1)))

let () =
  run "Blossom Core" [
    "Integrity", [
      test_case "validate_hash valid" `Quick test_validate_hash_valid;
      test_case "validate_hash invalid length" `Quick test_validate_hash_invalid_length;
      test_case "validate_hash invalid char" `Quick test_validate_hash_invalid_char;
      test_case "validate_size valid" `Quick test_validate_size_valid;
      test_case "validate_size zero" `Quick test_validate_size_zero;
      test_case "validate_size negative" `Quick test_validate_size_negative;
    ];
  ]
