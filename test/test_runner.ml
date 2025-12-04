let () =
  Alcotest.run "Blossom Core" [
    "Integrity", Test_integrity.tests;
    "Policy", Test_policy.tests;
    "Auth", Test_auth.tests;
    "BIP340", Test_bip340.tests;
    "Http_response", Test_http_response.tests;
    "Mime_detect", Test_mime_detect.tests;
  ]
