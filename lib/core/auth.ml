(* Nostr event type for kind 24242 *)
type nostr_event = {
  id : string;
  pubkey : string;
  created_at : int64;
  kind : int;
  tags : string list list;
  content : string;
  signature : string;
}

type action = Upload | Download | Delete

let action_to_string = function
  | Upload -> "upload"
  | Download -> "get"
  | Delete -> "delete"

(* Helper to extract tag value *)
let find_tag event tag_name =
  try
    let tag = List.find (fun t ->
      match t with
      | name :: _ -> name = tag_name
      | _ -> false
    ) event.tags in
    match tag with
    | _ :: value :: _ -> Some value
    | _ -> None
  with Not_found -> None

let parse_auth_header header =
  try
    (* Format: "Nostr <base64-encoded-json>" *)
    match String.split_on_char ' ' header with
    | ["Nostr"; encoded] | ["nostr"; encoded] ->
        let decoded = Base64.decode_exn encoded in
        let json = Yojson.Safe.from_string decoded in
        let open Yojson.Safe.Util in
        let event = {
          id = json |> member "id" |> to_string;
          pubkey = json |> member "pubkey" |> to_string;
          created_at = json |> member "created_at" |> to_int |> Int64.of_int;
          kind = json |> member "kind" |> to_int;
          tags = json |> member "tags" |> to_list |> List.map (fun tag -> tag |> to_list |> List.map to_string);
          content = json |> member "content" |> to_string;
          signature = json |> member "sig" |> to_string;
        } in
        Ok event
    | _ -> Error (Domain.Storage_error "Invalid Authorization header format")
  with
  | Yojson.Json_error msg -> Error (Domain.Storage_error ("JSON parse error: " ^ msg))
  | _ -> Error (Domain.Storage_error "Failed to parse Authorization header")

let validate_event_structure event ~action ~current_time =
  if event.kind <> 24242 then
    Error (Domain.Storage_error "Invalid event kind, must be 24242")
  else if event.created_at > current_time then
    Error (Domain.Storage_error "Event created_at is in the future")
  else
    match find_tag event "expiration" with
    | None -> Error (Domain.Storage_error "Missing expiration tag")
    | Some exp_str ->
        (try
          let expiration = Int64.of_string exp_str in
          if expiration <= current_time then
            Error (Domain.Storage_error "Event has expired")
          else
            match find_tag event "t" with
            | None -> Error (Domain.Storage_error "Missing t tag")
            | Some t_value ->
                if t_value <> action_to_string action then
                  Error (Domain.Storage_error (Printf.sprintf "Invalid action, expected %s" (action_to_string action)))
                else
                  Ok ()
        with _ -> Error (Domain.Storage_error "Invalid expiration timestamp"))

let verify_signature event =
  (* Verify signature using BIP340 *)
  if String.length event.id <> 64 then
    Error (Domain.Storage_error "Invalid event ID length")
  else if String.length event.pubkey <> 64 then
    Error (Domain.Storage_error "Invalid pubkey length")
  else if String.length event.signature <> 128 then
    Error (Domain.Storage_error "Invalid signature length")
  else
    try
      if Bip340.verify ~pubkey:event.pubkey ~msg:event.id ~signature:event.signature then
        Ok ()
      else
        Error (Domain.Storage_error "Invalid signature")
    with _ -> Error (Domain.Storage_error "Signature verification failed")

let validate_auth ~header ~action ~current_time =
  match parse_auth_header header with
  | Error e -> Error e
  | Ok event ->
      match validate_event_structure event ~action ~current_time with
      | Error e -> Error e
      | Ok () ->
          match verify_signature event with
          | Error e -> Error e
          | Ok () -> Ok event.pubkey
