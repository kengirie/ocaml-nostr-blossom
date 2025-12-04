open Alcotest
open Blossom_core

(* PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A + IHDR chunk *)
let png_header = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"

(* JPEG magic bytes: FF D8 FF *)
let jpeg_header = "\xff\xd8\xff\xe0\x00\x10JFIF"

(* GIF magic bytes: GIF89a or GIF87a *)
let gif_header = "GIF89a"

(* WEBP magic bytes: RIFF + size (4 bytes) + WEBP
   The format is: "RIFF" (4) + file_size (4) + "WEBP" (4) *)
let webp_header = "RIFF\x00\x00\x00\x00WEBP"

(* ZIP empty archive: PK\005\006 + 18 bytes of zeros
   This is the End of Central Directory record for an empty ZIP *)
let zip_header = "PK\x05\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"

(* GZIP magic bytes: 1F 8B 08 *)
let gzip_header = "\x1f\x8b\x08\x00\x00\x00\x00\x00"

(* MP3 MPEG Audio frame sync: FF FB (MPEG1 Layer3) or FF FA (MPEG1 Layer3 with CRC)
   0xFFFB = 65531, matches MPEG ADTS frame sync pattern *)
let mp3_header = "\xff\xfb\x90\x00"

(* Random binary data (should not match any known type) *)
let unknown_data = "\x00\x01\x02\x03\x04\x05\x06\x07"

let test_png_detection () =
  let result = Mime_detect.detect_from_bytes png_header in
  check (option string) "PNG detected" (Some "image/png") result

let test_jpeg_detection () =
  let result = Mime_detect.detect_from_bytes jpeg_header in
  check (option string) "JPEG detected" (Some "image/jpeg") result

let test_gif_detection () =
  let result = Mime_detect.detect_from_bytes gif_header in
  check (option string) "GIF detected" (Some "image/gif") result

let test_webp_detection () =
  let result = Mime_detect.detect_from_bytes webp_header in
  check (option string) "WEBP detected" (Some "image/webp") result

let test_zip_detection () =
  let result = Mime_detect.detect_from_bytes zip_header in
  check (option string) "ZIP detected" (Some "application/zip") result

let test_gzip_detection () =
  let result = Mime_detect.detect_from_bytes gzip_header in
  check (option string) "GZIP detected" (Some "application/gzip") result

let test_mp3_detection () =
  let result = Mime_detect.detect_from_bytes mp3_header in
  check (option string) "MP3 detected" (Some "audio/mpeg") result

let test_unknown_detection () =
  let result = Mime_detect.detect_from_bytes unknown_data in
  check (option string) "Unknown data returns None" None result

let test_empty_detection () =
  let result = Mime_detect.detect_from_bytes "" in
  check (option string) "Empty data returns None" None result

let tests = [
  "PNG detection", `Quick, test_png_detection;
  "JPEG detection", `Quick, test_jpeg_detection;
  "GIF detection", `Quick, test_gif_detection;
  "WEBP detection", `Quick, test_webp_detection;
  "ZIP detection", `Quick, test_zip_detection;
  "GZIP detection", `Quick, test_gzip_detection;
  "MP3 detection", `Quick, test_mp3_detection;
  "Unknown detection", `Quick, test_unknown_detection;
  "Empty detection", `Quick, test_empty_detection;
]
